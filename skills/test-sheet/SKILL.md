---
name: test-sheet
description: Use when a branch reviewed ok, not pushed yet, has to be tested by hand by a human — the user asks for a test sheet, a manual test, "fiche de test", "prépare-moi le test", or an orchestrator's tester role hands over a branch, its ticket and its review. The human gets one setup script to run whenever they have time, which starts the branch's wtm stack on its own, creates the accounts and data, prints logins and second-factor codes and opens the screens to test; then a checklist page with screenshots next to the mockups. Writes no code, commits nothing.
argument-hint: [branch]
---

# Test sheet for a branch

Chat with the user in their language; this skill file stays in English. The sheet is in the human's language.

The human tests when they have time, alone: nobody keeps a stack or an agent running for them. So everything they need fits in **one `bash` line** that starts the stack, waits for it, recovers from the project's known stalls, creates accounts and data, and prints what to open. They never read a log, never fill a variable, never install an authenticator.

Shipped with this skill, never rewritten by hand:

- `test-sheet-lib.sh`: `ts_up` (create or start the stack, wait until ready, call the repo's recoveries), `ts_retry`, `ts_account`, `ts_code`, `ts_summary` (logins, current codes, fresh-code commands, cleanup), `ts_open` (the screens to test, opened in the human's browser), and `bash test-sheet-lib.sh selftest`. Read its header once.
- `sheet-template.html`: the sheet's page, with the « Copier » buttons already wired: the clipboard when the page is opened on its own, a `postMessage({type: "copy", text})` to the parent when a board shows it in a sandboxed iframe (the board copies), a selection to ⌘C when both are refused.

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
# Known stalls, called every 10 s while not ready, and between two tries of ts_retry.
ts_on_stall() {   # <branch> <elapsed minutes> <HTTP code, "unready" or "retry">
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
# The repo's own command that prints a current code, for accounts declared `repo`.
# Prints the command, not the code; the lib keeps the last 6-digit line of its output.
ts_totp_cmd() {   # <branch> <login>
  echo "wtm run $1 -- pnpm --filter api seed:totp"
}
```

`ts_ready` checks what a first page answering 200 does not prove: a module of each kind the app loads (a stylesheet entry, a script), and no error in the service's recent logs. Each recovery is keyed on what the notes say the stall looks like (an HTTP code, a minute threshold when a slow first start answers the same code, a log line) and guarded by `ts_once <name>`, so it runs once. Their output is silenced so the dots stay readable; the 200 is what proves them. Nothing else goes there: no accounts, no data, no branch.

## 4. The setup script

One self-contained file, `/tmp/test-setup-<branch without its prefix>.sh` (`feature/ABC-123-some-slug` → `test-setup-ABC-123-some-slug.sh`): the lib, the repo's hooks and the branch's body, concatenated, so nothing else has to survive until the human runs it. Write the body in your scratchpad, then:

```bash
cat <this skill>/test-sheet-lib.sh ~/.config/hy0sh-skills/repos/<owner>/<repo>/test-sheet/hooks.sh body.sh \
  > /tmp/test-setup-ABC-123-some-slug.sh
```

The body is this shape, the branch written in full on every line:

```bash
ts_account admin@example.test 'Admin-Test-2026!' repo

setup() {
  ts_up feature/ABC-123-some-slug bo back-office /login
  # Accounts and data: the repo's seed scripts when the branch has them, else host commands.
  ts_retry 5 15 wtm exec feature/ABC-123-some-slug -- pnpm create-user admin@example.test 'Admin-Test-2026!' admin
  wtm exec feature/ABC-123-some-slug -- pnpm seed:audit-logs --days 30 --count 200
  ts_summary feature/ABC-123-some-slug
  ts_open feature/ABC-123-some-slug back-office /login /audit-logs
}

case "${1:-}" in
  "") setup ;;
  totp) ts_code feature/ABC-123-some-slug "${2:-}" ;;
  # Commands the checklist asks for mid-test, one per state the human cannot reach by hand:
  expire-invitation) wtm exec feature/ABC-123-some-slug -- pnpm invitation:expire admin@example.test ;;
  *) echo "usage: bash $0 [totp <login> | expire-invitation]" >&2; exit 2 ;;
esac
```

- `ts_up <branch> <profile> <service> <path>`: the profile the change needs (`-` for the whole stack), the service as `wtm ports` names it, and a path that answers **200 without a session** (the login page, a health route): a protected screen answers 302 or 401 and the wait never ends.
- `ts_retry <tries> <seconds> <command…>` for the first data commands: a service can still be installing when the screen already answers. Between two tries the repo's recoveries run (`ts_on_stall … retry`).
- Every data command can run twice: it checks first, or tolerates "already exists". The human may rerun the script.
- An account the app asks a second factor of gets its code one of two ways, as its third argument: a base32 secret **the script imposes** (an admin API or a seed command that takes it; one per account, from `python3 -c 'import base64,os;print(base64.b32encode(os.urandom(20)).decode())'`), or `repo` when the stack generates the secret itself, which the repo's `ts_totp_cmd` reads back. Never a secret the proof's run enrolled: the human's run enrols another one.
- `ts_open <branch> <service> <path…>`, last: the exact screens of the checklist (login, then the screen the change touches), printed and opened in the human's browser (`open`, `xdg-open`, nothing when neither exists).
- A command that reaches a service of the stack from the host goes through `wtm run <branch> --`, a command in the app container through `wtm exec <branch> --` (see the `wtm` skill).
- The data is ready before the human opens the app: every list the change touches holds **at least two pages** in its default period, and there is **one account of each kind** the screen tells apart (roles, and deleted or unknown authors when the screen shows authors).
- Data goes through the product's own paths (seed scripts, use cases, admin) when it has them; a direct SQL insert only for a state the product cannot produce on purpose (a corrupted row, a deleted author), and the checklist says which.

## 5. Prove it

On **your own isolated stack**, never the human's, never the main stack: copy the script to your scratchpad with the human's branch replaced by yours (`sed 's#feature/ABC-123-some-slug#<your branch>#g'`) and run it as is, with `TS_NO_OPEN=1` so nothing opens on the human's screen. Under an orchestrator that gives you a stack command, start the stack with it first: `ts_up` then finds the worktree and only starts it and waits. Your worktree sits under `.claude/worktrees/`, which `ts_up` refuses to reuse for the human (an agent's stack stops when its task ends, and its URL with it: `ts_up` stops with "branch X is held by <path>"), so add `TS_ALLOW_FOREIGN=1` to your run only. A repo whose agents keep their worktrees elsewhere redefines `ts_foreign_worktree <path>` in its hooks.

- `bash <this skill>/test-sheet-lib.sh selftest` passes.
- Run the copy's `totp <login>` and each mid-test command once.
- Sign in with **each account**, the second factor typed from the printed code, in the headless browser of the `playwright` MCP, with its `browser_*` tools only, never `browser_run_code_unsafe` (it asks the user on every call). A step no `browser_*` tool can do is named in the sheet.
- Take a screenshot of each screen of the change on that stack, in the state the checklist describes.
- A line that fails is fixed in the script, then replayed. Never leave a failing line for the human, never add a "if this fails, run…" line: that is a recovery, and it goes into `ts_on_stall`.
- Stop your stack afterwards.

## 6. The sheet

Markdown in a file the caller names (else `/tmp/test-sheet-<branch without prefix>.md`), and its page next to it, same name, `.html`, made from `sheet-template.html`. Readable in one minute, in this order:

1. **Launch**: the single `bash /tmp/test-setup-….sh` line, then for each account with a second factor its fresh-code command (`bash /tmp/test-setup-….sh totp <login>`), then each mid-test command next to the checklist line that needs it, each line with its « Copier » button; the accounts table (login, password, role in the test, the unknown or deleted ones included).
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
| "Read `wtm ports`, then replace `<URL>`" | `ts_open` reads the addresses, prints and opens the screens |
| "Only if it answers 404 after 6 minutes, run…" | A recovery in `ts_on_stall`, applied by the script |
| A TOTP calculator written into the sheet | `bash /tmp/test-setup-….sh totp <login>` |
| The secret the proof's run enrolled, printed in the sheet | A secret the script imposes, or `repo` and the repo's `ts_totp_cmd` |
| The script sources files that may be gone by the time the human runs it | One file: lib, hooks and body concatenated |
| `BRANCH=…` then `$BRANCH` everywhere | The branch in full on every line |
| Proven on a worktree already adopted, so the fresh `create` path was never run | Prove on a stack created for the proof; say so when it was not |
| Lists with one page of data, one kind of account | Two pages in the default period, one account of each kind |
