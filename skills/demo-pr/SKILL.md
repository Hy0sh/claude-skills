---
name: demo-pr
description: Use when a pull request or a branch has to be shown working to a human before it is marked ready or merged — a reviewer, a PO or the author wants to see the change run rather than read screenshots, or an orchestrator collects one demo per worker. The agent prepares the data, writes a scenario with one step per acceptance criterion, films it headless with `demo-film`, and hands over a video and its chapters; the human answers once, ok or ko with the step. Does not change the code.
argument-hint: [branch|PR]
---

# Demo a pull request

Chat with the user in their language; this skill file stays in English.

A green test proves what the agent checked; a demo shows the human what the change does. The demo is a **video**: the agent drives the app headless, the human watches when they want, at their pace, and answers once. Filming is done with the `demo-film` skill — load it; this skill is everything around it.

## 1. What the demo proves

- **The acceptance criteria**: from the PR body, or the ticket via `jira-read`. One step per criterion, not one per click. An expectation no criterion backs is a requirement invented by the demo; its ko is noise.
- **Screens labelled**: each step's caption says whether the screen is **changed** by the PR or only **context** on the way. A context screen shown without that word reads as a deliverable.
- **Gaps announced**: where the screen departs from the mockup or the ticket on purpose, the caption or the expectation says so, with the reason. A gap is announced, never discovered.
- **Out of scope said**: a side effect that shows but is not the PR's (a confirmation mail that already existed) is named as such in the expectation.

## 2. Prepare: the demo works on the first take

The human's time and the take's length are the cost; nothing filmed may be broken, empty or ambiguous.

1. **The stack serves this branch's code**: the branch's own isolated stack (see the `wtm` skill), never the main stack's ports. Grep a symbol of the diff inside the app container.
2. **The repo's demo recipe**: `~/.config/hy0sh-skills/repos/<owner>/<repo>/demo/recipe.md`. Read it first; it holds what the last demo of this repo learned (accounts and how to give them a password, switches and modules the screens need, background workers to start, menu labels, home-made widgets, known traps). Absent → create it at the end of this demo.
3. **Data through the product**: every record a step needs exists, created through the product's own paths (its seed commands, use cases, admin, or the UI) — never written straight into the database: a demo must not show a state the product cannot produce. If one cannot be made that way, say so instead of forcing it.
4. **Every field filled**: an empty field on screen reads as a gap in the product.
5. **Accounts**: each account the demo uses can log in, with a password set for the demo.
6. **Order**: irreversible gestures last, or on records made for them; states that depend on the date or time checked for the moment of the take.
7. **Reset**: a script that puts the stack back in the state step 1 expects (deletes what a run created, empties the mail catcher). Run it before each take; keep it with the recipe when it is reusable.

## 3. Film

With the `demo-film` skill: write the scenario, `check`, `rehearse` until green, reset, `film` once.

- Captions and expectations in the human's language (`labels`), written from the user's side of the screen.
- Each `check` step's `see` quotes the criterion's observable result: texts, names, counts.
- Something the tool cannot assert (an absence, a value in another app) is stated in `expect` and checked by you outside the video; say so when handing over.

## 4. Hand over

- `~/Desktop/<branch without its prefix>/<KEY>-demo.mp4` and `<KEY>-demo-chapters.md`.
- One message: the video, the chapter table, what the demo covers and what it does not (criteria not filmed, checks done outside the video), and the question: **ok, or ko with the step and what you see**.
- Under an orchestrator, the same message goes to the orchestrator, which relays it.
- After an ok: one line for the PR body — the criteria demonstrated, the date, and that the video is available (GitHub takes no video through its API: the human attaches it if they want).

## 5. A ko

1. Reproduce it on the stack, from the step the human named.
2. Classify it in one line: **a defect** (the code does not do what the criterion says) or **a scope gap** (the step expected something the ticket never asked for — that goes back to the human or the PO, not to a fix).
3. After the caller's fix, film again: the whole scenario if it is short, otherwise the steps the fix touched, from a reset.

## 6. Leave the recipe better

Before closing, update `recipe.md` with what this demo had to discover: a label, a widget, a switch, a trap, a reset step. The next demo of this repo should not pay for it again.

## Never

- Write demo data straight into the database
- Film the main stack, or a stack that does not serve the branch
- Show a step whose expectation no criterion backs, or a context screen as a deliverable
- Hand over a video you have not checked on its key frames
- Take anything but an explicit ok as an ok
