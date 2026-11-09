# Reusable code

Pieces worth reusing before writing new code, and duplicates worth folding together.
Keep this list current when adding features.

## core/ (shared by app, checker and CLI tools)

### JSON files on disk — `core/lib/src/store.dart`
- `updateJsonFile(path, edit)` — serialised (per-path chain), atomic read-modify-write of any JSON file.
  Every mutation should go through this (or the wrappers below), never a raw write.
- `updateTask`, `updateProject`, `updateGeneral`, `updateNode(agenda, node, edit)` — wrappers per file kind.
- `appendHistory(jsonPath, text)` — the required dated history line for any change.
- `appendConversation`, `addThread`, `archiveThread`, `restoreThread`.
- `editTaskFields(task, changes)` — generic field edit with history line.
- `validateTaskJson`, `validateProjectJson`, `validateEventsJson`, `validateRecurringJson`.
- `encodeJson(map)` — two-space indent + trailing newline (the format rule).
- Pattern for root-level list files: `_updateEvents` / `_updateRecurring` — copy this shape for any new
  `<name>.json` at the agenda root.

### Paths and writes — `core/lib/src/paths.dart`
- `writeAtomic(path, contents)` (text), `writeBytesAtomic(path, bytes)` in `sync/sync_server.dart` (binary).
- `normalizePath`, `relativeTo(from, to)`.

### Ids — `core/lib/src/ids.dart`
- `generateUid(taken)`, `takenUids(projectsDir)`, `slugFor(name)`, `taskFolderName(uid, name)`.
- `todayIso()`, `nowIso()`.

### Model helpers — `core/lib/src/model.dart`
- `listOfMaps(v)` — safe JSON list-of-objects reader for `fromJson`.
- `Agenda.allTasks`, `taskByUid`, `projectById`, `upcoming()`, `overdue()`, `conversationOf(node)`,
  `jsonPathForNode(node)`.
- Node keys: `general`, `project:<id>`, `task:<uid>` (`AgendaTask.node`, `Project.node`).
- `RecurringItem.nextOccurrenceAfter` / `_addMonths` — month arithmetic clamped to month end.

### Claude — `core/lib/src/claude_process.dart`, `sessions.dart`
- `ChatEngine` interface (implemented by `ClaudeChat` on desktop and `ApiChat` on the phone).
- `runClaudeOnce(...)` — one unattended run (used by the checker).
- `parseStreamLine`, `toolSummary`, `parseTranscript`, `listSessions`.

### Sync between devices — `core/lib/src/sync/`
- `SyncTransport` / `RequestTransport(call)` — file sync over any request/reply channel (chunked).
  Tests use a direct call to a `SyncHost`; the app uses LXMF. New transports only need a `SyncCall`.
- `SyncHost(roots)` — answers `manifest/get/put/delete` with compare-and-swap writes.
- `SyncSession` — three-way sync with one peer (per-peer base under its `stateDir`).
- `SyncRoots.includes/isPrivate` — what syncs and what is written mode 600.
- `writeBytesAtomic(path, bytes, mtime:, private:)` in `paths.dart`.

### Account-wide state — `core/lib/src/checker.dart`, `settings.dart`
- `CheckerLock.take(path, device:, lease:)` — a lease in a synced file: "one device of the account
  does X". Reuse for any other job that must run on a single device.
- `localDeviceId()` — stable random id of this installation.
- `AgendaSettings.sharedKeys` + `reloadShared()` — settings shared across devices; `save()` only writes
  keys changed on this device.

## app/

### Identity and Reticulum — `app/lib/src/identity/identity.dart`, `app/lib/src/sync/rns_node.dart`
- `KeyStore` / `SecureKeyStore` / `MemoryKeyStore`, `Identity`, `parsePubkey`, `shortNpub` (from senhorio).
- `Account` — the nsec in `accounts/agenda.nsec` plus the OS keystore.
- `RnsNode` — hubs + LAN, npub binding in the announce, per-device LXMF `send(peerId, msg)`.
  senhorio's version addresses every device of an npub; this one addresses one device.

### Formatting — `app/lib/src/ui/theme.dart`
- `two`, `isoDay`, `dayOf`, `sameDay`, `isoWeek`, `fmtDate`, `fmtShort`, `fmtTime`, `fmtDateTime`,
  `fmtDay`, `daysUntil`, `relativeDay`, `ago`.
- `statusColor`, `statusIcon`, `taskOrder`.

### Widgets — `app/lib/src/ui/theme.dart`
- `Panel`, `Caption`, `Chip2`, `Action2`, `Badge2`, `Md` (markdown), `EmptyNote`, `Splitter`, `PageTitle`.
- Colours: `Ui.bg/surface/surface2/surface3/border/text/muted/faint/accent/ok/warn/danger/purple`.

### Dialogs — `app/lib/src/ui/dialogs.dart`
- `textDialog`, `confirmDialog`, `pickDate`, `pickSchedule`, `taskDialog`, `projectDialog`,
  `eventDialog`, `topicDialog`, `recurringItemDialog`.

### Controller pattern — `app/lib/src/app_controller.dart`
- Every action is `await store.xxx(...); await _loadAgenda();`. New actions follow it.
- `_later(key, fn, ms:)` — keyed debounce.
- `_watch(dir, onEvent)` — guarded directory watch.

## Known duplicates (candidates to unify)

- Two-digit padding / ISO day exists in several places: `two`/`isoDay` (theme.dart), `_two`
  (app_controller.dart), local `two` (checker.dart), `_iso` (model.dart), `_hm` (sync_service.dart).
  Suggest one `core/lib/src/dates.dart` exported by `agenda_core` and used everywhere.
- File timestamp `YYYY-MM-DD_HHMMSS` is built twice in `app_controller.dart`
  (`addFileToTask`, `addSharesToTask`) — extract `fileStamp(DateTime)`.
- `HH:MM` regex in both `store.dart` (`_hhmm`) and `dialogs.dart` (`_hhmm`).
