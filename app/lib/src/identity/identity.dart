/// The account: one NOSTR key pair (nsec/npub) installed on every device of the
/// user. Devices recognise each other by it: a Reticulum node only syncs with
/// nodes whose announce proves they hold the same nsec (see sync/rns_node.dart).
///
/// Lifted from senhorio (lib/identity/identity_service.dart): [KeyStore],
/// [SecureKeyStore], [Identity], [parsePubkey], [shortNpub].
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;

/// Where per-device secrets live (the Reticulum identity of this device).
abstract class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryKeyStore implements KeyStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Android Keystore / OS keychain, falling back to a 0600 file in [fallbackDir]
/// when the platform has no keyring (a Linux desktop without libsecret).
class SecureKeyStore implements KeyStore {
  SecureKeyStore(this.fallbackDir);

  final String fallbackDir;
  final _secure = const FlutterSecureStorage();
  bool _useFile = false;

  File _file(String key) => File('$fallbackDir/.$key.secret');

  @override
  Future<String?> read(String key) async {
    if (!_useFile) {
      try {
        final v = await _secure.read(key: key);
        if (v != null) return v;
      } catch (_) {
        _useFile = true;
      }
    }
    final f = _file(key);
    return await f.exists() ? (await f.readAsString()).trim() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    if (!_useFile) {
      try {
        await _secure.write(key: key, value: value);
        return;
      } catch (_) {
        _useFile = true;
      }
    }
    final f = _file(key);
    await f.parent.create(recursive: true);
    await f.writeAsString(value, flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}

class Identity {
  Identity(this.privateKeyHex) : pubkey = NostrCrypto.derivePublicKey(privateKeyHex);

  final String privateKeyHex;

  /// Hex, x-only.
  final String pubkey;

  String get npub => NostrCrypto.encodeNpub(pubkey);
  String get nsec => NostrCrypto.encodeNsec(privateKeyHex);

  /// BIP-340 signature of the hex [digest].
  String sign(String digest) => NostrCrypto.schnorrSign(digest, privateKeyHex);

  static Identity generate() => Identity(NostrCrypto.generateKeyPair().privateKeyHex);

  /// Accepts nsec1… or 64 hex chars.
  static Identity parse(String secret) {
    final s = secret.trim();
    if (s.startsWith('nsec1')) return Identity(NostrCrypto.decodeNsec(s));
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return Identity(s.toLowerCase());
    throw const FormatException('not an nsec');
  }
}

/// Accepts npub1… or 64 hex chars; returns the hex pubkey.
String parsePubkey(String input) {
  final s = input.trim();
  if (s.startsWith('npub1')) return NostrCrypto.decodeNpub(s);
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return s.toLowerCase();
  throw const FormatException('not an npub');
}

String shortNpub(String pubkeyHex) {
  final n = NostrCrypto.encodeNpub(pubkeyHex);
  return '${n.substring(0, 12)}…${n.substring(n.length - 6)}';
}

/// The account of this installation. The nsec is kept in `accounts/agenda.nsec`
/// (mode 600) so it travels with the other credentials, and mirrored in the OS
/// keystore so a device keeps its account even if that folder is lost.
class Account {
  Account({required this.accountsDir, required this.keys});

  final String accountsDir;
  final KeyStore keys;
  static const _kNsec = 'agenda_nsec';

  File get _file => File('$accountsDir/agenda.nsec');

  Identity? identity;

  /// Loads the account, creating one on the first run of the first device.
  Future<Identity> load() async {
    String? s;
    if (await _file.exists()) s = (await _file.readAsString()).trim();
    if (s == null || s.isEmpty) s = await keys.read(_kNsec);
    final id = s != null && s.isNotEmpty ? Identity.parse(s) : Identity.generate();
    await _store(id);
    return identity = id;
  }

  /// Replaces this device's account with [nsec], copied from another device.
  Future<Identity> import(String nsec) async {
    final id = Identity.parse(nsec);
    await _store(id);
    return identity = id;
  }

  Future<void> _store(Identity id) async {
    if (await keys.read(_kNsec) != id.nsec) await keys.write(_kNsec, id.nsec);
    final f = _file;
    // One exact form on every device, so the synced file never differs by a newline.
    if (await f.exists() && await f.readAsString() == '${id.nsec}\n') return;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp-$pid');
    await tmp.writeAsString('${id.nsec}\n', flush: true);
    if (Platform.isLinux || Platform.isMacOS) await Process.run('chmod', ['600', tmp.path]);
    await tmp.rename(f.path);
  }
}
