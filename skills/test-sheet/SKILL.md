---
name: test-sheet
description: Use when a branch reviewed ok, not pushed yet, has to be tested by hand by a human — the user asks for a test sheet, a manual test, "fiche de test", "prépare-moi le test", or an orchestrator's tester role hands over a branch, its ticket and its review. The human gets one setup script to run whenever they have time, which starts the branch's wtm stack on its own, creates the accounts and data and prints the URLs, logins and second-factor code; then a checklist page with screenshots next to the mockups. Writes no code, commits nothing.
argument-hint: [branch]
---

# Test sheet for a branch

Chat with the user in their language; this skill file stays in English. The sheet is in the human's language.

The human tests when they have time, alone: nobody keeps a stack or an agent running for them. So everything they need fits in **one `bash` line** that starts the stack, waits for it, recovers from the project's known stalls, creates accounts and data, and prints what to open. They never read a log, never fill a variable, never install an authenticator.

Shipped with this skill, never rewritten by hand:

- `test-sheet-lib.sh`: `ts_up` (create or start the stack, wait for a 200, call the repo's recoveries), `ts_account`, `ts_summary` (URLs, logins, current code, fresh-code command, cleanup), `totp` and `selftest` subcommands. Read its header once.
- `sheet-template.html`: the sheet's page, with the « Copier » buttons already wired.

## 1. Check the branch

Clean tree and HEAD at the reviewed commit the brief names. Otherwise stop and say what you saw: a sheet for another commit tests something nobody reviewed.

## 2. Read what the change must do

- the ticket's acceptance criteria (`jira-read` skill), its comments included;
- the review's threads and suggestions about the screen;
- the plan's edge cases and framing answers, and its mockup nodes;
- the repo's notes and its `local-app` (or equivalent) skill: profiles, accounts, seed scripts, second factor, known stalls.

## 3. The repo's hooks, once per repo

`~/.config/hy0sh-skills/repos/<owner>/<repo>/test-sheet/hooks.sh` holds what this repo's stacks need beyond the lib. Read it if it exists; otherwise write it from the notes and the `local-app` skill, and add to it whenever a stall teaches something new. It defines only these functions, all optional:

```bash
# Ready means more than one page answering 200: a dev server can serve /login while
# other modules still fail (install rewriting node_modules as it started).
ts_ready() {   # <branch> <service base URL>
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$2/src/styles.css")" = 200 ] &&
    ! wtm run "$1" -- docker compose logs --since 1m back-office 2>/dev/null | grep -q 'Internal server error'
}
# Known stalls, called every 10 s while not ready. One try each.
ts_on_stall() {   # <branch> <elapsed minutes> <last HTTP code, or "unready">
  if [ "$3" = unready ] && ts_once restart-front; then
    wtm run "$1" -- docker compose restart back-office
  fi
  # Front stopped after the first boot: 404 that outlasts a normal start.
  if [ "$3" = 404 ] && [ "$2" -ge 6 ] && ts_once front; then
    wtm run "$1" -- docker compose up -d --no-deps back-office
  fi
  # Install aborted for lack of a TTY: rerun it non-interactive.
  if wtm run "$1" -- docker compose logs api 2>/dev/null | grep -q ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY && ts_once api; then
    wtm run "$1" -- docker compose run -d --no-deps -e CI=true api
  fi
}
# The repo's own fresh-code command, when it has one (prints the command, not the code).
ts_totp_cmd() {   # <branch> <login> <secret>
  echo "wtm exec $1 -- pnpm seed:totp $2"
}
```

`ts_ready` checks what a first page answering 200 does not prove: a module of each kind the app loads (a stylesheet entry, a script), and no error in the service's recent logs. Each recovery is keyed on what the notes say the stall looks like (an HTTP code, a minute threshold when a slow first start answers the same code, a log line) and guarded by `ts_once <name>`, so it runs once. Their output is silenced so the dots stay readable; the 200 is what proves them. Nothing else goes there: no accounts, no data, no branch.

## 4. The setup script

`/tmp/test-setup-<branch without its prefix>.sh` (`feature/ABC-123-some-slug` → `test-setup-ABC-123-some-slug.sh`). Copy the lib next to it first: `cp <this skill>/test-sheet-lib.sh /tmp/test-sheet-lib.sh`. The script is exactly this shape, the branch written in full on every line:

```bash
#!/usr/bin/env bash
set -euo pipefail
source /tmp/test-sheet-lib.sh
source ~/.config/hy0sh-skills/repos/some-org/some-repo/test-sheet/hooks.sh
ts_up feature/ABC-123-some-slug bo back-office /login

# Accounts and data: the repo's seed scripts when the branch has them, else host commands.
wtm exec feature/ABC-123-some-slug -- pnpm create-user admin@example.test 'Admin-Test-2026!' admin
wtm exec feature/ABC-123-some-slug -- pnpm seed:audit-logs --days 30 --count 200

ts_account admin@example.test 'Admin-Test-2026!' JBSWY3DPEHPK3PXP
ts_summary feature/ABC-123-some-slug
```

- `ts_up <branch> <profile> <service> <path>`: the profile the change needs (`-` for the whole stack), the service as `wtm ports` names it, and a path that answers **200 without a session** (the login page, a health route): a protected screen answers 302 or 401 and the wait never ends.
- An account the app asks a second factor of is **enrolled by the script** with a secret of its own, so the summary prints its code: one per account, from `python3 -c 'import base64,os;print(base64.b32encode(os.urandom(20)).decode())'`. An account that must enroll on screen gets its secret read from the screen; say so in the checklist.
- A command that reaches a service of the stack from the host goes through `wtm run <branch> --`, a command in the app container through `wtm exec <branch> --` (see the `wtm` skill).
- The data is ready before the human opens the app: every list the change touches holds **at least two pages** in its default period, and there is **one account of each kind** the screen tells apart (roles, and deleted or unknown authors when the screen shows authors).
- Data goes through the product's own paths (seed scripts, use cases, admin) when it has them; a direct SQL insert only for a state the product cannot produce on purpose (a corrupted row, a deleted author), and the checklist says which.

## 5. Prove it

On **your own isolated stack**, never the human's, never the main stack: copy the script to your scratchpad with the human's branch replaced by yours (`sed 's#feature/ABC-123-some-slug#<your branch>#g'`) and run it as is. Under an orchestrator that gives you a stack command, start the stack with it, then run the copy with `ts_up`'s line kept: it finds the worktree and only starts it and waits.

- `bash /tmp/test-sheet-lib.sh selftest` passes.
- Sign in with **each account**, the second factor typed from the printed code, in the headless browser of the `playwright` MCP, with its `browser_*` tools only, never `browser_run_code_unsafe` (it asks the user on every call). A step no `browser_*` tool can do is named in the sheet.
- Take a screenshot of each screen of the change on that stack, in the state the checklist describes.
- A line that fails is fixed in the script, then replayed. Never leave a failing line for the human, never add a "if this fails, run…" line: that is a recovery, and it goes into `ts_on_stall`.
- Stop your stack afterwards.

## 6. The sheet

Markdown in a file the caller names (else `/tmp/test-sheet-<branch without prefix>.md`), and its page next to it, same name, `.html`, made from `sheet-template.html`. Readable in one minute, in this order:

1. **Launch**: the single `bash /tmp/test-setup-….sh` line, then for each account with a second factor its fresh-code command, the exact `New code:` line the summary printed (the real secret in it, never a placeholder), each line with its « Copier » button; the accounts table (login, password, role in the test, the unknown or deleted ones included).
2. **Checklist**, one line each, "do X, you should see Y": every acceptance criterion, every behaviour the review threads name, every edge case and framing answer of the plan, the edge cases the change exposes (an empty list, a wrong input, an unknown or deleted record, a second page, a hand-edited URL).
3. **Screens**: each screen of the change, its screenshot next to its mockup (the design tool's screenshot of the plan's node). In the sheet only, never in the PR.
4. **Not prepared**: what could not be prepared or checked, plainly.
5. The script's full text, folded, for reference: the real file, HTML-escaped.

No `(a) …; (b) …` choices in it: the sheet is accepted (test OK) or refused with the human's notes (test KO).

Open the page in the headless browser: light, dark and phone width, and **click each « Copier »**: it must show « Copié ». A sheet in plain markdown, without its page, is not done.

## 7. Hand over

The sheet's path and the page's, one line on what is covered and what is not, and the question: **test OK, or KO with your notes**. Under an orchestrator, that message goes to it.

## Common mistakes

| Mistake | Instead |
|---|---|
| A dozen commands to paste in order | One `bash` line; everything else is in the script |
| "Read `wtm ports`, then replace `<URL>`" | `ts_up` reads the address; the summary prints it |
| "Only if it answers 404 after 6 minutes, run…" | A recovery in `ts_on_stall`, applied by the script |
| A TOTP calculator written into the sheet | `bash /tmp/test-sheet-lib.sh totp <secret>`, or the repo's `ts_totp_cmd` |
| `BRANCH=…` then `$BRANCH` everywhere | The branch in full on every line |
| Proven on a worktree already adopted, so the fresh `create` path was never run | Prove on a stack created for the proof; say so when it was not |
| Lists with one page of data, one kind of account | Two pages in the default period, one account of each kind |
