// Keeps the about box honest.
//
// `AppInfo.version` is a constant rather than something read from the platform,
// which is only acceptable while it cannot drift from the real one. That is
// what this asserts — the alternative was a plugin for one string.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/app_info.dart';

void main() {
  test('the version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml sans version lisible');
    expect(
      AppInfo.version,
      match!.group(1),
      reason:
          'AppInfo.version doit suivre pubspec.yaml — la boîte « À propos » '
          'annoncerait un numéro faux',
    );
  });

  test('the package id matches the Android manifest', () {
    // The one the launcher and the play store know it by; worth showing
    // correctly next to the owner's name.
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains(AppInfo.packageId));
  });

  test('the owner is named', () {
    expect(AppInfo.owner, isNotEmpty);
  });

  // The one that cost the user their data.
  //
  // Android refuses an APK whose `versionCode` is below the installed one, so
  // every build after 2.0.1 — which shipped with 2012 — was seen as a
  // downgrade and could only be installed by uninstalling first. Uninstalling
  // wipes the app's private storage: the API keys, the tag backups, the log and
  // every setting went with it, on each update.
  //
  // The code is therefore derived from the version rather than counted by hand,
  // which makes it monotonic by construction, and this test refuses anything at
  // or below the highest number ever shipped.
  test('the build number can only ever go up', () {
    const highestEverShipped = 2012;

    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml sans version+build lisible');

    final major = int.parse(match!.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    final build = int.parse(match.group(4)!);

    expect(
      build,
      major * 10000 + minor * 100 + patch,
      reason:
          'le versionCode doit valoir major*10000 + minor*100 + patch, sinon '
          'il peut repasser sous un numero deja installe',
    );
    expect(
      build,
      greaterThan(highestEverShipped),
      reason:
          'un versionCode inferieur a $highestEverShipped force une '
          'desinstallation, et une desinstallation efface les cles API',
    );
  });
}
