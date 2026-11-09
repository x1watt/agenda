import 'package:agenda_core/agenda_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../system_integration.dart';

/// Palette and theme of the app: dark, quiet, rounded.
class Ui {
  static const bg = Color(0xFF0F1115);
  static const surface = Color(0xFF171A21);
  static const surface2 = Color(0xFF1E232C);
  static const surface3 = Color(0xFF262C37);
  static const border = Color(0xFF2A303B);
  static const text = Color(0xFFE6E9EF);
  static const muted = Color(0xFF8B94A5);
  static const faint = Color(0xFF5C6577);
  static const accent = Color(0xFF7AA2F7);
  static const accentSoft = Color(0xFF2B3B5E);
  static const ok = Color(0xFF9ECE6A);
  static const warn = Color(0xFFE0AF68);
  static const danger = Color(0xFFF7768E);
  static const purple = Color(0xFFBB9AF7);
  static const codeBg = Color(0xFF12151B);

  static const radius = 10.0;
  static final rounded = BorderRadius.circular(radius);
  static final roundedSmall = BorderRadius.circular(6);
  static const mono = TextStyle(fontFamily: 'DejaVu Sans Mono', fontFamilyFallback: ['monospace']);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
        primary: accent,
        onPrimary: bg,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: muted,
        surfaceContainerLow: surface2,
        surfaceContainerHighest: surface3,
        outline: border,
        outlineVariant: border,
        error: danger,
      ),
      scaffoldBackgroundColor: bg,
      canvasColor: surface,
      visualDensity: VisualDensity.compact,
      dividerColor: border,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text).copyWith(
            bodyMedium: const TextStyle(fontSize: 13, color: text, height: 1.4),
            bodySmall: const TextStyle(fontSize: 12, color: muted),
            titleMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: text),
            headlineSmall: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: text),
          ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          disabledForegroundColor: faint,
          textStyle: const TextStyle(fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: roundedSmall),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: bg,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: roundedSmall),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: border),
          textStyle: const TextStyle(fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: roundedSmall),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: muted)),
      popupMenuTheme: PopupMenuThemeData(
        color: surface2,
        textStyle: const TextStyle(color: text, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: roundedSmall, side: const BorderSide(color: border)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: rounded, side: const BorderSide(color: border)),
        titleTextStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
        contentTextStyle: const TextStyle(fontSize: 13, color: text),
      ),
      checkboxTheme: CheckboxThemeData(
        side: const BorderSide(color: muted, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? bg : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : surface3),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: surface2,
        hintStyle: const TextStyle(color: faint, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderSide: const BorderSide(color: border), borderRadius: roundedSmall),
        enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: border), borderRadius: roundedSmall),
        focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: accent), borderRadius: roundedSmall),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(color: surface3, borderRadius: roundedSmall),
        textStyle: const TextStyle(color: text, fontSize: 12),
      ),
      scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStateProperty.all(const Color(0xFF3A4352))),
      dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    );
  }
}

Color statusColor(TaskStatus s) => switch (s) {
  TaskStatus.needsUser => Ui.danger,
  TaskStatus.waiting => Ui.warn,
  TaskStatus.inProgress => Ui.accent,
  TaskStatus.todo => Ui.muted,
  TaskStatus.done => Ui.ok,
  TaskStatus.cancelled => Ui.faint,
};

IconData statusIcon(TaskStatus s) => switch (s) {
  TaskStatus.needsUser => Icons.front_hand_outlined,
  TaskStatus.waiting => Icons.hourglass_empty,
  TaskStatus.inProgress => Icons.play_circle_outline,
  TaskStatus.todo => Icons.circle_outlined,
  TaskStatus.done => Icons.check_circle_outline,
  TaskStatus.cancelled => Icons.cancel_outlined,
};

/// Board order: needs you, in progress, to do, waiting, done, cancelled; then priority, then due.
int taskOrder(AgendaTask a, AgendaTask b) {
  int rank(TaskStatus s) => switch (s) {
    TaskStatus.needsUser => 0,
    TaskStatus.inProgress => 1,
    TaskStatus.todo => 2,
    TaskStatus.waiting => 3,
    TaskStatus.done => 4,
    TaskStatus.cancelled => 5,
  };
  final r = rank(a.status).compareTo(rank(b.status));
  if (r != 0) return r;
  final p = a.priority.compareTo(b.priority);
  if (p != 0) return p;
  return (a.due ?? '9999').compareTo(b.due ?? '9999');
}

// ---- formatting -------------------------------------------------------------------

String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${two(d.day)}.${two(d.month)}.${d.year}';
String fmtShort(DateTime d) => '${two(d.day)}.${two(d.month)}.';
String fmtTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String fmtDateTime(DateTime d) => '${fmtDate(d)} ${fmtTime(d)}';

const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// `YYYY-MM-DD`, the day part of task and event dates.
String isoDay(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// ISO 8601 calendar week (KW): weeks start on Monday, week 1 holds the year's first Thursday.
int isoWeek(DateTime d) {
  final day = DateTime.utc(d.year, d.month, d.day);
  final thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  return (thursday.difference(DateTime.utc(thursday.year, 1, 1)).inDays ~/ 7) + 1;
}
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "Thu 24.09.", and the time when [withTime].
String fmtDay(DateTime d, {bool withTime = false}) => '${weekdayNames[d.weekday - 1]} ${fmtShort(d)}${withTime ? ' ${fmtTime(d)}' : ''}';

int daysUntil(DateTime d) {
  final n = DateTime.now();
  return DateTime(d.year, d.month, d.day).difference(DateTime(n.year, n.month, n.day)).inDays;
}

String relativeDay(DateTime d) {
  final days = daysUntil(d);
  return switch (days) {
    0 => 'today',
    1 => 'tomorrow',
    -1 => 'yesterday',
    > 1 => 'in $days days',
    _ => '${-days} days ago',
  };
}

/// "5 min ago", "2 h ago", or a date.
String ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return fmtDateTime(d);
}

// ---- building blocks --------------------------------------------------------------

/// Rounded surface with a hairline border.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.color, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Ui.surface,
        borderRadius: Ui.rounded,
        border: Border.all(color: Ui.border),
      ),
      // Its own Material, so list tiles inside paint above the fill.
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: Ui.rounded, child: box),
    );
  }
}

/// Small uppercase caption above a group.
class Caption extends StatelessWidget {
  const Caption(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.only(top: 18, bottom: 8)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: const TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: Ui.muted),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// Compact tag: an icon and a short text on a tinted background.
class Chip2 extends StatelessWidget {
  const Chip2(this.text, {super.key, this.icon, this.color = Ui.muted, this.onTap, this.tooltip, this.menu = true});
  final String text;
  final IconData? icon;
  final Color color;
  final VoidCallback? onTap;
  final String? tooltip;

  /// Show the small arrow that says a tap opens a choice.
  final bool menu;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          if (onTap != null && menu) ...[const SizedBox(width: 2), Icon(Icons.expand_more, size: 14, color: color)],
        ],
      ),
    );
    final wrapped = tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
    if (onTap == null) return wrapped;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(999), child: wrapped);
  }
}

/// Flat icon button with a label; icon only when [compact].
class Action2 extends StatelessWidget {
  const Action2({super.key, required this.icon, required this.label, this.onPressed, this.tooltip, this.compact = false, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool compact;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(onPressed: onPressed, tooltip: tooltip ?? label, iconSize: 18, icon: Icon(icon));
    }
    final b = primary
        ? FilledButton.icon(onPressed: onPressed, icon: Icon(icon, size: 16), label: Text(label))
        : TextButton.icon(onPressed: onPressed, icon: Icon(icon, size: 16), label: Text(label));
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// Tiny count badge.
class Badge2 extends StatelessWidget {
  const Badge2(this.count, {super.key, this.color = Ui.danger});
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => count <= 0
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
          child: Text('$count', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Ui.bg)),
        );
}

/// Markdown with the app's styling; links open externally.
class Md extends StatelessWidget {
  const Md(this.data, {super.key, this.selectable = true, this.size = 13, this.onLink});
  final String data;
  final bool selectable;
  final double size;

  /// Handles link taps instead of opening them externally.
  final void Function(String href)? onLink;

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: data,
    selectable: selectable,
    softLineBreak: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(fontSize: size, height: 1.45, color: Ui.text),
      listBullet: TextStyle(fontSize: size, color: Ui.text),
      code: Ui.mono.copyWith(fontSize: size - 0.5, backgroundColor: Ui.codeBg),
      codeblockDecoration: BoxDecoration(color: Ui.codeBg, borderRadius: Ui.roundedSmall),
      blockquoteDecoration: const BoxDecoration(
        color: Ui.surface2,
        border: Border(left: BorderSide(color: Ui.accent, width: 3)),
      ),
      tableBorder: TableBorder.all(color: Ui.border),
      h1: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Ui.text),
      h2: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Ui.text),
      h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Ui.text),
    ),
    onTapLink: (_, href, _) => href == null ? null : (onLink ?? SystemIntegration.openPath)(href),
  );
}

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: const TextStyle(color: Ui.muted)),
  );
}

/// Draggable vertical splitter between two panes.
class Splitter extends StatelessWidget {
  const Splitter({super.key, required this.onDrag, this.onDragEnd});
  final void Function(double dx) onDrag;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => onDragEnd?.call(),
      child: Container(width: 6, color: Ui.bg, child: const VerticalDivider(width: 6, thickness: 1, color: Ui.border)),
    ),
  );
}

/// Section header inside a page.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      spacing: 12,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: const TextStyle(fontSize: 12.5, color: Ui.muted)),
              ],
            ],
          ),
        ),
        if (actions.isNotEmpty) Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
      ],
    ),
  );
}
