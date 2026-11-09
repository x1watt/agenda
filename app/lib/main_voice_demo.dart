import 'dart:io';

import 'package:flutter/material.dart';

import 'src/ui/theme.dart';
import 'voice_demo/voice_demo_page.dart';

/// Separate entrypoint for the voice conversation PoC, isolated from the
/// agenda app: `flutter run -d linux -t lib/main_voice_demo.dart`.
/// Language defaults to English; set `VOICE_LANG=de` to switch back to German.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final modelsDir = '${Directory.current.path}/voice_models';
  final language = Platform.environment['VOICE_LANG'] ?? 'en';
  runApp(MaterialApp(
    title: 'Voice demo',
    debugShowCheckedModeBanner: false,
    theme: Ui.theme(),
    home: VoiceDemoPage(modelsDir: modelsDir, language: language),
  ));
}
