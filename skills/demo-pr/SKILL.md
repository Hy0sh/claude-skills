---
name: demo-pr
description: Use when a pull request or a branch has to be shown working to a human before it is marked ready or merged — a reviewer, a PO or the author wants to see the change run, or an orchestrator collects one demo per worker. The agent first decides whether a video is worth it (a user journey across several screens, a complex business flow) or two or three screenshots suffice; when it is, it prepares the data, films the nominal path only with `demo-film`, captures the other states as screenshots, and hands them over; the human answers once, ok or ko with the step. Does not change the code.
argument-hint: [branch|PR]
---

# Demo a pull request

Chat with the user in their language; this skill file stays in English.

A green test proves what the agent checked; a demo shows the human what the change does. The demo is a **video**: the agent drives the app headless, the human watches when they want, at their pace, and answers once. Filming is done with the `demo-film` skill — load it; this skill is everything around it.

## 0. Film only when a video is worth it

A video costs the reviewer minutes, and costs storage and energy every time; reviewers skip the long ones. Film when the change is a **user journey across several screens or a complex business flow**, where the sequence itself is what must be seen. Otherwise:

- **No visible screen** (back-end, API, data): no demo; the tests and the PR's description carry it.
- **A front-end change that fits in one or two screens**: two or three well-chosen screenshots, where the repo's PR convention puts them.

Say which in one line and stop there, unless the user asks for the video anyway. Checking every case of every criterion is the job of the tests and the recette, not of the video.

## 1. What the demo proves

- **The nominal path**: the base case of the acceptance criteria, from the PR body or the ticket via `jira-read`. One step per criterion it crosses, not one per click; about a minute, not three. An expectation no criterion backs is a requirement invented by the demo; its ko is noise.
- **Other states as screenshots**: errors, empty cases, variants, one screenshot per state that matters, taken on the same stack after the take. Never more takes or more steps for them.
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

With the `demo-film` skill: write the scenario, `check`, `rehearse` until green, reset, `film` once. Then capture the other states as screenshots on the same stack.

- Captions and expectations in the human's language (`labels`), written from the user's side of the screen.
- Each `check` step's `see` quotes the criterion's observable result: texts, names, counts.
- Something the tool cannot assert (an absence, a value in another app) is stated in `expect` and checked by you outside the video; say so when handing over.

## 4. Hand over

- `~/Desktop/<branch without its prefix>/<KEY>-demo.mp4` and one `<KEY>-<state>.png` per other state, and nothing else: no chapter file, no summary. The captions in the video already name each step.
- One message: the video's path, what the demo covers and what it does not (criteria not filmed, checks done outside the video), and the question: **ok, or ko with the step and what you see**.
- Under an orchestrator, the same message goes to the orchestrator, which relays it.
- After an ok, and once the human agrees to post it: put **the video alone** in the PR body, **right after its summary section** (the first one: TL;DR, in short), never at the bottom with the technical details, where reviewers do not scroll; no summary line, no chapter table. The screenshots go where the repo's PR convention puts them (read it first: its commit/PR skill or notes). Fetch the body, insert `![](./<file>.mp4)` **alone in its paragraph** at that place, keep everything else as it is, then `gh pr edit <PR> --body-file <file> --attach <video>`: `gh` rewrites the path to the uploaded URL and GitHub renders a player (anywhere else it is only a link). A PR comment only when the body has no summary section.
- Size: GitHub takes videos up to 10 MB on a free plan, 100 MB on a paid one (H.264 `.mp4`, which `demo-film` writes). Over the limit, say so and offer a shorter cut (the steps that matter) rather than a blurrier one.

## 5. A ko

1. Reproduce it on the stack, from the step the human named.
2. Classify it in one line: **a defect** (the code does not do what the criterion says) or **a scope gap** (the step expected something the ticket never asked for — that goes back to the human or the PO, not to a fix).
3. After the caller's fix, film again: the whole scenario if it is short, otherwise the steps the fix touched, from a reset.

## 6. Leave the recipe better

Before closing, update `recipe.md` with what this demo had to discover: a label, a widget, a switch, a trap, a reset step. The next demo of this repo should not pay for it again.

## Never

- Film a change that one or two screenshots show, or that has no screen
- Film every case of every criterion: the video is the nominal path
- Write demo data straight into the database
- Film the main stack, or a stack that does not serve the branch
- Show a step whose expectation no criterion backs, or a context screen as a deliverable
- Hand over a video you have not checked on its key frames
- Take anything but an explicit ok as an ok
