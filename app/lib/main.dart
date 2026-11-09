import 'dart:async';
import 'dart:io';

import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_controller.dart';
import 'src/ui/theme.dart';
import 'src/ui/home.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) return _mainAndroid();
  // Started by the autostart entry at login: stay in the tray until opened.
  final startMinimized = args.contains('--start-minimized');
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(1280, 820), minimumSize: Size(720, 520), title: 'agenda'),
    () async {
      if (!startMinimized) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  final settings = await AgendaSettings.load();
  final app = AppController(settings);
  unawaited(app.start());
  runApp(AgendaApp(app: app, startMinimized: startMinimized));
}

/// The phone: files in the app's private storage, synced with the desktop over the LAN.
Future<void> _mainAndroid() async {
  final support = (await getApplicationSupportDirectory()).path;
  AgendaPaths.homeOverride = support;
  final settings = await AgendaSettings.load();
  settings
    ..agendaDir = '$support/agenda'
    ..personalDir = '$support/personal';
  final app = AppController(settings)..listMode = true;
  unawaited(app.start());
  // Photos and files shared from other apps (WhatsApp, gallery, mail): pick a task for them.
  List<String> files(List<SharedMediaFile> xs) => [
    for (final x in xs)
      if (x.type != SharedMediaType.text && x.type != SharedMediaType.url) x.path,
  ];
  ReceiveSharingIntent.instance.getMediaStream().listen((xs) => app.receiveShares(files(xs)));
  unawaited(ReceiveSharingIntent.instance.getInitialMedia().then((xs) {
    app.receiveShares(files(xs));
    ReceiveSharingIntent.instance.reset();
  }));
  runApp(
    MaterialApp(
      title: 'agenda',
      debugShowCheckedModeBanner: false,
      theme: Ui.theme(),
      home: _Lifecycle(app: app, child: Home(app: app)),
    ),
  );
}

/// Syncs when the phone app comes back to the foreground.
class _Lifecycle extends StatefulWidget {
  const _Lifecycle({required this.app, required this.child});
  final AppController app;
  final Widget child;

  @override
  State<_Lifecycle> createState() => _LifecycleState();
}

class _LifecycleState extends State<_Lifecycle> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(widget.app.sync.syncNow());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AgendaApp extends StatefulWidget {
  const AgendaApp({super.key, required this.app, this.startMinimized = false});
  final AppController app;
  final bool startMinimized;

  @override
  State<AgendaApp> createState() => _AgendaAppState();
}

class _AgendaAppState extends State<AgendaApp> with WindowListener {
  final _tray = SystemTray();
  final _trayIcons = <String, String>{};
  bool _trayReady = false;
  int _trayCount = -1;
  bool _quitting = false;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    app.addListener(_refreshTray);
    unawaited(_initTray());
    if (widget.startMinimized) {
      WidgetsBinding.instance.addPostFrameCallback((_) => windowManager.hide());
    }
  }

  @override
  void dispose() {
    app.removeListener(_refreshTray);
    windowManager.removeListener(this);
    super.dispose();
  }

  // ---- tray ---------------------------------------------------------------

  Future<void> _initTray() async {
    // appindicator needs real files on disk, not bundled-asset URIs.
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/tray');
      await dir.create(recursive: true);
      for (final name in ['tray.png', for (var i = 1; i <= 9; i++) 'tray_$i.png', 'tray_9plus.png']) {
        final data = await rootBundle.load('assets/tray/$name');
        final f = File('${dir.path}/$name');
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        _trayIcons[name] = f.path;
      }
      await _tray.initSystemTray(title: 'agenda', iconPath: _trayIcons['tray.png']!, toolTip: 'agenda');
      final menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(label: 'Open agenda', onClicked: (_) => _show()),
        MenuItemLabel(label: 'Run check now', onClicked: (_) => app.runNow()),
        MenuSeparator(),
        MenuItemLabel(label: 'Quit', onClicked: (_) => _quit()),
      ]);
      await _tray.setContextMenu(menu);
      // On GNOME the shell turns tray clicks into the menu; other desktops send these.
      _tray.registerSystemTrayEventHandler((event) {
        if (event == kSystemTrayEventClick || event == kSystemTrayEventDoubleClick) {
          _show();
        } else if (event == kSystemTrayEventRightClick) {
          _tray.popUpContextMenu();
        }
      });
      _trayReady = true;
      _refreshTray();
    } on Object catch (e) {
      debugPrint('no tray: $e'); // the app still works from the dock
    }
  }

  void _refreshTray() {
    if (!_trayReady) return;
    final n = app.needsUserCount;
    if (n == _trayCount) return;
    _trayCount = n;
    final name = n <= 0 ? 'tray.png' : (n > 9 ? 'tray_9plus.png' : 'tray_$n.png');
    unawaited(() async {
      try {
        await _tray.setImage(_trayIcons[name]!);
        await _tray.setToolTip(n <= 0 ? 'agenda' : 'agenda: $n need you');
      } catch (_) {}
    }());
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    await app.shutdown();
    await _tray.destroy();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    if (_quitting) return;
    // Closing hides to the tray; background checks run regardless (systemd).
    await windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'agenda',
      debugShowCheckedModeBanner: false,
      theme: Ui.theme(),
      home: Home(app: app),
    );
  }
}
