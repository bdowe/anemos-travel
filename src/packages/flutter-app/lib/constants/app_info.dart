/// Single source of truth for the product name in Dart code.
///
/// Non-Dart locations that must be kept in sync by hand:
/// - web/index.html (title, description, apple-mobile-web-app-title)
/// - web/manifest.json (name, short_name, description)
/// - pubspec.yaml (description)
/// - ios/Runner/Info.plist (CFBundleDisplayName)
/// - android/app/src/main/AndroidManifest.xml (android:label)
abstract final class AppInfo {
  static const String name = 'Anemos';
}
