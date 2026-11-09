import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Anthropic API key: a mode-600 file in accounts/, which syncs to every
/// device of the account (see SyncRoots). Older phone installs kept it in the
/// Android Keystore; it moves to the file on first read.
class Secrets {
  static const _storage = FlutterSecureStorage();
  static const _key = 'anthropic_api_key';

  static Future<String?> apiKey(AgendaSettings s) async {
    final f = File(s.paths.apiKeyFile);
    if (await f.exists()) {
      final k = (await f.readAsString()).trim();
      if (k.isNotEmpty) return k;
    }
    if (Platform.isAndroid) {
      final old = await _storage.read(key: _key);
      if (old != null && old.trim().isNotEmpty) {
        await setApiKey(s, old);
        await _storage.delete(key: _key);
        return old.trim();
      }
    }
    return null;
  }

  static Future<void> setApiKey(AgendaSettings s, String? key) async {
    final k = key?.trim() ?? '';
    final f = File(s.paths.apiKeyFile);
    if (k.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await writeBytesAtomic(f.path, '$k\n'.codeUnits, private: true);
  }
}
