import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Anthropic API key: a mode-600 file in accounts/ on the desktop, the
/// Android Keystore on the phone. Never written to a synced folder.
class Secrets {
  static const _storage = FlutterSecureStorage();
  static const _key = 'anthropic_api_key';

  static Future<String?> apiKey(AgendaSettings s) async {
    if (Platform.isAndroid) return _storage.read(key: _key);
    final f = File(s.paths.apiKeyFile);
    if (!await f.exists()) return null;
    final k = (await f.readAsString()).trim();
    return k.isEmpty ? null : k;
  }

  static Future<void> setApiKey(AgendaSettings s, String? key) async {
    final k = key?.trim() ?? '';
    if (Platform.isAndroid) {
      k.isEmpty ? await _storage.delete(key: _key) : await _storage.write(key: _key, value: k);
      return;
    }
    final f = File(s.paths.apiKeyFile);
    if (k.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsString('$k\n');
    await Process.run('chmod', ['600', f.path]);
  }
}
