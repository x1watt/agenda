import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'calendar_view.dart';
import 'dialogs.dart';
import 'file_view.dart';
import 'new_task_view.dart';
import 'personal_page.dart';
import 'recurring_page.dart';
import 'runs_page.dart';
import 'settings_page.dart';
import 'share_page.dart';
import 'task_list_view.dart';
import 'task_pane.dart';
import 'theme.dart';

/// Main window: calendar (or task list) on the left, the open task with its
/// chats on the right. Runs, settings, files and the new-task composer take
/// the whole window with a back button.
class Home extends StatefulWidget {
  const Home({super.key, required this.app});
  final AppController app;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  AppController get app => widget.app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.sync]),
      builder: (context, _) => Scaffold(
        backgroundColor: Ui.bg,
        body: SafeArea(
          child: AppController.isFullPage(app.selected)
              ? PopScope(canPop: false, onPopInvokedWithResult: (didPop, _) => didPop ? null : app.back(), child: _fullPage())
              : _twoPanes(),
        ),
      ),
    );
  }

  Widget _twoPanes() => LayoutBuilder(
    builder: (context, box) {
      // Narrow window: one pane at a time; a task or project replaces the calendar.
      // Narrow window or phone: one pane at a time; a task, project or chat replaces the calendar.
      if (box.maxWidth < 900) {
        final home = app.selected == 'general';
        return PopScope(
          canPop: home,
          onPopInvokedWithResult: (didPop, _) => didPop ? null : app.select('general'),
          child: home ? _LeftPane(app: app) : _rightPane(),
        );
      }
      final left = (box.maxWidth * app.settings.calendarSplit).clamp(420.0, box.maxWidth - 420);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: left,
            child: _LeftPane(app: app),
          ),
          Splitter(onDrag: (dx) => setState(() => app.settings.calendarSplit = ((left + dx) / box.maxWidth).clamp(0.3, 0.75)), onDragEnd: app.saveSettings),
          Expanded(child: _rightPane()),
        ],
      );
    },
  );

  /// One chat per project: the project tabs on top, then the open task, or the project's own chat.
  Widget _rightPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _ProjectTabs(app: app),
      Expanded(child: _paneBody()),
    ],
  );

  Widget _paneBody() {
    final node = app.selected;
    if (app.taskFor(node) case (final p, final t)?) return TaskPane(key: ValueKey(node), app: app, project: p, task: t);
    if (app.projectFor(node) case final p?) return ProjectPane(key: ValueKey(node), app: app, project: p);
    if (node != 'chat') {
      if (app.homeProject case final p?) return ProjectPane(key: ValueKey(projectNode(p)), app: app, project: p);
    }
    return GeneralPane(app: app);
  }

  Widget _fullPage() {
    final node = app.selected;
    if (node.startsWith('new:') && app.agenda?.projectById(node.substring(4)) != null) {
      return NewTaskView(key: ValueKey(node), app: app, project: app.agenda!.projectById(node.substring(4))!);
    }
    if (app.fileFor(node) case (final p, final t, final f)?) {
      return FileView(key: ValueKey(node), app: app, project: p, task: t, file: f);
    }
    final Widget page = switch (node) {
      'runs' => RunsPage(app: app),
      'settings' => SettingsPage(app: app),
      'personal' => PersonalPage(app: app),
      'recurring' => RecurringPage(app: app),
      'share' => SharePage(app: app),
      _ => const Center(
        child: Text('This item no longer exists.', style: TextStyle(color: Ui.muted)),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: app.back, icon: const Icon(Icons.arrow_back, size: 16), label: const Text('Back')),
          ),
        ),
        Expanded(child: page),
      ],
    );
  }
}

class _LeftPane extends StatelessWidget {
  const _LeftPane({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _build(context, box.maxWidth < 520));

  Widget _build(BuildContext context, bool narrow) {
    final projects = app.agenda?.projects ?? const <Project>[];
    return Container(
      color: Ui.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Row(
              children: [
                Image.asset('assets/icon.png', width: 20, height: 20),
                const SizedBox(width: 10),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [
                    ButtonSegment(value: false, icon: const Icon(Icons.calendar_month, size: 16), label: narrow ? null : const Text('Calendar'), tooltip: 'Calendar'),
                    ButtonSegment(value: true, icon: const Icon(Icons.checklist, size: 16), label: narrow ? null : const Text('Tasks'), tooltip: 'All tasks as a list'),
                  ],
                  selected: {app.listMode},
                  onSelectionChanged: (s) => app.setListMode(s.first),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: narrow ? 130 : 200),
                  child: PopupMenuButton<String>(
                    tooltip: 'Show one project',
                    onSelected: (v) {
                      app.setProjectFilter(v.isEmpty ? null : v);
                      // The right pane follows: that project's chat, unless one of its tasks is open.
                      final p = app.agenda?.projectById(v);
                      if (p != null && app.taskFor(app.selected)?.$1.id != p.id) app.select(projectNode(p));
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: '', checked: app.projectFilter == null, child: const Text('All projects')),
                      for (final p in projects) CheckedPopupMenuItem(value: p.id, checked: app.projectFilter == p.id, child: Text(p.title)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              app.projectFilter == null ? 'All projects' : (app.agenda?.projectById(app.projectFilter!)?.title ?? app.projectFilter!),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: app.projectFilter == null ? Ui.muted : Ui.accent),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, size: 18, color: Ui.muted),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                _AddMenu(app: app),
                _SystemMenu(app: app),
              ],
            ),
          ),
          if (app.agendaError != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Ui.danger.withValues(alpha: 0.1), borderRadius: Ui.roundedSmall),
              child: Text(
                'Some files did not load: ${app.agendaError}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Ui.danger, fontSize: 12),
              ),
            ),
          Expanded(
            child: app.listMode ? TaskListView(app: app) : CalendarView(app: app),
          ),
        ],
      ),
    );
  }
}

class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final projects = app.agenda?.projects ?? const <Project>[];
    return PopupMenuButton<String>(
      tooltip: 'Add',
      icon: const Icon(Icons.add, color: Ui.accent),
      onSelected: (v) async {
        if (v == 'event') {
          final r = await eventDialog(context, date: DateTime.now(), tasks: app.visibleTasks.where((e) => e.$2.isOpen).toList());
          if (r is EventSave) await app.saveEvent(r.event);
        } else if (v == 'project') {
          final r = await projectDialog(context);
          if (r == null) return;
          final parts = r.split('\n');
          await app.createProject(parts[0], parts[1]);
        } else {
          app.select(AppController.newTaskNode(v));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'event',
          child: ListTile(dense: true, leading: Icon(Icons.event, size: 18), title: Text('New event')),
        ),
        const PopupMenuDivider(),
        for (final p in projects.where((p) => app.projectFilter == null || p.id == app.projectFilter))
          PopupMenuItem(
            value: p.id,
            child: ListTile(dense: true, leading: const Icon(Icons.task_alt, size: 18), title: Text('New task in ${p.title}')),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'project',
          child: ListTile(dense: true, leading: Icon(Icons.create_new_folder_outlined, size: 18), title: Text('New project')),
        ),
      ],
    );
  }
}

/// Conversations, background runs and settings, plus the mail and checker state.
class _SystemMenu extends StatelessWidget {
  const _SystemMenu({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final lastRun = app.runs.firstOrNull;
    final sync = app.sync;
    final last = sync.lastAnySuccess;
    final phoneOk = last != null && DateTime.now().difference(last) < const Duration(minutes: 10);
    final healthy = AppController.isMobile ? phoneOk : app.bridgeUp && app.timerOn && (lastRun == null || lastRun.ended == null || lastRun.ok);
    final status = AppController.isMobile
        ? sync.status
        : [
            app.bridgeUp ? 'Mail connected' : 'Mail Bridge off',
            sync.status,
            app.timerOn ? (app.nextCheck == null ? 'Checking...' : 'Next check ${fmtTime(app.nextCheck!)}') : 'Background checks off',
            if (lastRun != null) 'Last run ${ago(lastRun.started)}${lastRun.ended == null ? ' (running)' : (lastRun.ok ? '' : ' (failed)')}',
          ].join('\n');
    return PopupMenuButton<String>(
      tooltip: status,
      icon: Badge(backgroundColor: healthy ? Ui.ok : Ui.danger, smallSize: 7, child: const Icon(Icons.settings_outlined, size: 20)),
      onSelected: (v) => v == 'run' ? app.runNow() : app.select(v),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text(status, style: const TextStyle(fontSize: 12, color: Ui.muted)),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'chat', child: Text('Chat across projects')),
        const PopupMenuItem(value: 'personal', child: Text('Personal info')),
        const PopupMenuItem(value: 'recurring', child: Text('Recurring')),
        if (!AppController.isMobile) ...[
          PopupMenuItem(value: 'run', enabled: !app.runInProgress, child: Text(app.runInProgress ? 'Check running...' : 'Run check now')),
          const PopupMenuItem(value: 'runs', child: Text('Background runs')),
        ],
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
      ],
    );
  }
}

/// A tab per project (each with its own chat) and one for chats across projects.
class _ProjectTabs extends StatelessWidget {
  const _ProjectTabs({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final projects = app.agenda?.projects ?? const <Project>[];
    final current = app.paneProject;
    Widget tab(String label, bool selected, VoidCallback onTap) => InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? Ui.accent : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: selected ? Ui.text : Ui.muted, fontWeight: selected ? FontWeight.w700 : FontWeight.normal),
        ),
      ),
    );
    return Container(
      height: 38,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Ui.border))),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final p in projects)
            // On a task, its project's tab goes back to the project chat.
            tab(p.title.split(':').first.trim(), p.id == current, () => app.select(projectNode(p))),
          tab('Across projects', current == null, () => app.select('chat')),
        ],
      ),
    );
  }
}
