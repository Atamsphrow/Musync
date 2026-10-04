/// The metadata fields the tag editor reads and writes.
///
/// One shape shared by the MP3 (ID3) and M4A paths, so the editor never has
/// to know which container it is dealing with.
///
/// Write contract, per field:
/// - `null` leaves the field untouched in the file.
/// - an empty string removes the field's frame/atom.
/// - a negative track/disc number removes that part of the pair.
///
/// The editor builds this as a diff against what it loaded: a field the user
/// didn't change is null, a field they cleared is empty (or negative for the
/// numbers), a field they set carries the new value.
library;

import 'dart:typed_data';

typedef TrackMetadata = ({
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  String? genre,
  String? year,
  int? trackNumber,
  int? trackTotal,
  int? discNumber,
  int? discTotal,
  String? composer,
  String? comment,
  Uint8List? artwork,
});

const TrackMetadata emptyTrackMetadata = (
  title: null,
  artist: null,
  album: null,
  albumArtist: null,
  genre: null,
  year: null,
  trackNumber: null,
  trackTotal: null,
  discNumber: null,
  discTotal: null,
  composer: null,
  comment: null,
  artwork: null,
);
