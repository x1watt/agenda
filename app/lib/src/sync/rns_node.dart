/// The Reticulum node of this device: TCP uplinks to the public hubs (re-dialed
/// every 30 s) plus LAN UDP, an `agenda/sync` announce that binds the account's
/// npub to this device's Reticulum identity, and LXMF (end-to-end encrypted over
/// links, large messages as Resources) to carry the sync messages.
///
/// Adapted from senhorio (lib/sync/rns_node.dart). Differences: only nodes that
/// prove they hold *our* nsec are peers (all devices of one account), every
/// message goes to one device (not to every device of an npub), and the announce
/// carries the device name.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:reticulum/reticulum.dart' hide debugPrint;
// The LAN interface is not exported by the package (as of 2ad7030); senhorio uses it too.
// ignore: implementation_imports
import 'package:reticulum/src/services/reticulum/rns_lan_interface.dart';

import '../identity/identity.dart';

const kSyncApp = 'agenda';
const kSyncAspects = ['sync'];
const kSyncTitle = 'agenda/1';

/// Public hubs (the same defaults as senhorio).
const defaultHubs = [
  'rns.wisco.network:4242',
  'sydney.reticulum.au:4242',
  'rns.birdsnet.com.br:4242',
  'use.inertia.chat:4242',
];

const _lanPort = 42672;

/// Longest device name carried in the announce, in UTF-8 bytes.
const _maxName = 32;

/// Another device of this account.
class DevicePeer {
  DevicePeer(this.id, this.identity, this.lxmfDest, this.name, this.lastSeen, this.via);

  /// Hex hash of the device's Reticulum identity: stable per device.
  final String id;
  final RnsIdentity identity;
  final Uint8List lxmfDest;
  String name;
  DateTime lastSeen;
  String via;
}

String hexOf(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List bytesOfHex(String h) =>
    Uint8List.fromList([for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

class RnsNode extends ChangeNotifier {
  RnsNode({
    required this.account,
    required this.keys,
    required this.deviceName,
    required this.onMessage,
    required this.onPeer,
    this.hubs = defaultHubs,
  });

  final Identity account;
  final KeyStore keys;
  final String deviceName;
  List<String> hubs;

  /// A sync message from device [peerId].
  final void Function(String peerId, Map<String, Object?> msg) onMessage;

  /// Device [peerId] announced itself (first time or again).
  final void Function(String peerId) onPeer;

  RnsTransportClient? _transport;
  RnsIdentity? _id;
  LxmfRouter? _lxmf;
  final _tcp = <String, RnsTcpInterface>{};
  RnsLanInterface? _lan;
  Timer? _tick;
  Timer? _reannounce;
  DateTime _lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);

  /// The other devices of this account, by device id.
  final peers = <String, DevicePeer>{};
  final _byLxmf = <String, String>{}; // lxmf dest hex -> device id
  final _seen = <String>{};
  final logLines = <String>[];
  bool running = false;

  /// Announce names never shed by the transport's flood budget.
  static List<String> get priorityNames => [
    hexOf(RnsDestination.nameHash(kSyncApp, kSyncAspects)),
    hexOf(RnsDestination.nameHash(kLxmfApp, kLxmfDeliveryAspects)),
  ];

  /// Logs the transport engine too (debugging).
  static bool verbose = false;

  /// This device's id (hex hash of its Reticulum identity), once started.
  String? get deviceId => _id?.hexHash;
  Iterable<String> get connectedHubs => _tcp.entries.where((e) => e.value.isConnected).map((e) => e.key);
  bool get lanUp => _lan != null;

  void log(String s) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
    logLines.add(line);
    if (logLines.length > 300) logLines.removeAt(0);
    debugPrint('RNS $s');
    notifyListeners();
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> start() async {
    if (running) return;
    running = true;
    _id = await _loadIdentity();
    final t = await RnsTransportClient.spawn(log: verbose ? (m) => log('tx: $m') : null);
    _transport = t;
    t.onAnnounce = _onAnnounce;
    t.onPathRequest = (h) {
      if (_isOurs(h)) unawaited(announce(force: true));
    };
    t.setPriorityAnnounceNames(priorityNames);
    _lxmf = LxmfRouter(
      identity: _id!,
      send: (raw) => _transport?.sendLinkAware(raw),
      nextHopFor: (peer) => _transport?.nextHopForIdentity(peer),
      identityForDest: (h) => _transport?.pathFor(h)?.identity ?? _identityForLxmf(h),
      requestPath: (h) => _transport?.requestPath(h),
      onMessage: _onLxmf,
      log: verbose ? (m) => log('lxmf: $m') : null,
    );
    await _bindLan();
    await _connectHubs();
    await announce(force: true);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => tick());
    log('node up, device ${_id!.hexHash.substring(0, 12)}');
  }

  Future<void> stop() async {
    running = false;
    _tick?.cancel();
    _reannounce?.cancel();
    for (final i in _tcp.values) {
      await i.close();
    }
    _tcp.clear();
    await _lan?.close();
    _lan = null;
    _transport?.close();
    _transport = null;
    notifyListeners();
  }

  Future<RnsIdentity> _loadIdentity() async {
    final s = await keys.read('agenda_rns_identity');
    if (s != null && s.length == 128) return RnsIdentity.fromPrivateKey(bytesOfHex(s));
    final id = await RnsIdentity.generate();
    await keys.write('agenda_rns_identity', hexOf(id.getPrivateKey()!));
    return id;
  }

  Future<void> _bindLan() async {
    try {
      final lan = RnsLanInterface(port: _lanPort, onPacket: (raw) => _onInbound(raw, 'lan'));
      await lan.bind();
      _transport!.addInterface(lan);
      _lan = lan;
    } catch (e) {
      log('lan: $e');
    }
  }

  Future<void> _connectHubs() async {
    for (final h in hubs) {
      final cur = _tcp[h];
      if (cur != null && cur.isConnected) continue;
      if (cur != null) {
        _transport?.removeInterface(cur);
        _tcp.remove(h);
      }
      final parts = h.split(':');
      final host = parts.first;
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 4242 : 4242;
      final label = 'tcp:$host:$port';
      final iface = RnsTcpInterface(
        host: host,
        port: port,
        label: label,
        uplink: true,
        onPacket: (raw) => _onInbound(raw, label),
        onDisconnect: () {
          log('hub down $h');
          notifyListeners();
        },
      );
      try {
        await iface.connect(timeout: const Duration(seconds: 8));
        _transport?.addInterface(iface);
        _tcp[h] = iface;
        log('hub up $h');
      } catch (e) {
        log('hub $h unreachable');
      }
    }
    notifyListeners();
  }

  /// Reconnects dropped hubs and re-announces when due.
  Future<void> tick() async {
    if (!running) return;
    await _connectHubs();
    await announce();
  }

  // ---------------------------------------------------------------- announce

  bool _isOurs(Uint8List h) {
    final id = _id;
    if (id == null) return false;
    return _eq(h, RnsDestination.hash(id, kSyncApp, kSyncAspects)) || _eq(h, RnsDestination.hash(id, kLxmfApp, kLxmfDeliveryAspects));
  }

  /// appData = npub pubkey (32) || schnorr(sha256("agenda-bind" || rns hash)) (64)
  ///           || device name (UTF-8, at most 32 bytes; covered by the announce signature)
  Uint8List _bindingAppData() {
    final pk = bytesOfHex(account.pubkey);
    final sig = bytesOfHex(account.sign(_bindDigest(_id!.hash)));
    var name = utf8.encode(deviceName);
    if (name.length > _maxName) name = utf8.encode(utf8.decode(name.sublist(0, _maxName), allowMalformed: true).replaceAll('�', ''));
    return Uint8List.fromList([...pk, ...sig, ...name]);
  }

  static String _bindDigest(Uint8List rnsHash) => sha256.convert([...utf8.encode('agenda-bind'), ...rnsHash]).toString();

  /// Announces the sync and LXMF destinations (at most every 5 minutes unless [force]).
  Future<void> announce({bool force = false}) async {
    final t = _transport;
    final id = _id;
    if (t == null || id == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastAnnounce) < const Duration(minutes: 5)) return;
    _lastAnnounce = now;
    final a = await RnsAnnounceBuilder.build(id, kSyncApp, kSyncAspects, appData: _bindingAppData());
    t.sendAnnounce(a.pack(), a.destHash);
    final lx = await RnsAnnounceBuilder.build(id, kLxmfApp, kLxmfDeliveryAspects, appData: Uint8List.fromList(utf8.encode('agenda')));
    t.sendAnnounce(lx.pack(), lx.destHash);
  }

  /// One forced announce, at least 5 s after the previous one.
  void _reannounceSoon() {
    if (_reannounce?.isActive ?? false) return;
    final since = DateTime.now().difference(_lastAnnounce);
    const gap = Duration(seconds: 5);
    _reannounce = Timer(since >= gap ? Duration.zero : gap - since, () => announce(force: true));
  }

  void _onAnnounce(RnsAnnounce ann, int hops, String via) {
    final id = _id;
    if (id == null || _eq(ann.identity.hash, id.hash)) return;
    if (!_eq(ann.destHash, RnsDestination.hash(ann.identity, kSyncApp, kSyncAspects))) return;
    final ad = ann.appData;
    if (ad.length < 96 || ad.length > 96 + _maxName) return;
    final pk = hexOf(ad.sublist(0, 32));
    if (pk != account.pubkey) return; // another account: not ours to sync with
    bool ok;
    try {
      ok = NostrCrypto.schnorrVerify(_bindDigest(ann.identity.hash), hexOf(ad.sublist(32, 96)), pk);
    } catch (_) {
      ok = false;
    }
    if (!ok) return;
    final lx = RnsDestination.hash(ann.identity, kLxmfApp, kLxmfDeliveryAspects);
    final devId = ann.identity.hexHash;
    final name = utf8.decode(ad.sublist(96), allowMalformed: true);
    final known = peers[devId];
    if (known == null) {
      peers[devId] = DevicePeer(devId, ann.identity, lx, name, DateTime.now(), via);
      log('device ${name.isEmpty ? devId.substring(0, 8) : name} via $via');
      // A newcomer missed our last announce: answer so it learns us now.
      _reannounceSoon();
    } else {
      known
        ..name = name
        ..lastSeen = DateTime.now()
        ..via = via;
    }
    _byLxmf[hexOf(lx)] = devId;
    notifyListeners();
    onPeer(devId);
  }

  RnsIdentity? _identityForLxmf(Uint8List h) => peers[_byLxmf[hexOf(h)]]?.identity;

  // ---------------------------------------------------------------- traffic

  Future<void> _onInbound(Uint8List raw, String via) async {
    final p = RnsPacket.parse(raw);
    if (p == null) return;
    if (p.destType == RnsDestType.link) _transport?.noteLinkIface(p.destHash, via);
    if (p.packetType != RnsPacketType.announce) {
      try {
        if (await _lxmf?.handlePacket(p) ?? false) return;
      } catch (e) {
        log('lxmf: $e');
        return;
      }
    }
    _transport?.ingestRaw(raw, via);
  }

  void _onLxmf(LxmfMessage m) {
    if (m.titleString != kSyncTitle) return;
    final key = hexOf(m.hash);
    if (!_seen.add(key)) return;
    if (_seen.length > 4096) _seen.remove(_seen.first);
    // sourceHash is the sender's LXMF delivery destination; only verified devices of this account are known.
    final devId = _byLxmf[hexOf(m.sourceHash)];
    if (devId == null) {
      log('message from an unknown node dropped');
      return;
    }
    try {
      onMessage(devId, (jsonDecode(m.contentString) as Map).cast<String, Object?>());
    } catch (e) {
      log('bad message: $e');
    }
  }

  /// Sends [msg] to device [peerId] (encrypted LXMF over a link); true when it confirmed.
  Future<bool> send(String peerId, Map<String, Object?> msg, {Duration timeout = const Duration(seconds: 90)}) async {
    final id = _id;
    final p = peers[peerId];
    if (id == null || _lxmf == null || p == null) return false;
    final m = await LxmfMessage.create(destinationHash: p.lxmfDest, source: id, title: kSyncTitle, content: jsonEncode(msg));
    final r = await _lxmf!.deliver(m, timeout: timeout);
    if (r != LxmfDelivery.confirmed) log('send to ${p.name}: ${r.name}');
    return r == LxmfDelivery.confirmed;
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
