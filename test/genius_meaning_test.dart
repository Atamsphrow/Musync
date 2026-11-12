// Tests des significations Genius : recherche, « About », annotations.
//
// Tout tourne contre un client HTTP simulé. Les charges reflètent les
// réponses réelles de genius.com/api (search, songs, referents) telles
// que myspoti les lit — sans clé.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/genius_meaning.dart';

/// Un hit de recherche Genius, dans la forme renvoyée.
Map<String, dynamic> hit({
  int id = 42,
  String title = 'Blinding Lights',
  String artistNames = 'The Weeknd',
  String url = 'https://genius.com/The-weeknd-blinding-lights-lyrics',
}) => {
  'result': {
    'id': id,
    'title': title,
    'artist_names': artistNames,
    'url': url,
  },
};

/// Une réponse de recherche : une section, des hits.
Map<String, dynamic> searchPayload(List<Map<String, dynamic>> hits) => {
  'response': {
    'sections': [
      {'hits': hits},
    ],
  },
};

/// Une réponse de morceau : la description « About ».
Map<String, dynamic> songPayload({String? about}) => {
  'response': {
    'song': {
      'description': {'plain': about},
    },
  },
};

/// Un référent Genius : un fragment + ses annotations.
Map<String, dynamic> referent({
  String fragment = 'blinding lights',
  List<Map<String, dynamic>>? annotations,
}) => {
  'fragment': fragment,
  'annotations': annotations ??
      [
        {
          'body': {'plain': 'Il parle des lumières de la ville.'},
          'votes_total': 12,
          'url': 'https://genius.com/annotations/1',
        },
      ],
};

Map<String, dynamic> referentsPayload(List<Map<String, dynamic>> refs) => {
  'response': {'referents': refs},
};

/// Sert search, songs et referents depuis les charges données.
MockClient mockGenius({
  List<Map<String, dynamic>>? hits,
  Map<String, dynamic>? song,
  Map<String, dynamic>? referents,
  int searchStatus = 200,
  int songStatus = 200,
  int referentsStatus = 200,
  List<Uri>? recordInto,
  int failTimes = 0,
}) {
  var calls = 0;
  return MockClient((request) async {
    recordInto?.add(request.url);
    calls++;
    if (calls <= failTimes) {
      throw const SocketException('Connexion réinitialisée');
    }
    final path = request.url.path;
    Object? payload;
    var status = 200;
    if (path.endsWith('/search/song')) {
      payload = searchPayload(hits ?? []);
      status = searchStatus;
    } else if (path.contains('/songs/')) {
      payload = song ?? songPayload();
      status = songStatus;
    } else if (path.endsWith('/referents')) {
      payload = referents ?? referentsPayload([]);
      status = referentsStatus;
    } else {
      return http.Response.bytes(utf8.encode('{}'), 404);
    }
    return http.Response.bytes(utf8.encode(jsonEncode(payload)), status);
  });
}

void main() {
  test('chemin nominal : About + note de la meilleure annotation', () async {
    final service = GeniusMeaningService(
      client: mockGenius(
        hits: [
          hit(title: 'Autre titre', artistNames: 'Autre artiste'),
          hit(),
        ],
        song: songPayload(about: 'Une chanson sur la nuit.'),
        referents: referentsPayload([
          referent(),
          referent(
            fragment: 'yeah',
            annotations: [
              {
                'body': {'plain': '?'},
                'votes_total': 99,
                'url': '',
              },
              {
                'body': {'plain': 'Un oui las.'},
                'votes_total': 3,
                'url': '',
              },
              {
                'body': {'plain': 'Une explication rejetée.'},
                'votes_total': -5,
                'url': '',
              },
            ],
          ),
          referent(fragment: '', annotations: []),
        ]),
      ),
    );
    final meaning = await service.find(
      title: 'Blinding Lights',
      artist: 'The Weeknd',
    );
    expect(meaning, isNotNull);
    expect(meaning!.title, 'Blinding Lights');
    expect(meaning.about, 'Une chanson sur la nuit.');
    expect(meaning.notes, hasLength(2));
    // La note « blinding lights » : la seule annotation, 12 votes.
    expect(meaning.notes[0].fragment, 'blinding lights');
    expect(meaning.notes[0].votes, 12);
    // La note « yeah » : le « ? » (99 votes) et le -5 sont écartés.
    expect(meaning.notes[1].explanation, 'Un oui las.');
    expect(meaning.notes[1].votes, 3);
  });

  test('noteForLine : le fragment dans la ligne, et l’inverse', () {
    const meaning = GeniusMeaning(
      url: '',
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      notes: [
        GeniusNote(
          fragment: 'blinding lights',
          explanation: 'Les lumières de la ville.',
        ),
      ],
    );
    expect(
      meaning
          .noteForLine('I’ve been blinded by the blinding lights')
          ?.explanation,
      'Les lumières de la ville.',
    );
    // La ligne est plus courte que le fragment : match aussi.
    expect(
      meaning.noteForLine('blinding')?.explanation,
      'Les lumières de la ville.',
    );
    expect(meaning.noteForLine('Rien à voir'), isNull);
  });

  test('aucun morceau ne correspond : null', () async {
    final service = GeniusMeaningService(
      client: mockGenius(hits: [hit(artistNames: 'Autre artiste')]),
    );
    expect(
      await service.find(title: 'Blinding Lights', artist: 'The Weeknd'),
      isNull,
    );
  });

  test('ni About ni note : null', () async {
    final service = GeniusMeaningService(
      client: mockGenius(
        hits: [hit()],
        song: songPayload(about: null),
        referents: referentsPayload([]),
      ),
    );
    expect(
      await service.find(title: 'Blinding Lights', artist: 'The Weeknd'),
      isNull,
    );
  });

  test('recherche 404 : null', () async {
    final service = GeniusMeaningService(
      client: mockGenius(searchStatus: 404),
    );
    expect(
      await service.find(title: 'Blinding Lights', artist: 'The Weeknd'),
      isNull,
    );
  });

  test('recherche 500 : exception', () async {
    final service = GeniusMeaningService(
      client: mockGenius(searchStatus: 500),
    );
    await expectLater(
      service.find(title: 'Blinding Lights', artist: 'The Weeknd'),
      throwsA(isA<GeniusMeaningException>()),
    );
  });

  test('1er appel coupé : le retry passe', () async {
    final service = GeniusMeaningService(
      client: mockGenius(hits: [hit()], failTimes: 1),
    );
    final meaning = await service.find(
      title: 'Blinding Lights',
      artist: 'The Weeknd',
    );
    // Pas de About ni de note dans les charges par défaut : null, mais
    // sans exception — le retry a bien eu lieu.
    expect(meaning, isNull);
  });

  test('deuxième appel : servi par le cache, sans requête', () async {
    final urls = <Uri>[];
    final service = GeniusMeaningService(
      client: mockGenius(
        hits: [hit()],
        song: songPayload(about: 'Une chanson sur la nuit.'),
        recordInto: urls,
      ),
    );
    await service.find(title: 'Blinding Lights', artist: 'The Weeknd');
    final callsAfterFirst = urls.length;
    expect(callsAfterFirst, greaterThan(0));
    await service.find(title: 'Blinding Lights', artist: 'The Weeknd');
    expect(urls.length, callsAfterFirst);
  });

  test('absence mémorisée : pas de deuxième requête', () async {
    final urls = <Uri>[];
    final service = GeniusMeaningService(
      client: mockGenius(hits: [], recordInto: urls),
    );
    await service.find(title: 'Inconnu', artist: 'Inconnu');
    final callsAfterFirst = urls.length;
    await service.find(title: 'Inconnu', artist: 'Inconnu');
    expect(urls.length, callsAfterFirst);
  });
}
