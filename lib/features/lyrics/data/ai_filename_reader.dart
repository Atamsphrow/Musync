/// Asks a language model to read an artist and a title out of a file name.
///
/// The fallback behind [FilenameParser], not a replacement for it. The
/// heuristic handles the regular shapes offline and instantly; this exists for
/// the ones it cannot reason about — a name with no separator at all, or one
/// where the title comes before the artist.
///
/// Two API shapes cover almost everything worth configuring: Gemini's, and
/// OpenAI's `/chat/completions`, which Groq, OpenRouter, Mistral and a locally
/// served model all speak.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

/// Raised when the model can't be reached or answers with nothing usable.
///
/// [message] is written for the user and **never contains the API key** — the
/// debug panel has a Copy button, and a report pasted into a conversation must
/// not carry a secret with it.
class AiReaderException implements Exception {
  final String message;

  /// The HTTP status, when the failure was one. Null for a timeout, an
  /// unreachable host, or an answer that came back but made no sense.
  ///
  /// Carried separately from [message] so a caller can tell a dead model (404)
  /// from a dead key (401) without matching on prose.
  final int? statusCode;

  /// The model named in the request that failed.
  ///
  /// This is the field that turns "Gemini a répondu 404" into something
  /// actionable: a 404 from a generative endpoint almost always means the model
  /// identifier no longer exists, and knowing *which* one was asked for is the
  /// whole diagnosis.
  final String? model;

  const AiReaderException(this.message, {this.statusCode, this.model});

  /// One line for the log, with everything needed to act on it.
  String get detail {
    final parts = <String>[
      if (statusCode != null) 'HTTP $statusCode',
      if (model != null && model!.isNotEmpty) 'modèle demandé : $model',
    ];
    return parts.isEmpty ? message : '$message (${parts.join(' — ')})';
  }

  @override
  String toString() => 'AiReaderException: $detail';
}

/// Whether a configured model still exists on its provider.
enum AiModelCheck {
  /// The provider listed it.
  present,

  /// The provider answered, and this model was not in the list. The usual
  /// cause of a repeated 404: an identifier that was retired.
  missing,

  /// The key was refused, so nothing can be said about the model.
  keyRejected,

  /// The listing could not be had — no network, or a provider that does not
  /// implement it (a locally served model, typically).
  ///
  /// Deliberately distinct from [missing]. Reporting "your model does not
  /// exist" because a *listing* endpoint was unavailable would be a confident
  /// wrong answer, and would send the user editing a setting that is correct.
  unknown,
}

class AiFilenameReader {
  final http.Client _client;

  AiFilenameReader({http.Client? client}) : _client = client ?? http.Client();

  /// Generous: a cold model behind a free tier can take a while, and the user
  /// pressed a button and is watching.
  static const Duration _timeout = Duration(seconds: 25);

  /// Reads [fileName] through [provider].
  ///
  /// Returns the guess. Either field may come back empty, which is the honest
  /// answer for a name that does not say — the instruction asks for exactly
  /// that rather than an invention.
  Future<FilenameGuess> read({
    required AiProviderConfig provider,
    required String instruction,
    required String fileName,
  }) async {
    final answer = switch (provider.kind) {
      AiProviderKind.gemini => await _askGemini(
        provider,
        instruction,
        fileName,
      ),
      AiProviderKind.openAiCompatible => await _askOpenAi(
        provider,
        instruction,
        fileName,
      ),
    };

    return _parseAnswer(answer);
  }

  /// Asks the provider whether [provider]'s model still exists.
  ///
  /// Exists because a retired model identifier produces nothing but repeated
  /// 404s at the moment of use, which is the worst place to find out: the user
  /// pressed a button and got a failure whose cause is a setting they last
  /// touched months ago. Both API shapes expose a listing, so the question can
  /// be asked directly.
  ///
  /// Never throws. A check that cannot be made answers [AiModelCheck.unknown];
  /// this is a diagnostic, and it must not become a second way for the feature
  /// to fail.
  Future<AiModelCheck> checkModel(AiProviderConfig provider) async {
    final List<String> models;
    try {
      models = await listModels(provider);
    } on AiReaderException catch (e) {
      return e.statusCode == 401 || e.statusCode == 403
          ? AiModelCheck.keyRejected
          : AiModelCheck.unknown;
    }

    // An empty list means the provider answered but told us nothing useful —
    // treated as "cannot say", not as "your model is gone".
    if (models.isEmpty) return AiModelCheck.unknown;

    final wanted = provider.model.trim();
    return models.any((m) => m == wanted)
        ? AiModelCheck.present
        : AiModelCheck.missing;
  }

  /// The model identifiers [provider] admits to having.
  ///
  /// Gemini reports them as `models/<id>`; the prefix is stripped so both
  /// shapes come back in the form the config field holds.
  Future<List<String>> listModels(AiProviderConfig provider) async {
    final uri = Uri.parse('${_trimSlash(provider.baseUrl)}/models');
    final headers = switch (provider.kind) {
      AiProviderKind.gemini => {'x-goog-api-key': provider.apiKey.trim()},
      AiProviderKind.openAiCompatible => {
        'Authorization': 'Bearer ${provider.apiKey.trim()}',
      },
    };

    final http.Response response;
    try {
      response = await _client.get(uri, headers: headers).timeout(_timeout);
    } catch (_) {
      throw AiReaderException('${provider.name} est injoignable.');
    }

    if (response.statusCode != 200) {
      // The code is in the message, not only in the field. A scan that fails
      // with "liste indisponible" and nothing else leaves the user with no way
      // to tell a rejected key from a wrong address — which is exactly the
      // report that prompted this. Never the body: some providers echo the
      // request back, key included.
      throw AiReaderException(switch (response.statusCode) {
        401 || 403 =>
          'Clé refusée par ${provider.name} (HTTP ${response.statusCode}).',
        404 =>
          "Adresse introuvable sur ${provider.name} (HTTP 404). Verifiez "
              "l'URL de base : elle doit s'arreter avant /models.",
        429 => '${provider.name} limite les requêtes (HTTP 429). Réessayez.',
        _ =>
          'Liste des modèles indisponible sur ${provider.name} '
              '(HTTP ${response.statusCode}).',
      }, statusCode: response.statusCode);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw AiReaderException('Réponse illisible de ${provider.name}.');
    }
    // 'models' is Gemini's key, 'data' is OpenAI's — and a bare array is what
    // some self-hosted OpenAI-compatible servers answer with. That last shape
    // used to fall through to an empty list, which the form reported as "ce
    // fournisseur ne publie pas la liste de ses modèles": a wrong statement
    // about the provider, caused by a shape this code did not know.
    final entries = switch (decoded) {
      List() => decoded,
      Map() => decoded['models'] ?? decoded['data'],
      _ => null,
    };
    if (entries is! List) return const [];

    final out = <String>[];
    for (final entry in entries) {
      if (entry is! Map) continue;

      // Which field holds the identifier depends on the provider, and picking
      // whichever is present is wrong: OpenRouter publishes both, with `id` =
      // `meta/muse-spark-1.2-contributor` and `name` = "Meta: Muse Spark 1.2
      // Contributor". Preferring `name` filled the picker with display labels
      // that are not model identifiers, so choosing one could only ever 404.
      // Gemini is the opposite — its `name` is the identifier.
      final raw = switch (provider.kind) {
        AiProviderKind.gemini => entry['name'] ?? entry['id'],
        AiProviderKind.openAiCompatible => entry['id'] ?? entry['name'],
      };
      if (raw is! String || raw.isEmpty) continue;

      // Only models that can answer the question being asked.
      //
      // Gemini lists everything it serves, embeddings included, and says which
      // methods each one supports. A picker offering `embedding-001` alongside
      // the generative models is a picker that invites a 400. The OpenAI shape
      // publishes no such field, so there is nothing to filter on there and
      // everything is offered.
      final methods = entry['supportedGenerationMethods'];
      if (methods is List && !methods.contains('generateContent')) continue;

      out.add(raw.startsWith('models/') ? raw.substring(7) : raw);
    }
    // Alphabetical: the API's own order is neither stable nor meaningful, and a
    // list of sixty names is only usable if it is sorted.
    out.sort();
    return out;
  }

  Future<String> _askGemini(
    AiProviderConfig provider,
    String instruction,
    String fileName,
  ) async {
    final uri = Uri.parse(
      '${_trimSlash(provider.baseUrl)}/models/${provider.model}'
      ':generateContent',
    );

    final body = await _post(
      // The key travels in a header, not the query string: a URL is the thing
      // most likely to end up in a log somewhere.
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': provider.apiKey.trim(),
      },
      payload: {
        'systemInstruction': {
          'parts': [
            {'text': instruction},
          ],
        },
        'contents': [
          {
            'parts': [
              {'text': fileName},
            ],
          },
        ],
        'generationConfig': {'responseMimeType': 'application/json'},
      },
      provider: provider,
    );

    final candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const AiReaderException('Le modèle n\'a rien répondu.');
    }
    final parts = (candidates.first as Map?)?['content']?['parts'];
    if (parts is! List || parts.isEmpty) {
      throw const AiReaderException('Réponse vide du modèle.');
    }
    return '${(parts.first as Map?)?['text'] ?? ''}';
  }

  Future<String> _askOpenAi(
    AiProviderConfig provider,
    String instruction,
    String fileName,
  ) async {
    final uri = Uri.parse('${_trimSlash(provider.baseUrl)}/chat/completions');

    final body = await _post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${provider.apiKey.trim()}',
      },
      payload: {
        'model': provider.model,
        'messages': [
          {'role': 'system', 'content': instruction},
          {'role': 'user', 'content': fileName},
        ],
        'response_format': {'type': 'json_object'},
        // The answer is two short strings; there is no reason to pay for more,
        // and a cap stops a confused model rambling.
        'max_tokens': 200,
        'temperature': 0,
      },
      provider: provider,
    );

    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiReaderException('Le modèle n\'a rien répondu.');
    }
    return '${(choices.first as Map?)?['message']?['content'] ?? ''}';
  }

  Future<Map<String, Object?>> _post(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, Object?> payload,
    required AiProviderConfig provider,
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_timeout);
    } catch (_) {
      // The original exception is swallowed rather than wrapped: on some
      // clients it echoes the request, headers included.
      throw AiReaderException(
        '${provider.name} est injoignable. Vérifiez la connexion et l\'adresse.',
        model: provider.model,
      );
    }

    // Every one of these carries the status and the model, so the log line says
    // which of the two settings is wrong. "Gemini a répondu 404" sent the user
    // checking their key; "404 — modèle demandé : gemini-2.0-flash" points at
    // the model, which is where the fault actually was.
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AiReaderException(
        'Clé refusée par ${provider.name}.',
        statusCode: response.statusCode,
        model: provider.model,
      );
    }
    if (response.statusCode == 429) {
      throw AiReaderException(
        'Quota atteint sur ${provider.name}.',
        statusCode: response.statusCode,
        model: provider.model,
      );
    }
    if (response.statusCode == 404) {
      throw AiReaderException(
        '${provider.name} ne connaît pas ce modèle. Il a probablement été '
        'retiré : choisissez-en un autre dans Paramètres › IA.',
        statusCode: 404,
        model: provider.model,
      );
    }
    if (response.statusCode != 200) {
      throw AiReaderException(
        '${provider.name} a répondu ${response.statusCode}.',
        statusCode: response.statusCode,
        model: provider.model,
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (_) {
      // Falls through to the same message: the body could hold anything, and
      // quoting it back would be noise at best.
    }
    throw AiReaderException('Réponse illisible de ${provider.name}.');
  }

  /// Pulls `{"artist": ..., "title": ...}` out of whatever came back.
  ///
  /// Models are asked for bare JSON and mostly comply, but a stray ```json
  /// fence or a sentence of preamble is common enough to be worth surviving —
  /// so the first balanced object in the text is what gets parsed.
  static FilenameGuess _parseAnswer(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const AiReaderException(
        'Le modèle n\'a pas répondu en JSON. Ajustez l\'instruction.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw.substring(start, end + 1));
    } catch (_) {
      throw const AiReaderException(
        'Le JSON du modèle est invalide. Ajustez l\'instruction.',
      );
    }

    if (decoded is! Map) {
      throw const AiReaderException('Le modèle n\'a pas renvoyé d\'objet.');
    }

    return (
      artist: '${decoded['artist'] ?? ''}'.trim(),
      title: '${decoded['title'] ?? ''}'.trim(),
    );
  }

  static String _trimSlash(String url) {
    var out = url.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
