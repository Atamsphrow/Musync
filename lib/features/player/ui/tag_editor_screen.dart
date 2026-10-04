/// Full-screen tag editor for the current track.
///
/// Follows Musicolet's save flow: on Android 11+ the system write-access
/// dialog comes first (a refusal aborts silently), the tags are written into
/// a copy in the app's cache directory — never into the original — the copy
/// is then moved over the original, and MediaStore is told to re-index.
/// The final toast reads like Musicolet's: "Tags de la chanson mise à jour".
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:musync/core/id3/audio_container.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_metadata.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class TagEditorScreen extends ConsumerStatefulWidget {
  final Song song;

  const TagEditorScreen({super.key, required this.song});

  @override
  ConsumerState<TagEditorScreen> createState() => _TagEditorScreenState();
}

enum _CoverEdit { keep, replace, remove }

class _TagEditorScreenState extends ConsumerState<TagEditorScreen> {
  bool _loading = true;
  bool _saving = false;

  TrackMetadata _loaded = emptyTrackMetadata;
  String _loadedLyrics = '';

  final _title = TextEditingController();
  final _album = TextEditingController();
  final _artist = TextEditingController();
  final _albumArtist = TextEditingController();
  final _composer = TextEditingController();
  final _genre = TextEditingController();
  final _comment = TextEditingController();
  final _trackNumber = TextEditingController();
  final _discNumber = TextEditingController();
  final _lyrics = TextEditingController();

  _CoverEdit _coverEdit = _CoverEdit.keep;
  Uint8List? _newCover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _album,
      _artist,
      _albumArtist,
      _composer,
      _genre,
      _comment,
      _trackNumber,
      _discNumber,
      _lyrics,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Containers Musync can write tags to. Anything else gets the "format non
  /// supporté" message instead of the form.
  static bool _isEditable(AudioContainer container) =>
      container == AudioContainer.mp3 ||
      container == AudioContainer.unknown ||
      container == AudioContainer.mp4;

  Future<void> _load() async {
    final path = widget.song.filePath;
    AudioContainer container;
    try {
      final handle = await File(path).open();
      try {
        container = AudioContainerReader.detect(await handle.read(16));
      } finally {
        await handle.close();
      }
    } catch (_) {
      container = AudioContainer.unknown;
    }

    if (!_isEditable(container)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showOnly(
        SnackBar(
          content: Text(
            'Format non supporté : les tags d\'un fichier ${container.label} '
            'ne peuvent pas être modifiés.',
          ),
        ),
      );
      Navigator.maybePop(context);
      return;
    }

    final metadata = await Id3Reader.readFullMetadata(path);
    final lyrics = await Id3Reader.readLyrics(path);
    if (!mounted) return;
    final synced = lyrics.synced;
    final lyricsText = (synced != null && synced.isNotEmpty)
        ? synced.toLrc()
        : (lyrics.unsynced?.text ?? '');
    setState(() {
      _loaded = metadata;
      _loadedLyrics = lyricsText;
      _title.text = metadata.title ?? '';
      _album.text = metadata.album ?? '';
      _artist.text = metadata.artist ?? '';
      _albumArtist.text = metadata.albumArtist ?? '';
      _composer.text = metadata.composer ?? '';
      _genre.text = metadata.genre ?? '';
      _comment.text = metadata.comment ?? '';
      _trackNumber.text = metadata.trackNumber?.toString() ?? '';
      _discNumber.text = metadata.discNumber?.toString() ?? '';
      _lyrics.text = lyricsText;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Éditer les tags')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildForm(),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                ),
              ),
            ),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _field(_title, 'Titre'),
        _field(_album, 'Album'),
        _field(_artist, 'Artiste'),
        _field(_albumArtist, 'Artiste de l\'album'),
        _field(_composer, 'Compositeur'),
        _field(_genre, 'Genre'),
        _field(_comment, 'Commentaire', maxLines: 3),
        Row(
          children: [
            Expanded(
              child: _field(_trackNumber, 'N° de piste', numeric: true),
            ),
            const SizedBox(width: 12),
            Expanded(child: _field(_discNumber, 'N° de disque', numeric: true)),
          ],
        ),
        const SizedBox(height: 8),
        _buildCoverCard(),
        const SizedBox(height: 8),
        _field(_lyrics, 'Paroles', maxLines: 8),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        keyboardType: numeric ? TextInputType.number : null,
        maxLines: maxLines,
        textInputAction: TextInputAction.next,
      ),
    );
  }

  Widget _buildCoverCard() {
    final scheme = Theme.of(context).colorScheme;
    final Uint8List? preview = switch (_coverEdit) {
      _CoverEdit.replace => _newCover,
      _CoverEdit.remove => null,
      _CoverEdit.keep => _loaded.artwork,
    };
    final canRemove =
        _coverEdit == _CoverEdit.replace || _loaded.artwork != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: scheme.surfaceContainerHighest,
              ),
              clipBehavior: Clip.antiAlias,
              child: preview == null
                  ? Icon(Icons.music_note, color: scheme.onSurfaceVariant)
                  : Image.memory(preview, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: preview == null
                        ? null
                        : () => _viewCover(preview),
                    icon: const Icon(Icons.visibility, size: 18),
                    label: const Text('Voir'),
                  ),
                  TextButton.icon(
                    onPressed: _pickCover,
                    icon: const Icon(Icons.image, size: 18),
                    label: const Text('Remplacer'),
                  ),
                  TextButton.icon(
                    onPressed: canRemove
                        ? () => setState(() {
                            _coverEdit = _CoverEdit.remove;
                            _newCover = null;
                          })
                        : null,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Supprimer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _viewCover(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.memory(bytes),
        ),
      ),
    );
  }

  Future<void> _pickCover() async {
    final chosen = await FilePicker.pickFile(
      type: FileType.image,
      dialogTitle: 'Choisir une pochette',
    );
    final path = chosen?.path;
    if (path == null || !mounted) return;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty || !mounted) return;
      setState(() {
        _newCover = bytes;
        _coverEdit = _CoverEdit.replace;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showOnly(const SnackBar(content: Text('Image illisible.')));
    }
  }

  /// A text field's diff against what was loaded: null when untouched, the
  /// (possibly empty) new value otherwise. Empty means "remove the frame".
  String? _diffText(TextEditingController controller, String? loaded) {
    final value = controller.text.trim();
    if (value == (loaded ?? '')) return null;
    return value;
  }

  /// A number field's diff: null when untouched, -1 when cleared (remove that
  /// part), the new value otherwise.
  ///
  /// Returns null and shows a message when the input isn't a valid number —
  /// a typo must not silently become a removal. The caller aborts the save.
  ({int? trackNumber, int? discNumber})? _checkedNumbers() {
    int? check(TextEditingController controller, int? loaded, String label) {
      final value = controller.text.trim();
      if (value == (loaded?.toString() ?? '')) return null; // untouched
      if (value.isEmpty) return -1; // cleared → remove that part
      final parsed = int.tryParse(value);
      if (parsed == null || parsed <= 0) {
        ScaffoldMessenger.of(context).showOnly(
          SnackBar(content: Text('$label : « $value » n\'est pas valide.')),
        );
        throw const _InvalidNumber();
      }
      return parsed;
    }

    try {
      return (
        trackNumber: check(_trackNumber, _loaded.trackNumber, 'N° de piste'),
        discNumber: check(_discNumber, _loaded.discNumber, 'N° de disque'),
      );
    } on _InvalidNumber {
      return null;
    }
  }

  Future<void> _save() async {
    if (_saving || _loading) return;

    // The number fields are validated before anything is written: a typo
    // must not silently become a removal.
    final numbers = _checkedNumbers();
    if (numbers == null) return; // invalid, message already shown

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final song = widget.song;

    // The diffs, computed before anything touches the file: when nothing
    // changed there is nothing to ask permission for.
    final diff = (
      title: _diffText(_title, _loaded.title),
      artist: _diffText(_artist, _loaded.artist),
      album: _diffText(_album, _loaded.album),
      albumArtist: _diffText(_albumArtist, _loaded.albumArtist),
      genre: _diffText(_genre, _loaded.genre),
      year: null,
      trackNumber: numbers.trackNumber,
      trackTotal: null,
      discNumber: numbers.discNumber,
      discTotal: null,
      composer: _diffText(_composer, _loaded.composer),
      comment: _diffText(_comment, _loaded.comment),
      artwork: switch (_coverEdit) {
        _CoverEdit.keep => null,
        _CoverEdit.replace => _newCover,
        _CoverEdit.remove => Uint8List(0),
      },
    );
    final newLyrics = _diffLyrics();
    if (_isEmptyDiff(diff) && newLyrics == null) {
      if (mounted) {
        setState(() => _saving = false);
        Navigator.maybePop(context);
      }
      return;
    }

    try {
      // 1. System write permission (Android 11+). A refusal aborts silently —
      //    no error, no toast.
      final granted = await MediaStore.requestWriteAccess(
        mediaStoreId: song.id,
        path: song.filePath,
      );
      if (!granted) {
        if (mounted) setState(() => _saving = false);
        return;
      }

      // 2. Work on a copy in the app's cache directory. The writers never
      //    open the original — not even their own temp files live next to it.
      final cacheDir = await getTemporaryDirectory();
      final workPath = p.join(cacheDir.path, 'tag_edit_${song.id}.tmp');
      final workFile = File(workPath);
      if (await workFile.exists()) await workFile.delete();
      await File(song.filePath).copy(workPath);

      // 3. Write the tags, then the lyrics, into the copy.
      try {
        if (!_isEmptyDiff(diff)) {
          await Id3Writer.writeMetadata(workPath, diff);
        }
        if (newLyrics != null) {
          await _writeLyrics(workPath, newLyrics);
        }
      } on Id3WriteException catch (e) {
        await _deleteQuietly(workFile);
        if (!mounted) return;
        setState(() => _saving = false);
        messenger.showOnly(SnackBar(content: Text(e.message)));
        return;
      }

      // 4. Binary copy over the original, via a sibling temp + atomic rename:
      //    the original is never left half-written.
      final target = File(song.filePath);
      final stage = File('${target.path}.musync.tmp');
      if (await stage.exists()) await stage.delete();
      await workFile.copy(stage.path);
      await _deleteQuietly(workFile);
      await stage.rename(target.path);

      // 5. Tell MediaStore the file changed.
      await MediaStore.rescan(target.path);
    } catch (_) {
      // Anything unexpected (copy failure, …): the original is untouched,
      // say so plainly.
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showOnly(
        const SnackBar(content: Text('Enregistrement impossible.')),
      );
      return;
    }

    if (!mounted) return;
    _refreshDisplays();
    setState(() => _saving = false);
    Navigator.maybePop(context);
    // The editor is gone: toast on the app's messenger, Musicolet-style.
    appMessengerKey.currentState?.showOnly(
      const SnackBar(content: Text('Tags de la chanson mise à jour')),
    );
  }

  /// The lyrics diff, raw: pasted lyrics reach the file exactly as typed,
  /// never silently modified.
  String? _diffLyrics() {
    final value = _lyrics.text;
    if (value == _loadedLyrics) return null;
    return value;
  }

  /// Writes [newLyrics] into the working copy: LRC text becomes synchronised
  /// lyrics (SYLT + timed USLT, the way Musicolet reads them), plain text
  /// becomes an untimed USLT, and an emptied field clears both frames.
  Future<void> _writeLyrics(String workPath, String newLyrics) async {
    if (newLyrics.trim().isEmpty) {
      await Id3Writer.writeLyrics(workPath);
      return;
    }
    final synced = LrcParser.parse(newLyrics);
    if (synced.isNotEmpty) {
      await Id3Writer.writeLyrics(workPath, synced: synced);
    } else {
      await Id3Writer.writeLyrics(
        workPath,
        unsynced: UnsyncedLyrics(newLyrics),
      );
    }
  }

  static bool _isEmptyDiff(TrackMetadata diff) =>
      diff.title == null &&
      diff.artist == null &&
      diff.album == null &&
      diff.albumArtist == null &&
      diff.genre == null &&
      diff.year == null &&
      diff.trackNumber == null &&
      diff.trackTotal == null &&
      diff.discNumber == null &&
      diff.discTotal == null &&
      diff.composer == null &&
      diff.comment == null &&
      diff.artwork == null;

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Pushes the edited values into the player, the library list and the
  /// lyrics providers, so the new tags show without a rescan.
  void _refreshDisplays() {
    final song = widget.song;
    final updated = song.copyWith(
      title: _displayValue(_title.text, song.title),
      artist: _displayValue(_artist.text, song.artist),
      album: _displayValue(_album.text, song.album),
    );

    // The player holds its own Song: update it in place so the screen shows
    // the new values without restarting the track.
    final current = ref.read(currentSongProvider);
    if (current != null && current.filePath == song.filePath) {
      ref
          .read(audioPlayerServiceProvider)
          .updateCurrentSongMetadata(
            title: updated.title,
            artist: updated.artist,
            album: updated.album,
          );
      if (_coverEdit != _CoverEdit.keep) {
        ref.read(audioPlayerServiceProvider).forgetArtwork(song);
      }
    }

    // The library list, matched by id, keeping the current sort order.
    ref.read(songListProvider.notifier).updateSong(updated);

    // The file changed: let the lyrics providers re-read rather than serve
    // anything stale.
    ref.invalidate(currentLyricsProvider);
  }

  /// Mirrors the library scanner: an emptied tag field keeps the previous
  /// display value instead of blanking the title.
  static String _displayValue(String form, String previous) {
    final trimmed = form.trim();
    return trimmed.isEmpty ? previous : trimmed;
  }
}

/// Thrown by [_TagEditorScreenState._checkedNumbers] to abort the save when a
/// number field holds an invalid value. The message is already shown.
class _InvalidNumber implements Exception {
  const _InvalidNumber();
}
