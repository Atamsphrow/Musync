package com.atamsphrow.musync

import com.ryanheise.audioservice.AudioServiceActivity

/// Must extend `AudioServiceActivity`, never `FlutterActivity`.
///
/// `audio_service` — pulled in by `just_audio_background` — runs the media
/// session in a FlutterEngine that it caches itself, so that playback survives
/// the UI being destroyed. `AudioServiceActivity` hands that same cached engine
/// to the Activity, which leaves exactly one engine, with an Activity attached
/// to it.
///
/// With a plain `FlutterActivity` there are two engines and the Activity's one
/// is not the one `audio_service` configured. That failed twice at launch, and
/// the app never got past its splash screen:
///
///  * `JustAudioBackground.init()` threw "The Activity class declared in your
///    AndroidManifest.xml is wrong or has not provided the correct
///    FlutterEngine", so `main()` aborted before the notification channel and
///    the background handler were installed;
///  * `permission_handler` found no Activity to attach its request to ("Unable
///    to detect current Activity"), so the startup permission prompt never
///    appeared — `READ_MEDIA_AUDIO` stayed denied and the library had nothing
///    to scan.
class MainActivity : AudioServiceActivity()
