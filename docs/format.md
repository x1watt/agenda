# Agenda data format

Version 1 of the folder-per-project, file-per-task layout. This file is the reference for the
app (`app/`), the shared Dart package (`core/`), the background checker and for Claude sessions
that edit the JSON files directly.

## Principles

- One folder per project, one folder per task. A task's folder holds its `task.json` and the files
  produced for that task (drafts, letters, forms).
- The JSON files are the state. There is no summary file to keep in sync; the app builds its
  overview from them.
- Some fields are owned by the app (conversation, threads); Claude never edits those. Some are
  owned by Claude and the user; the app only changes what a click in the app means (status, item
  ticks, file approval) and always appends a history line for it.
- History and conversation are append-only.

## Layout

```
agenda/
  projects/
    <project-id>/                 # ^[A-Za-z0-9-]+$
      project.json
      sources/                    # input material the user drops in (PDFs, scans, forms, mail)
      data/                       # project-level material Claude produces (plans, checklists, letters)
      <UID>-<slug>/               # one folder per task, at the project root
        task.json
        ...                       # files produced for this task
  general.json                    # the General topic: conversation and threads across projects
  legacy/                         # the pre-migration files (tasks.json, threads.json, next.md, id-map.json)
  docs/format.md                  # this file
  runs/, prompts/, accounts/, core/, app/
```

Folders that held a project before the migration may still exist as symlinks to
`agenda/projects/<id>`, so links written back then keep resolving.

## Identifiers

- Project id: the folder name. Letters, digits and `-` only (`^[A-Za-z0-9-]+$`).
- Task UID: `XXX-XXX`, six characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no I, O, 0, 1),
  generated at random, unique across all projects, never reused or changed. The taken set is every
  task folder name under `projects/*/` plus every `uid` in a readable `task.json`, so a broken file
  still holds its UID.
- Slug: from the task name at creation. Lowercase; ae, oe, ue, ss for umlauts; every run of other
  characters becomes `-`; trimmed; at most 40 characters; `task` when empty. The folder is
  `<UID>-<slug>` and is never renamed, even when the task name changes.
- Item id: a string, `1`, `2`, ... inside the task (next id = highest numeric id + 1). Migrated or
  hand-written items may use other short ids such as `K1`.

Create projects and tasks with `agenda-new` (compiled from `core/bin/agenda_new.dart`); it makes
the folder and a valid JSON file:

```
agenda-new project --id car --title "Car"
agenda-new task --project car --name "Renew the insurance" [--status todo] [--priority 1] [--due 2026-09-18]
```

## project.json

```json
{
  "version": 1,
  "id": "car",
  "title": "Car",
  "created": "2026-09-10T00:00:00",
  "status": "Quotes requested, waiting for the written offer.",
  "docs": ["data/TASKS.md", "data/PLAN.md"],
  "deadlines": [
    { "date": "2026-12-31", "text": "Last day to change insurer", "task": "K7M-2PQ" },
    { "date": "2026-12-19", "text": "Current quote expires", "task": null }
  ],
  "conversation": [
    { "at": "2026-09-12T10:03:11", "role": "user", "text": "What is still open?", "session": "84a6941a-..." }
  ],
  "threads": [
    { "id": "84a6941a-...", "created": "2026-09-12T10:03:00", "archived": false, "archived_at": null, "archived_reason": null }
  ]
}
```

| Field | Owner | Meaning |
|---|---|---|
| `version` | fixed | Format version, `1`. |
| `id` | fixed | Equals the folder name. |
| `title` | Claude, user | Display name. |
| `created` | fixed | ISO timestamp. |
| `status` | Claude | One line on where the project stands. |
| `docs` | Claude | Paths relative to the project folder, shown as buttons in the app. |
| `deadlines` | Claude | Dates that are not a single task's due date. `task` is a UID or null. |
| `conversation` | app | Project-level chat, see below. |
| `threads` | app | Claude sessions of the project-level chat, see below. |

Tasks are never listed in `project.json`; the loader finds them from the subfolders.

## task.json

```json
{
  "version": 1,
  "uid": "K7M-2PQ",
  "name": "Change the car insurance for next year",
  "status": "todo",
  "priority": 1,
  "created": "2026-09-10T00:00:00",
  "due": "2026-09-18",
  "next_step": "Fill the cancellation form using form-help.md, print, sign, post by 18.09.",
  "waiting_on": null,
  "watch": [ { "from": "insurer.example" }, { "from": "garage.example" } ],
  "items": [
    { "id": "1", "text": "Ask the garage for the current mileage", "done": false, "done_at": null, "due": null },
    { "id": "2", "text": "Download the forms", "done": true, "done_at": "2026-09-11T12:00:00", "due": null }
  ],
  "history": [
    { "date": "2026-09-10", "text": "Working document and covering letter drafted" }
  ],
  "files": [
    { "path": "form-help.md", "status": "needs_review", "at": "2026-09-14T09:22:00+02:00" },
    { "path": "../data/insurance/PLAN.md", "status": "approved", "at": "2026-09-11T18:00:00" }
  ],
  "conversation": [
    { "at": "2026-09-14T10:01:00", "role": "user", "text": "Is the old policy already cancelled?", "session": "3d971cb4-..." },
    { "at": "2026-09-14T10:01:20", "role": "assistant", "text": "Not yet, the form still needs your signature.", "session": "3d971cb4-..." }
  ],
  "threads": [
    { "id": "3d971cb4-...", "created": "2026-09-11T19:01:17", "archived": false, "archived_at": null, "archived_reason": null }
  ],
  "follows": null,
  "legacy_id": "T1"
}
```

| Field | Owner | Meaning |
|---|---|---|
| `version` | fixed | `1`. |
| `uid` | fixed | Equals the UID in the folder name. |
| `follows` | fixed | UID of the task this one continues (a follow-up), or null. Set when the app or `agenda-new` spawns the follow-up. |
| `name` | Claude, user | The task name as the author wrote it. |
| `status` | Claude, user, app | `todo`, `in_progress`, `waiting`, `needs_user`, `done`, `cancelled`. |
| `priority` | Claude, user | 1 is highest; default 3. |
| `created` | fixed | ISO timestamp of creation. |
| `due` | Claude, user | `YYYY-MM-DD` or null. Feeds the overview and the checker's deadline window. |
| `scheduled` | user, Claude | When the user plans to work on it: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`, or absent/null. Places the task on that day in the app's calendar. Not a deadline. |
| `next_step` | Claude | The next concrete step, Markdown allowed. |
| `waiting_on` | Claude | Who or what the task waits for, or null. |
| `watch` | Claude | Sender substrings the checker searches mail for while the task is open. |
| `items` | Claude, user, app | Checklist of points to complete. The app ticks `done` and sets `done_at`. |
| `history` | Claude, app | Append-only dated log. Never rewrite or delete entries. |
| `files` | Claude, app | Files to review. `status` is `needs_review` or `approved`; the app sets `approved`. |
| `conversation` | app | The app's chat about this task, see below. |
| `threads` | app | Claude sessions of that chat. |
| `legacy_id` | fixed | The id the task had in the old `tasks.json` (`T1`, `H1`), or absent. |

A follow-up is a new task in the same project whose `follows` points at the task it continues;
the app can move the open items over and mark the origin done in the same step. The task page
shows the chain in both directions.

Statuses: a task is open unless it is `done` or `cancelled`. `needs_user` means only the user can
move it (a call, a signature, a decision); the app lists those under "Needs you" and the tray badge
counts them. Open items do not block `done`; they are a checklist, not a gate.

## general.json

```json
{ "version": 1, "conversation": [], "threads": [] }
```

Same entry shapes as in a task. Used by the General topic of the app.

## events.json

Calendar entries that are not tasks (appointments, calls, reminders), at the agenda root.

```json
{
  "version": 1,
  "events": [
    { "id": "e1k3x9", "date": "2026-09-25", "time": "14:00", "end": "14:30", "title": "Garage",
      "note": "Bring the service book", "task": "K7M-2PQ", "project": "car" }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Unique short string. The app makes `e` + a base-36 timestamp. |
| `date` | `YYYY-MM-DD`. |
| `time`, `end` | `HH:MM` or null (null `time` = the whole day). |
| `title`, `note` | What and details. `title` must not be empty. |
| `task`, `project` | Optional links: a task UID and a project id. |

Events count as upcoming dates, so the checker announces one when it enters the next 24 hours.

## recurring.json

Things that come back on a schedule and are not a task or an event: a yearly insurance renewal,
a periodic inspection. Grouped into topics (e.g. "Campervan"), at the agenda root.

```json
{
  "version": 1,
  "topics": [
    {
      "id": "campervan",
      "title": "Campervan",
      "items": [
        {
          "id": "r1a2b3",
          "text": "Yearly insurance",
          "interval": "yearly",
          "every": 1,
          "anchor": "2026-03-15",
          "next_due": "2027-03-15",
          "last_done": "2026-03-10",
          "note": null,
          "project": null,
          "task": null,
          "history": [{ "date": "2026-03-10", "text": "Done, next due 2027-03-15" }]
        }
      ]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` (topic) | Short id, `slugFor(title)` by default. |
| `title` (topic) | Display name. |
| `id` (item) | Unique across every topic. |
| `text` | What recurs. |
| `interval` | `yearly`, `monthly` or `days`. |
| `every` | Repeat every N years/months/days, default 1. |
| `anchor` | The first/original due date, `YYYY-MM-DD`. Kept so the schedule's origin is never lost. |
| `next_due` | `YYYY-MM-DD`. Drives the calendar and the checker, same as an event's `date`. |
| `last_done` | `YYYY-MM-DD` of the last time it was marked done, or null. |
| `note`, `project`, `task` | Optional: free text, and links to a project id / task UID like an event. |
| `history` | Append-only, same shape as a task's `history`. |

`next_due` feeds `Agenda.upcoming()` and the checker exactly as an event's `date` does, so a
recurring item due soon shows on the calendar and triggers the 24h-window announcement like any
other deadline. Marking an item done computes the next `next_due` from the *previous* `next_due`
(not from today) by stepping `interval`/`every`, so the schedule stays anchored even if done late
or early, and appends a `history` entry.

## Personal information (~/personal)

Outside the agenda folder, mode 700: Markdown files per topic (`me.md`, `family.md`, `ids.md`,
`money.md`, `tax.md`, `health.md`, `vehicles.md`, `contacts.md`, `open-questions.md`) and
`documents/` with copies of reusable documents. Every fact row names its source and date. Rules
in `~/personal/README.md`. The app and the checker pass it to Claude with `--add-dir`.

## Sync between devices

One account (an nsec, kept in `accounts/agenda.nsec`) can be installed on several laptops and
phones. Each device keeps its own copy and syncs with the others of the same account over
Reticulum, on the LAN and through public hubs (`core/lib/src/sync/`, `app/lib/src/sync/`).
Synced: `projects/**`, `accounts/**`, `prompts/**`, `shared/**`, `general.json`, `events.json`,
`recurring.json`, `CLAUDE.md`, `docs/format.md` and all of `~/personal`. Never synced: `runs/`,
`legacy/`, `app/`, `core/`, `build/`, `*.tmp-*`, `*.lock`. Files in `accounts/` and `~/personal`
are written with mode 600.

- `shared/` holds what every device needs for the automation: `settings.json` (model, daily review
  hour, run timeout), `checker-state.json` (last full run, mail already reported, deadlines
  already announced) and `checker-lock.json` (the device that runs the background checks and
  until when; the holder renews it every tick, another device takes over once it expired).
- Task photos from the phone: `<task folder>/photos/YYYY-MM-DD_HHMMSS.jpg`, with a history entry.
- A JSON file changed on two devices is merged three-way: `items`, `threads`, `events` by `id`,
  `files` by `path`, `watch` by `from`, `deadlines` by date+text, `seen` and `notified_deadlines`
  as sets, `history` and `conversation` as append-only logs (union, in date order); a scalar
  changed differently on both keeps the newer one.
- Any other file changed on both: the newer keeps its name, the other is saved beside it as
  `<name>.conflict-<device>-<YYYYMMDD-HHMM>.<ext>`. Check for such files and merge them by hand.
- Chat transcripts stay on the device that ran the chat; their messages reach the node's
  `conversation[]` like any other chat.

## Paths

`files[].path` is relative to the task folder. `docs[]` is relative to the project folder. The app
resolves a path by trying, in order: the task folder, the project folder, the agenda folder, the
workspace folder above it; then a search by file name under the task folder and the project folder
(three levels deep). Paths through the old symlinks resolve to the same file.

The app also lists every file that sits in the task folder, whether or not it is in `files[]`.

## Deadlines and due dates

A task's `due` is its own date. A project's `deadlines[]` hold dates that belong to the project as a
whole or to a task without being its due date (a legal cut-off, a document expiry). The overview
and the checker merge both (plus `events.json`), dropping dates in the past; the checker announces a date once when it
enters the next 24 hours.

## Conversation and threads

The app appends every message of a chat to the node's `conversation[]`: `role` is `user` or
`assistant`, `session` is the Claude session id the message belongs to (null if the session never
started). Tool calls and their output are not stored. `threads[]` lists the Claude sessions of the
node.

Each node (task, project, General) has exactly one chat in the app, never tabs and never closed. It
shows every stored message of the node, from all its sessions, and continues the newest session whose
transcript is on this device (`--resume`); when there is none, the first message starts a new session
that is added to `threads[]`. A new session gets the last few stored conversation entries in its
system prompt, so it knows what was said before. The `archived` fields of old threads are kept for
history but ignored. A project's pane lists its tasks' chats (newest first) and the project chat's
prompt carries the latest message of each.

Claude never edits `conversation[]` or `threads[]`, and skips `conversation[]` when reading a task
for its state.

## Rules for editing the JSON directly

- Keep every file valid JSON. Two-space indent, one trailing newline.
- Never change `uid`, `created`, `legacy_id`, the folder name, or `version`.
- Append a dated `history` entry for every change; never rewrite or remove existing entries.
- Put files produced for a task into the task folder and list them in `files[]` with
  `needs_review` and a path relative to that folder. Project-level material goes into `data/`.
  `sources/` is the user's; do not write there.
- Add a `watch` entry when a task starts waiting for mail, remove it when the mail came.
- New tasks and projects only through `agenda-new`.

## Migration and legacy/

`agenda_migrate` converted the old `tasks.json` and `threads.json` (kept under `legacy/` together
with `next.md`). `legacy/id-map.json` maps every old project and task id to the new folder and
UID. Old ids may still appear in the checklists and in history texts; `legacy_id` on the task links
them.

## Versioning

Each file carries `version`. Readers accept the current version and treat missing lists as empty.
A format change that is not backwards compatible bumps the version and ships with a migration.
