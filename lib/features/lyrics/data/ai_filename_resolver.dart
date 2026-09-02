/// Tries the configured models in order, and stops at the first that answers.
///
/// Before this, only the first usable provider was ever asked: a dead Gemini
/// model meant the feature was dead, even with a working Groq key sitting right
/// underneath it. Three providers configured is three chances, and the user
/// should not have to reorder them by hand to get past one that is broken.
///
/// The distinction that matters, and the one that makes this correct rather than
/// merely persistent: a provider that *answers* ends the cascade, even if the
/// answer is "this file name does not say". That is a result, not a failure —
/// asking a second model the same unanswerable question would cost a round trip
/// to be told the same thing. Only a technical failure moves on.
library;

import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

/// What one provider did when it was asked.
class AiAttempt {
  final String providerId;
  final String providerName;
  final String model;

  /// Null when the provider answered.
  final AiReaderException? failure;

  const AiAttempt({
    required this.providerId,
    required this.providerName,
    required this.model,
    this.failure,
  });

  bool get ok => failure == null;
}

/// The outcome of a whole cascade.
class AiResolution {
  /// Null when every provider failed. An *empty* guess is not null: it means a
  /// model answered and had nothing to offer.
  final FilenameGuess? guess;

  /// Which provider answered, for the message that says where the fields came
  /// from.
  final String? providerName;

  /// Every attempt, in order. The UI shows the per-provider state from this.
  final List<AiAttempt> attempts;

  const AiResolution({this.guess, this.providerName, this.attempts = const []});

  bool get answered => guess != null;

  /// True when providers were configured and all of them failed — the only case
  /// worth interrupting the user for.
  bool get allFailed => attempts.isNotEmpty && !answered;

  /// One message for the failure of the whole cascade, naming each provider and
  /// its own reason. A single line saying "l'IA a échoué" would hide the fact
  /// that the three causes are usually three different problems.
  String get failureSummary => attempts
      .where((a) => !a.ok)
      .map((a) => '${a.providerName} : ${a.failure!.detail}')
      .join(' · ');
}

class AiFilenameResolver {
  final AiFilenameReader reader;

  const AiFilenameResolver(this.reader);

  Future<AiResolution> resolve({
    required AiSettings settings,
    required String fileName,
  }) async {
    final providers = settings.usable;
    if (providers.isEmpty) return const AiResolution();

    final attempts = <AiAttempt>[];

    for (final provider in providers) {
      try {
        final guess = await reader.read(
          provider: provider,
          instruction: settings.instruction,
          fileName: fileName,
        );

        attempts.add(
          AiAttempt(
            providerId: provider.id,
            providerName: provider.name,
            model: provider.model,
          ),
        );
        // Info, not warning: this is the normal path, and the log has a
        // verbosity filter that should not be shouted at.
        DebugLog.instance.info(
          'IA',
          '${provider.name} a répondu (modèle ${provider.model})',
        );

        return AiResolution(
          guess: guess,
          providerName: provider.name,
          attempts: attempts,
        );
      } on AiReaderException catch (e) {
        attempts.add(
          AiAttempt(
            providerId: provider.id,
            providerName: provider.name,
            model: provider.model,
            failure: e,
          ),
        );
        // Each individual failure is recorded but *not* surfaced: with three
        // providers configured, one broken one used to mean a snackbar on every
        // single press. The user hears about it only if none of them work.
        DebugLog.instance.info(
          'IA',
          '${provider.name} a échoué, on passe au suivant — ${e.detail}',
        );
      }
    }

    DebugLog.instance.warning(
      'IA',
      'Tous les modèles configurés ont échoué. '
          '${AiResolution(attempts: attempts).failureSummary}',
    );
    return AiResolution(attempts: attempts);
  }
}
