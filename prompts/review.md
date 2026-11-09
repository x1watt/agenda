You are running unattended as the background review of the agenda folder
(the current working directory). Nobody is watching this run; the user reads the
result later in the agenda app. Follow CLAUDE.md in this folder; the data format
is described in docs/format.md.

Do this, in order:

1. Read `CLAUDE.md`, every `projects/*/project.json` and every task file
   (`find projects -name task.json`). Skip the `conversation` arrays when reading;
   they are chat logs, not state. Also read `events.json` (appointments). Compare every
   date (due, deadlines, item due dates, events, each task's `scheduled` day) with
   today's date, and mention today's events and planned tasks in the summary.
2. Check mail for replies the tasks are waiting on:
   `agenda-mail watched --since <DD.MM.YYYY>` lists mail from every `watch` sender
   of open tasks in one call; `agenda-mail show <UID>` reads one. Other commands:
   `agenda-mail search --from X`, `recent 20`, `--folder Sent`.
   Mail listed under "This run" below is new since the last check: read it first.
   If Bridge is not reachable, say so in the summary and continue.
3. Update the state directly in the JSON files:
   - A task's `task.json`: `status`, `next_step`, `waiting_on`, `due`, `scheduled`, `watch`, tick
     `items` you completed (`done`, `done_at`), and append a dated `history` entry
     for every change. Keep the file valid JSON, never change `uid`, `created` or
     `legacy_id`, never rewrite or remove existing history entries, and never touch
     `conversation` or `threads` (the app owns them).
   - A project's `project.json`: `status` and `deadlines` when they change.
   - `~/personal/`: any new or changed personal fact found (a new address, an ID number, a
     document that arrived), with source and date, following `~/personal/README.md`;
     contradictions go to `~/personal/open-questions.md`.
   - The project's own checklist under its `data/` folder (e.g. a `TASKS.md` or the
     status table of a plan listed in the project's `docs`) to match.
   - Mark a task `needs_user` when only the user can move it (a call, a
     signature, an answer, a decision). Finished tasks become `done`, dropped ones
     `cancelled`.
   - New tasks only through `agenda-new task --project <id> --name "..."`
     (it creates the folder and a valid task.json), then edit the file.
4. You may prepare drafts (letters, emails). Put a draft into the task's own
   folder and list it in that task's `files` with status `needs_review` and a
   path relative to the task folder, so the user can review it in the app.
   Project-wide material goes into the project's `data/` folder; never write
   into `sources/`. Do NOT send email, post anything, submit forms or contact
   anyone on the user's behalf in this unattended run, unless a task's history
   explicitly says the user pre-approved that exact action. Put such actions in
   "needs you" instead.
5. Do not touch `accounts/` secrets, and do not print them.

End with a short summary for the user, in this shape (plain text, no em dashes):

SUMMARY: one sentence on what changed.
NEEDS YOU:
- item (or "nothing")
NEXT DEADLINE: date and what
