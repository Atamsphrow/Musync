// The batch probe: models are pinged one at a time, in order, and the batch
// stops on a refused key or a rate limit instead of burning one call per
// model into the same wall. An unknown (test impossible) is reported like
// any other result and never stops the batch.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_model_probe.dart';

void main() {
  group('AiModelProbe.run', () {
    test('probes every model in order when all answer', () async {
      final pinged = <String>[];
      final results = <String, AiModelPing>{};
      final outcome = await AiModelProbe.run(
        models: const ['a', 'b', 'c'],
        ping: (model) async {
          pinged.add(model);
          return AiModelPing.answered;
        },
        onResult: (model, result) => results[model] = result,
      );
      expect(outcome, AiModelProbeOutcome.completed);
      expect(pinged, ['a', 'b', 'c']);
      expect(results, {
        'a': AiModelPing.answered,
        'b': AiModelPing.answered,
        'c': AiModelPing.answered,
      });
    });

    test('stops on a refused key, later models never pinged', () async {
      final pinged = <String>[];
      final outcome = await AiModelProbe.run(
        models: const ['a', 'b', 'c'],
        ping: (model) async {
          pinged.add(model);
          return model == 'b'
              ? AiModelPing.keyRejected
              : AiModelPing.answered;
        },
        onResult: (_, _) {},
      );
      expect(outcome, AiModelProbeOutcome.stoppedKeyRejected);
      expect(pinged, ['a', 'b']);
    });

    test('stops on a rate limit, later models never pinged', () async {
      final pinged = <String>[];
      final outcome = await AiModelProbe.run(
        models: const ['a', 'b', 'c'],
        ping: (model) async {
          pinged.add(model);
          return model == 'a'
              ? AiModelPing.rateLimited
              : AiModelPing.answered;
        },
        onResult: (_, _) {},
      );
      expect(outcome, AiModelProbeOutcome.stoppedRateLimited);
      expect(pinged, ['a']);
    });

    test('unknowns are reported, not stopping', () async {
      final results = <String, AiModelPing>{};
      final outcome = await AiModelProbe.run(
        models: const ['a', 'b'],
        ping: (model) async =>
            model == 'a' ? AiModelPing.unknown : AiModelPing.answered,
        onResult: (model, result) => results[model] = result,
      );
      expect(outcome, AiModelProbeOutcome.completed);
      expect(results, {
        'a': AiModelPing.unknown,
        'b': AiModelPing.answered,
      });
    });

    test('cancellation stops before the next model', () async {
      var cancel = false;
      final pinged = <String>[];
      final outcome = await AiModelProbe.run(
        models: const ['a', 'b', 'c'],
        ping: (model) async {
          pinged.add(model);
          return AiModelPing.answered;
        },
        onResult: (_, _) => cancel = true,
        isCancelled: () => cancel,
      );
      expect(outcome, AiModelProbeOutcome.cancelled);
      expect(pinged, ['a']);
    });

    test('empty list completes without pinging', () async {
      var pinged = 0;
      final outcome = await AiModelProbe.run(
        models: const [],
        ping: (_) async {
          pinged++;
          return AiModelPing.answered;
        },
        onResult: (_, _) {},
      );
      expect(outcome, AiModelProbeOutcome.completed);
      expect(pinged, 0);
    });
  });
}
