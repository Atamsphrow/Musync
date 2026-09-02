/// Who made this, and which build you are looking at.
library;

abstract final class AppInfo {
  static const String name = 'Musync';

  /// Shown in the about box, and the reason it exists.
  static const String owner = 'Atamsphrow';

  static const String packageId = 'com.atamsphrow.musync';

  /// Kept in step with `pubspec.yaml` by a test rather than by a plugin.
  ///
  /// `package_info_plus` would read it at runtime, but every plugin added to
  /// this project has cost a Gradle argument, and one string does not justify
  /// another. A duplicated constant is only a problem if it can drift silently
  /// — so `app_info_test.dart` reads the pubspec and fails when the two
  /// disagree.
  static const String version = '2.14.0';

  static const String tagline =
      'Lecteur audio et éditeur de paroles synchronisées';
}
