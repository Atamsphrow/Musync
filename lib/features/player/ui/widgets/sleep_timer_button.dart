import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/player/providers/sleep_timer_provider.dart';

/// Sleep timer button for the now-playing screen's top bar.
///
/// Timer icon filled in the accent colour while a timer runs, dimmed
/// timer-off outline when idle. A fixed-duration timer also wears a small
/// badge with the minutes left; the tooltip always spells out the state.
class SleepTimerButton extends ConsumerWidget {
  const SleepTimerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final timerState = ref.watch(sleepTimerProvider);
    final active = timerState.active;
    final remaining = timerState.remaining;

    final tooltip = !active
        ? 'Minuteur d’arrêt'
        : remaining != null
            ? 'Minuteur : ${remaining.inMinutes} min restantes'
            : 'Minuteur : fin du morceau';

    return Badge(
      // Only fixed durations have a countdown; "end of track" has none.
      isLabelVisible: active && remaining != null,
      label: Text('${remaining?.inMinutes ?? 0}'),
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
      child: IconButton(
        icon: Icon(
          active ? Icons.timer : Icons.timer_off_outlined,
          color: active ? scheme.primary : scheme.onSurfaceVariant,
        ),
        tooltip: tooltip,
        onPressed: () => _openSheet(context),
      ),
    );
  }

  void _openSheet(BuildContext context) => showSleepTimerSheet(context);
}

/// Opens the sleep-timer sheet. Public so the now-playing overflow menu can
/// offer the same entry point as the old top-bar button.
void showSleepTimerSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => const SafeArea(child: _SleepTimerSheet()),
  );
}

class _SleepTimerSheet extends ConsumerWidget {
  const _SleepTimerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final selected = ref.watch(sleepTimerProvider).option;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Minuteur d’arrêt',
              style: textTheme.titleMedium,
            ),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final option in SleepTimerOption.values)
                ListTile(
                  leading: option == SleepTimerOption.disabled
                      ? const Icon(Icons.timer_off_outlined)
                      : const Icon(Icons.timer_outlined),
                  title: Text(option.label),
                  trailing: selected == option
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    ref
                        .read(sleepTimerProvider.notifier)
                        .setOption(option);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
