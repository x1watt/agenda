# agenda

A personal command center for real-life tasks, driven by Claude Code: letters to write, forms to
file, appointments to keep, deadlines not to miss. It answers one question, on the desktop and on
the phone: what is the next step, and by when?

Every ongoing matter is a folder of plain JSON and Markdown on disk, so Claude can read and update
the state directly, and so can you with any editor. There is no server and no database.

This is a personal project, built for one setup (Linux laptops plus an Android phone sharing one
account). It is published because the design may be useful to others, not as a product: there is no
support and no stability promise.

## What is in here

- `core/`: the Dart package shared by everything else. Data model and store, the background
  checker, the Claude Code process wrapper, the read-only Proton Mail Bridge reader, the file-sync protocol.
- `app/`: the Flutter app. Linux desktop (calendar, task list, task pane with a chat per task,
  tray icon, run history, settings) and Android phone (package `x1watt.agenda`).
- `docs/format.md`: the data format, field by field.
- `prompts/review.md`: the prompt the background checker runs unattended.

The folder the app works on is not part of this repository. It holds `projects/<id>/` with one
subfolder per task, plus `events.json`, `recurring.json`, `general.json`, an `accounts/` folder for
credentials, and a `CLAUDE.md` that tells Claude how to work in it.

## How it works

Each task is a `task.json`: status, priority, due and scheduled dates, a checklist, an append-only
history, the files prepared for review, and the mail senders the task is waiting on. Claude edits
those files; the app renders them. Nothing needs to be kept in sync by hand.

A systemd user timer runs the checker every 30 minutes. Each tick is cheap: it looks at deadlines
and at new mail from the senders tasks are watching. It wakes Claude with `prompts/review.md` only
when something happened (first check after boot, the daily review, new watched mail, a deadline
entering the next 24 hours, or "Run now" in the app). Those runs update files and prepare drafts;
they never send mail, post anything or contact anyone.

Every task, every project and the cross-project topic has exactly one continuous chat, stored in
the node's own JSON file, with the node's current state passed to Claude as extra system prompt.

Every device of the account (one NOSTR key, copied from device to device in Settings) syncs the
content folder, the credentials and ~/personal with the others over Reticulum: on the LAN and
through public hubs, end-to-end encrypted, accepting only devices that prove they hold the same
key. JSON files changed on two devices are merged item by item, other conflicts are kept twice.
Any laptop can run the background checks; a synced lease makes sure only one does at a time. Run
records, chat transcripts and code stay on the device that made them.

## Requirements

- Flutter and the Dart SDK (`environment: sdk: ^3.10.0`).
- The Claude Code CLI on `PATH` (or at `~/.local/bin/claude`) for desktop sessions, and an
  Anthropic API key if you want Claude in the phone app.
- Optional: a running Proton Mail Bridge for the mail reader.
- Linux desktop for the installer; Android for the phone build.

## Install

Desktop, builds the app and the checker, installs under `~/.local`, adds the launcher, the autostart
entry and the systemd timer:

```
app/tool/install-linux.sh              # install with autostart and background checks
app/tool/install-linux.sh --no-auto    # install only
app/tool/install-linux.sh --uninstall  # remove everything except your data
```

Phone:

```
cd app && flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Command line tools from `core/`:

```
dart run core/bin/agenda_new.dart project --id car --title "Car"
dart run core/bin/agenda_new.dart task --project car --name "Renew the insurance"
dart run core/bin/agenda_check.dart --dry-run
dart run core/bin/agenda_migrate.dart --validate
dart run core/bin/protonmail.dart recent 20
```

## Configuration

Settings live in `~/.config/agenda/settings.json` (content folder, check interval, notifications,
sync, hubs) and are editable in the app. The model, the daily review hour and the run timeout are
shared by every device of the account, in the content folder's `shared/settings.json`.

Mail is read through the local Proton Mail Bridge and needs three files in the content folder's
`accounts/`, all mode 600 and none of them in this repository:

- `protonmail-bridge.user`: one line, `Name <address>` or just the address. The environment
  variable `AGENDA_MAIL_USER` overrides it.
- `protonmail-bridge.pass`: the Bridge-generated IMAP password.
- `protonmail-bridge-cert.pem`: the certificate Bridge exports.

The reader opens folders with EXAMINE and fetches with BODY.PEEK, so it never marks, moves or
deletes anything. Sending (`core/bin/send_mail.dart`) is a separate, explicit step and needs
`--confirm`.

## Tests

```
cd core && dart test
cd app && flutter test
```
