// Live smoke test of ClaudeChat against the real CLI (uses a few cents).
//   dart run tool/chat_smoke.dart <scratch-dir>
import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';

Future<void> main(List<String> args) async {
  final chat = ClaudeChat(cwd: args.first, model: 'haiku');
  final results = <ResultEvent>[];
  var deltas = 0;
  chat.events.listen((e) {
    if (e is TextDeltaEvent) deltas++;
    if (e is ResultEvent) results.add(e);
    if (e is ProcessErrorEvent) stderr.writeln('ERROR ${e.message}');
  });
  Future<void> turn(String text) async {
    final n = results.length;
    await chat.send(text);
    while (results.length == n) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    print('> $text\n< ${results.last.text} (session ${chat.sessionId}, deltas so far $deltas)');
  }

  await turn('Remember the number 417. Reply only: ok');
  await turn('What number? Reply only the number.');
  await chat.stop(); // process ends; next send resumes the session
  await turn('Say the number once more, only the number.');
  await chat.dispose();
  exit(0);
}
