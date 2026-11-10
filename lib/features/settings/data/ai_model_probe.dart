/// Probes every model of a freshly scanned list, one at a time, and reports
/// each answer as it arrives — so the add-model dialog can mark the models
/// that respond instead of making the user try them one by one.
///
/// Pure orchestration: the actual call is the injected [ping], which is
/// [AiFilenameReader.pingModel] with the draft config's model swapped per
/// candidate. The batch stops early on a refused key or a rate limit — both
/// poison every remaining probe, and burning one call per model into the
/// same wall would only make it worse.
library;

import 'package:musync/features/lyrics/data/ai_filename_reader.dart';

/// How a probe batch ended.
enum AiModelProbeOutcome {
  /// Every model was probed.
  completed,

  /// Stopped: the key was refused, so no later model could be judged.
  stoppedKeyRejected,

  /// Stopped: the provider is rate-limiting (HTTP 429).
  stoppedRateLimited,

  /// Stopped: the caller asked to stop (dialog closed, re-scan).
  cancelled,
}

class AiModelProbe {
  /// The models of [models] still to probe, given [results] so far.
  ///
  /// A model with no result yet is still to probe. So is a model whose
  /// result stopped a batch (refused key, rate limit): that result is
  /// not a verdict on the model — the provider refused the call itself —
  /// so a resumed batch retests it. Every other result (answered,
  /// no answer, unknown) stands and is never pinged again.
  static List<String> remaining({
    required List<String> models,
    required Map<String, AiModelPing> results,
  }) => [
    for (final model in models)
      if (!results.containsKey(model) ||
          results[model] == AiModelPing.rateLimited ||
          results[model] == AiModelPing.keyRejected)
        model,
  ];

  /// Probes [models] in order, one at a time, calling [onResult] after
  /// each model with what the probe found.
  ///
  /// [isCancelled] is consulted before each probe; when it answers true
  /// the batch ends with [AiModelProbeOutcome.cancelled] and no further
  /// model is pinged. A probe already in flight still reports its result
  /// through [onResult] — the caller (a dialog) must ignore results from
  /// a run it has superseded; see the generation guard in
  /// `_ProviderDialogState`.
  static Future<AiModelProbeOutcome> run({
    required List<String> models,
    required Future<AiModelPing> Function(String model) ping,
    required void Function(String model, AiModelPing result) onResult,
    bool Function()? isCancelled,
  }) async {
    for (final model in models) {
      if (isCancelled?.call() ?? false) {
        return AiModelProbeOutcome.cancelled;
      }
      final result = await ping(model);
      onResult(model, result);
      if (result == AiModelPing.keyRejected) {
        return AiModelProbeOutcome.stoppedKeyRejected;
      }
      if (result == AiModelPing.rateLimited) {
        return AiModelProbeOutcome.stoppedRateLimited;
      }
    }
    return AiModelProbeOutcome.completed;
  }
}
