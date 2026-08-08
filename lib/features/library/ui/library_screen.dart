import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/router/app_router.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/library/ui/widgets/song_tile.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/mini_player.dart';

/// Home screen: the whole music library, plus the mini player docked at the
/// bottom once something is playing.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    // The scan needs the audio permission, so ask before anything tries to
    // read MediaStore. Post-frame because a permission dialog cannot be raised
    // while the first frame is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissions());
  }

  Future<void> _requestPermissions() async {
    final outcome = await PermissionService.requestStartupPermissions();
    if (!mounted) return;

    if (outcome == PermissionOutcome.granted) {
      // The provider may have already built and failed against a denied
      // permission; rescanning now is what fills the list.
      ref.invalidate(songListProvider);
      return;
    }

    ref.read(libraryPermissionDeniedProvider.notifier).state = outcome;
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(songListProvider);
    final permissionIssue = ref.watch(libraryPermissionDeniedProvider);
    final hasCurrentSong = ref.watch(currentSongProvider) != null;

    return Scaffold(
      body: permissionIssue != null
          ? _PermissionRequired(
              outcome: permissionIssue,
              onRetry: _requestPermissions,
            )
          : RefreshIndicator(
              onRefresh: () => ref.read(songListProvider.notifier).refresh(),
              child: CustomScrollView(
                slivers: [
                  _LibraryAppBar(songsAsync: songsAsync),
                  ...switch (songsAsync) {
                    AsyncData(:final value) when value.isEmpty => [
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyLibrary(),
                        ),
                      ],
                    AsyncData(:final value) => [
                        SliverList.builder(
                          itemCount: value.length,
                          itemBuilder: (context, index) => SongTile(
                            song: value[index],
                            onTap: () => Navigator.pushNamed(
                              context,
                              AppRoutes.player,
                              arguments: SongRouteArgs(
                                song: value[index],
                                queue: value,
                                index: index,
                              ),
                            ),
                          ),
                        ),
                      ],
                    AsyncError(:final error) => [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _ScanFailed(
                            error: error,
                            onRetry: () =>
                                ref.read(songListProvider.notifier).refresh(),
                          ),
                        ),
                      ],
                    _ => [
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ],
                  },
                  // Keeps the last song reachable above the mini player.
                  SliverToBoxAdapter(
                    child: SizedBox(height: hasCurrentSong ? 8 : 24),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: const _DockedMiniPlayer(),
    );
  }
}

/// Slides the mini player in and out instead of making the list jump by 66 px
/// the moment playback starts.
class _DockedMiniPlayer extends ConsumerWidget {
  const _DockedMiniPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(currentSongProvider) != null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: hasSong ? const SafeArea(child: MiniPlayer()) : const SizedBox.shrink(),
    );
  }
}

class _LibraryAppBar extends StatelessWidget {
  final AsyncValue<List> songsAsync;

  const _LibraryAppBar({required this.songsAsync});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final subtitle = switch (songsAsync) {
      AsyncData(:final value) =>
        '${value.length} morceau${value.length > 1 ? 'x' : ''}',
      AsyncError() => 'Analyse impossible',
      _ => 'Analyse en cours…',
    };

    return SliverAppBar.large(
      pinned: true,
      title: const Text('Musync'),
      backgroundColor: scheme.surface,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Text(
              subtitle,
              style: textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const _CenteredMessage(
      icon: Icons.music_off,
      title: 'Aucun morceau trouvé',
      message: 'Musync n\'a trouvé aucun fichier audio sur cet appareil. '
          'Tirez vers le bas pour relancer l\'analyse.',
    );
  }
}

class _ScanFailed extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ScanFailed({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _CenteredMessage(
      icon: Icons.error_outline,
      title: 'Analyse impossible',
      message: '$error',
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Réessayer'),
      ),
    );
  }
}

class _PermissionRequired extends StatelessWidget {
  final PermissionOutcome outcome;
  final VoidCallback onRetry;

  const _PermissionRequired({required this.outcome, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isPermanent = outcome == PermissionOutcome.permanentlyDenied;

    return _CenteredMessage(
      icon: Icons.library_music_outlined,
      title: 'Accès à la musique requis',
      message: isPermanent
          ? 'L\'autorisation a été refusée définitivement. Activez-la dans les '
              'paramètres d\'Android pour que Musync puisse lire votre '
              'bibliothèque.'
          : 'Musync a besoin d\'accéder à vos fichiers audio pour afficher '
              'votre bibliothèque.',
      action: FilledButton.icon(
        onPressed: isPermanent ? PermissionService.openSettings : onRetry,
        icon: Icon(isPermanent ? Icons.settings : Icons.check, size: 18),
        label: Text(isPermanent ? 'Ouvrir les paramètres' : 'Autoriser'),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
