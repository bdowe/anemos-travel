// Post-build strip of flutter_math_fork's KaTeX fonts from a `flutter build
// web` output. gpt_markdown hard-depends on flutter_math_fork, whose 16 KaTeX
// font families land in FontManifest.json and are downloaded before first
// frame — but the app excludes the LaTeX markdown components (chat_panel.dart)
// so the fonts are dead weight (~597 KB). Run by dockerize/deployment/
// Dockerfile after the build; CI's plain compile-check build is unaffected.
//
// FAILS LOUDLY (exit 1) if the manifest has no flutter_math_fork entries:
// if gpt_markdown drops the dep or the manifest layout changes we want a red
// build, not a silently different bundle. Running it twice therefore fails.
//
// Usage: dart run tool/strip_katex_fonts.dart [build/web]
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final buildDir = args.isEmpty ? 'build/web' : args.first;
  const marker = 'packages/flutter_math_fork/';
  final manifestFile = File('$buildDir/assets/FontManifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('strip_katex_fonts: ${manifestFile.path} not found');
    exit(1);
  }
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as List<dynamic>;
  bool isKatex(dynamic e) =>
      (e as Map<String, dynamic>)['family'].toString().startsWith(marker) ||
      (e['fonts'] as List<dynamic>)
          .any((f) => (f as Map)['asset'].toString().startsWith(marker));
  final katex = manifest.where(isKatex).toList();
  if (katex.isEmpty) {
    stderr.writeln('strip_katex_fonts: no $marker families in '
        '${manifestFile.path} — manifest layout changed? Refusing to guess.');
    exit(1);
  }
  var deleted = 0;
  for (final entry in katex) {
    for (final font in (entry as Map)['fonts'] as List<dynamic>) {
      final file = File('$buildDir/assets/${(font as Map)['asset']}');
      if (!file.existsSync()) {
        stderr.writeln('strip_katex_fonts: listed font missing: ${file.path}');
        exit(1);
      }
      file.deleteSync();
      deleted++;
    }
  }
  // The package ships nothing but these fonts; drop its now-empty asset tree.
  final pkgDir = Directory('$buildDir/assets/$marker');
  if (pkgDir.existsSync()) pkgDir.deleteSync(recursive: true);
  manifestFile.writeAsStringSync(
      jsonEncode(manifest.where((e) => !isKatex(e)).toList()));
  stdout.writeln('strip_katex_fonts: removed ${katex.length} families '
      '($deleted font files); ${manifest.length - katex.length} families kept');
}
