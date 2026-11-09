import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';

/// The mailbox the Bridge serves, read from `accounts/protonmail-bridge.user`:
/// one line, either `Name <address>` or the bare address. The environment
/// variable `AGENDA_MAIL_USER` takes precedence over the file.
class BridgeAccount {
  const BridgeAccount({required this.address, this.name});

  final String address;

  /// Display name for outgoing mail, when the line carries one.
  final String? name;

  /// Host part of the address, used as the SMTP EHLO name.
  String get domain => address.split('@').last;

  static String file(String accountsDir) => '$accountsDir/protonmail-bridge.user';

  static Future<BridgeAccount> load(String accountsDir) async {
    var line = Platform.environment['AGENDA_MAIL_USER']?.trim() ?? '';
    if (line.isEmpty) {
      final f = File(file(accountsDir));
      if (await f.exists()) line = (await f.readAsString()).trim();
    }
    if (line.isEmpty) {
      throw StateError('no mail account configured: write "Name <address>" into '
          '${file(accountsDir)} or set AGENDA_MAIL_USER');
    }
    final m = RegExp(r'^(.*?)\s*<([^>]+)>$').firstMatch(line);
    if (m == null) return BridgeAccount(address: line);
    final name = m.group(1)!.trim();
    return BridgeAccount(address: m.group(2)!.trim(), name: name.isEmpty ? null : name);
  }
}

/// Read-only access to the Proton mailbox through the local Proton Mail Bridge.
///
/// Folders are opened with EXAMINE and bodies fetched with BODY.PEEK, so nothing
/// is marked as read, moved or deleted. Credentials live in agenda/accounts:
/// `protonmail-bridge.pass` (Bridge-generated IMAP password),
/// `protonmail-bridge-cert.pem` (Bridge's self-signed TLS certificate) and
/// `protonmail-bridge.user` (the mail address, see [BridgeAccount]).
class BridgeMail {
  BridgeMail._(this._client);

  static const host = '127.0.0.1';
  static const port = 1143;

  final ImapClient _client;
  static bool _certTrusted = false;

  /// True when Bridge accepts TCP connections on the IMAP port.
  static Future<bool> reachable() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  static Future<BridgeMail> connect(String accountsDir, {bool debug = false}) async {
    final account = await BridgeAccount.load(accountsDir);
    final password = (await File('$accountsDir/protonmail-bridge.pass').readAsString()).trim();
    // enough_mail's STARTTLS ignores onBadCertificate, so trust Bridge's
    // exported certificate explicitly (once per process).
    if (!_certTrusted) {
      SecurityContext.defaultContext
          .setTrustedCertificates('$accountsDir/protonmail-bridge-cert.pem');
      _certTrusted = true;
    }
    final client = ImapClient(isLogEnabled: debug);
    await client.connectToServer(host, port, isSecure: false);
    await client.startTls();
    await client.login(account.address, password);
    return BridgeMail._(client);
  }

  Future<List<String>> folders() async =>
      [for (final b in await _client.listMailboxes(recursive: true)) b.path];

  Future<void> open(String folder) async {
    final boxes = await _client.listMailboxes(recursive: true);
    final box = boxes.where((b) => b.path == folder || b.name == folder).firstOrNull;
    if (box == null) throw StateError('no folder $folder');
    await _client.examineMailbox(box);
  }

  /// UIDs matching an IMAP SEARCH [criteria] in the open folder.
  Future<List<int>> search(String criteria) async {
    final r = await _client.uidSearchMessages(searchCriteria: criteria);
    final seq = r.matchingSequence;
    return seq != null && seq.isNotEmpty ? seq.toList() : const [];
  }

  /// Headers for [uids], newest first by INTERNALDATE.
  Future<List<MailHeader>> headers(List<int> uids) async {
    if (uids.isEmpty) return const [];
    final r = await _client.uidFetchMessages(
      MessageSequence.fromIds(uids, isUid: true),
      '(UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])',
    );
    final out = [
      for (final m in r.messages)
        MailHeader(
          uid: m.uid ?? 0,
          date: parseInternalDate(m.internalDate) ?? m.decodeDate()?.toLocal(),
          from: _oneLine(m.from?.map((a) => a.toString()).join(', ')),
          subject: _oneLine(m.decodeSubject()),
        ),
    ]..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    return out;
  }

  Future<MailMessage?> message(int uid) async {
    final r = await _client.uidFetchMessage(uid, 'BODY.PEEK[]');
    if (r.messages.isEmpty) return null;
    final m = r.messages.first;
    return MailMessage(
      from: m.from?.join(', ') ?? '',
      to: m.to?.join(', ') ?? '',
      date: m.decodeDate()?.toLocal(),
      subject: m.decodeSubject() ?? '',
      attachments: [
        for (final c in m.findContentInfo(disposition: ContentDisposition.attachment))
          c.fileName ?? '?',
      ],
      body: m.decodeTextPlainPart() ?? m.decodeTextHtmlPart() ?? m.decodeContentText() ?? '',
    );
  }

  /// Writes the attachments of message [uid] into [dir]; returns the file paths.
  Future<List<String>> saveAttachments(int uid, String dir) async {
    final r = await _client.uidFetchMessage(uid, 'BODY.PEEK[]');
    if (r.messages.isEmpty) return [];
    final m = r.messages.first;
    final out = <String>[];
    for (final c in m.findContentInfo(disposition: ContentDisposition.attachment)) {
      final part = m.getPart(c.fetchId);
      final data = part?.decodeContentBinary();
      if (data == null) continue;
      final name = (c.fileName ?? 'attachment-${out.length + 1}').replaceAll('/', '_');
      final f = File('$dir/$name');
      await f.writeAsBytes(data);
      out.add(f.path);
    }
    return out;
  }

  Future<void> close() async {
    try {
      await _client.logout();
    } catch (_) {
      // Bridge may already have dropped the connection.
    }
  }
}

class MailHeader {
  MailHeader({required this.uid, this.date, required this.from, required this.subject});
  final int uid;
  final DateTime? date;
  final String from;
  final String subject;
}

class MailMessage {
  MailMessage({
    required this.from,
    required this.to,
    this.date,
    required this.subject,
    required this.attachments,
    required this.body,
  });
  final String from;
  final String to;
  final DateTime? date;
  final String subject;
  final List<String> attachments;
  final String body;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// IMAP date for SEARCH, e.g. 11-Sep-2026.
String imapDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${_months[d.month - 1]}-${d.year}';

/// One SEARCH matching mail from any of [senders] (nested ORs), e.g.
/// `OR FROM "a" OR FROM "b" FROM "c"`.
String fromAnyCriteria(List<String> senders) {
  if (senders.isEmpty) throw ArgumentError('no senders');
  final last = 'FROM ${imapQuote(senders.last)}';
  return senders.reversed.skip(1).fold(last, (acc, s) => 'OR FROM ${imapQuote(s)} $acc');
}

/// Sending through the local Proton Mail Bridge SMTP port.
///
/// Separate from [BridgeMail], which never writes. Sending is always an explicit
/// user request: nothing in the background checker calls this.
///
/// The SMTP dialogue is done by hand over a socket. enough_mail builds the MIME
/// message, but its own SmtpClient hangs after STARTTLS against Bridge.
class BridgeSmtp {
  static const host = '127.0.0.1';
  static const port = 1025;

  /// Sends a plain text message, with optional file [attachments] (paths), and
  /// returns the server's final response. [fromName] overrides the display name
  /// of the configured account.
  static Future<String> send({
    required String accountsDir,
    String? fromName,
    required List<String> to,
    required String subject,
    required String body,
    List<String> cc = const [],
    List<String> attachments = const [],
    bool debug = false,
  }) async {
    if (to.isEmpty) throw ArgumentError('no recipient');
    final account = await BridgeAccount.load(accountsDir);
    final user = account.address;
    final password = (await File('$accountsDir/protonmail-bridge.pass').readAsString()).trim();

    final MessageBuilder builder;
    if (attachments.isEmpty) {
      builder = MessageBuilder()
        ..text = body
        ..setContentType(MediaSubtype.textPlain.mediaType, characterSet: CharacterSet.utf8);
    } else {
      builder = MessageBuilder.prepareMultipartMixedMessage()..addTextPlain(body);
      for (final path in attachments) {
        await builder.addFile(File(path), MediaType.guessFromFileName(path));
      }
    }
    builder
      ..from = [MailAddress(fromName ?? account.name, user)]
      ..to = [for (final a in to) MailAddress(null, a.trim())]
      ..cc = [for (final a in cc) MailAddress(null, a.trim())]
      ..subject = subject;
    final mime = builder.buildMimeMessage().renderMessage();

    final session = _SmtpSession(
      await Socket.connect(host, port, timeout: const Duration(seconds: 10)),
      debug: debug,
    );
    try {
      await session.expect('220');
      await session.cmd('EHLO ${account.domain}', '250');
      await session.cmd('STARTTLS', '220');
      await session.upgrade(certFile: '$accountsDir/protonmail-bridge-cert.pem');
      await session.cmd('EHLO ${account.domain}', '250');
      final plain = base64.encode(utf8.encode('\u0000$user\u0000$password'));
      await session.cmd('AUTH PLAIN $plain', '235', secret: true);
      await session.cmd('MAIL FROM:<$user>', '250');
      for (final rcpt in [...to, ...cc]) {
        await session.cmd('RCPT TO:<${rcpt.trim()}>', '250');
      }
      await session.cmd('DATA', '354');
      final dotted = mime
          .split(RegExp(r'\r?\n'))
          .map((l) => l.startsWith('.') ? '.$l' : l)
          .join('\r\n');
      final result = await session.cmd('$dotted\r\n.', '250');
      await session.cmd('QUIT', '221');
      return result;
    } finally {
      session.close();
    }
  }
}

/// One SMTP conversation: write a line, wait for the reply code.
class _SmtpSession {
  _SmtpSession(this._socket, {this.debug = false}) {
    _listen(_socket);
  }

  Socket _socket;
  final bool debug;
  var _buffer = '';
  Completer<String>? _waiting;

  void _listen(Socket s) {
    s.listen((data) {
      _buffer += utf8.decode(data, allowMalformed: true);
      // A reply ends with "NNN <text>", a hyphen after the code means more lines.
      final lines = _buffer.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty) return;
      final last = lines.last;
      if (RegExp(r'^\d{3} ').hasMatch(last)) {
        if (debug) for (final l in lines) stderr.writeln('S: $l');
        final reply = _buffer;
        _buffer = '';
        _waiting?.complete(reply.trim());
        _waiting = null;
      }
    }, onError: (Object e) => _waiting?.completeError(e));
  }

  Future<String> _read() {
    final c = Completer<String>();
    _waiting = c;
    return c.future.timeout(const Duration(seconds: 30));
  }

  Future<String> expect(String code) async {
    final reply = await _read();
    if (!reply.startsWith(code)) throw StateError('SMTP: expected $code, got $reply');
    return reply;
  }

  Future<String> cmd(String line, String code, {bool secret = false}) async {
    if (debug) stderr.writeln('C: ${secret ? line.split(' ').first + ' ***' : line}');
    final pending = _read();
    _socket.write('$line\r\n');
    await _socket.flush();
    final reply = await pending;
    if (!reply.startsWith(code)) throw StateError('SMTP: expected $code, got $reply');
    return reply;
  }

  /// STARTTLS: wrap the plain socket, trusting Bridge's exported certificate.
  Future<void> upgrade({required String certFile}) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certFile);
    _socket = await SecureSocket.secure(_socket, host: BridgeSmtp.host, context: context);
    _buffer = '';
    _listen(_socket);
  }

  void close() {
    try {
      _socket.destroy();
    } catch (_) {}
  }
}

/// IMAP-quoted string.
String imapQuote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Parses an INTERNALDATE like "11-Sep-2026 13:50:00 +0000" into local time.
DateTime? parseInternalDate(String? s) {
  final m = RegExp(r'(\d{1,2})-(\w{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})')
      .firstMatch(s?.trim() ?? '');
  if (m == null) return null;
  final utc = DateTime.utc(int.parse(m[3]!), _months.indexOf(m[2]!) + 1, int.parse(m[1]!),
      int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
  final offset = Duration(hours: int.parse(m[8]!), minutes: int.parse(m[9]!));
  return (m[7] == '+' ? utc.subtract(offset) : utc.add(offset)).toLocal();
}

String _oneLine(String? s) => (s ?? '').split(RegExp(r'\s+')).join(' ').trim();
