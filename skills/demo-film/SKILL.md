---
name: demo-film
description: Use when a web app, or a command line tool through a terminal, has to be filmed doing something — a demo video of a feature, a pull request, a bug reproduction — with `demo-film`, a Go CLI that plays a declarative YAML scenario headless, checks that each expected text is on screen, and writes an mp4 with captions under the page plus a chapter list. Covers installing it, writing a scenario in its closed vocabulary, the check / rehearse / film cycle, reading its errors, cutting long waits, filming a long demo in parts joined at the end, and the traps of real apps (menus, home-made widgets, native date inputs, iframes, new tabs).
---

# Filming a web app with demo-film

Chat with the user in their language; this skill file stays in English.

`demo-film` turns a scenario (YAML, data only) into `demo.mp4` and `chapters.md`. The scenario names what to do and what must be on screen; the tool plays it the same way every time, checks every expectation, and refuses to film a step whose expectation is not met. Never drive Playwright by hand to make a demo video: what the tool cannot express is a gap to report, not a reason to script around it.

The tool's README (https://github.com/Hy0sh/demo-film) is the reference for the vocabulary and the rules; this skill is how to use it well.

## 0. Prerequisites

`demo-film --version` answers, `ffmpeg` is on the PATH, and Chromium is installed (`rehearse` says so if not). Anything missing: give the human the command and stop — never install it yourself.

| Missing | Command for the human |
|---|---|
| `demo-film` | `go install github.com/Hy0sh/demo-film/cmd/demo-film@latest` (or a release binary) |
| the browser | `demo-film install` |
| `ffmpeg` | the system package manager, e.g. `brew install ffmpeg` |
| `ttyd` (terminal demos only) | `brew install ttyd`, `apt install ttyd` |

`terminal`, `cut`, `join`, `watermark` and `nth` on `click` need demo-film 0.4.0 or later, `wait: {gone}`, `wait: {enabled}` and `rehearse --paced` 0.5.0 or later: on an older version, `check` rejects them as unknown keys.

## 1. The cycle

```
demo-film check scenario.yaml            # no browser: schema and rules
demo-film rehearse scenario.yaml -o dir  # plays everything, no pause, no video (seconds)
demo-film rehearse --paced scenario.yaml # at the take's pace, still no video: the last check before the take
demo-film film scenario.yaml -o dir      # the take: demo.mp4 + chapters.md
```

- Iterate with `rehearse` only; film once it is green. A take lasts the length of the video.
- **A step that passes in one and fails in the other depends on time**: a plain rehearsal has no pause, the take has captions to read and a cursor that travels. Find what the step waits for and say it — `wait: {gone: "Group created."}` for a toast or a spinner, `wait: {enabled: "Next"}` for a control greyed until data loads — then confirm with `rehearse --paced`. A toast pauses while the mouse is over it, and a rehearsal's cursor lands at once on the button under it: wait for the toast to go before clicking there. Never buy time with `hover` or extra gestures: each one is a stray cursor move in the video.
- A failure names the step, the action and what was looked for, and leaves `rehearse-fail-step<N>.png`: **read the screenshot** before changing anything. It answers most questions (wrong label, element not shown yet, a dialog in the way).
- Before the take, reset the data the rehearsal consumed (the record it created, the mails it sent), so the take starts from the state step 1 expects. A rehearsal that creates something is not idempotent.
- Keep the scenario out of any public repo when it names a client's app, accounts or URLs.
- Keep scenarios and the output of `film` and `join` out of any configuration or recipe folder: they go in a working folder (the session's scratchpad, or one the user chooses).

## 2. Writing the scenario

```yaml
title: "Short title of the demo"
base_url: http://app.localhost:3000
locale: fr                 # optional: i18next and the browser's language (native date inputs, Intl)
hide: [".dev-toolbar"]     # optional: dev overlays hidden while filming
speed: 1                   # optional: 0.25-4, the whole video, gestures and captions (2 = twice as fast)
labels: {step: "Étape", check: "vérifie", see: "Tu dois voir :", later: "plus tard"}   # caption words in the viewer's language
watermark: {text: "© Some Co", position: bottom-right}   # optional: or image: logo.png; a corner of the page, never the band
steps:
  - caption: what I do, in one sentence     # shown before the actions
    check: AC1                              # optional: the acceptance point this step proves
    do:
      - open: /login
      - fill: {field: 1, value: alice}
      - fill: {field: password, value: secret}
      - press: Enter
    see: ["Dashboard"]                      # must be visible at the end, or the step fails
    expect: what the viewer should see      # shown after the actions
```

| Action | Use |
|---|---|
| `open: path-or-url` | step 1, or another origin (a mail catcher); never to move inside the app afterwards |
| `menu: [Parent, Child]` | sidebar or nav, exact names; the parent is opened if the child is hidden |
| `click: "Text"` · `{role, name}` · `{row, button}` · `{row, button: {nth: -2}}` | by visible text, by role and accessible name, or a button in a table row (by name, or by index for icon-only buttons) |
| `click: {text, nth}` · `{role, name, nth}` | when several visible elements share the text or the name (a slot per day, an "Actions" button per card): the nth one, from 0, negative from the end; out of range, the error says how many match |
| `fill: {field, value}` | field by label, placeholder, rank (`1`) or `password`; typed visibly. A native date, month, time or datetime-local input takes its ISO value (`2026-10-06`, `2026-10-06T08:00`) at once, and the step fails if the field does not keep it |
| `type: "text"` | keystrokes to whatever has the focus: a terminal |
| `select: {field, option}` | native `<select>` only; options that load late are waited for |
| `press`, `hover`, `wait` | a key, the cursor onto an element, a text to wait for |
| `wait: {gone: "text"}` · `wait: {enabled: "text"}` | wait, with no gesture, until nothing visible shows the text (a toast, a spinner; also proves an absence), or until a control is no longer disabled |
| `popup: {click, url_contains}` | a link opening a new tab: the URL is checked, the tab is not filmed |
| `confirm: "Button"` | a button of the last opened dialog (an "abandon changes?" prompt) |
| `within: dialog` | modifier on click, fill, select, hover, wait: look only in the last open dialog. Put it on **every** action aimed inside a modal: without it the page behind answers too (a `fill` by rank picks a field under the modal) |
| `cut: true`, `timeout: N` | modifiers on `wait`: see "Long waits" below |

Rules `check` enforces, and why:

- **No `open` inside the app after step 1**: it reloads the app, and the video shows a blank page. Navigate through menus and links like a user.
- **A step never ends on a forward button** (Next, Suivant, Continue): its "you should see" would be shown on the next screen. Put that click first in the next step.
- **A `check` step has a `see`**: an acceptance point is proven on screen, not asserted in a caption.

### Long waits

A task that takes a while (an export, a generation, a stack starting) is not filmed in real time: wait for its result with `cut: true`, and give it the time it needs with `timeout` (seconds, the default is 15).

```yaml
- click: Generate the invoices
- wait: Invoices generated
  cut: true
  timeout: 600
```

A transition card with a spinner covers the page, the wait is cut out under it, then the card reads "⏩ 2:14 later" and fades onto the result: the viewer sees that time passed. Wait for a text only the result shows; one already on screen ends the wait at once, and nothing is cut.

**One example of each operation on screen.** Repetitions and volume (the same object created for five entities, a hundred rows) are created off camera, and one is filmed. When the repetition falls in the middle of a filmed wizard, start a watcher before the take that creates the rest as soon as the filmed object exists, and let the step wait for the result with `cut`.

### A terminal

`terminal` replaces `base_url` to film a shell (served in the browser by ttyd, behind a password made for the run, opened off camera once the prompt shows; no `open` in such a scenario, it would restart the shell):

```yaml
terminal: {cwd: ../shop}           # relative to the scenario file, ~ expanded; shell: a command line, defaults to $SHELL
steps:
  - caption: I create a worktree with its own stack
    do:
      - type: wtm create feat/login
      - press: Enter
      - wait: stack started
        cut: true
        timeout: 900
    see: [stack started]
    expect: the worktree is ready on its own ports
```

The typed command stays on screen: a `wait` or `see` on a word it contains matches at once. Aim at a line only the output prints, read from the tool's source rather than guessed — a message printed on one path only (after an optional hook, say) never comes on another. A rehearsal really runs the commands: undo what it created before the take, or film directly, since a failed take writes nothing.

### A long film, in parts

Past a few minutes, or when the demo changes accounts, film **one scenario per part** and join them:

```
demo-film film agent.yaml -o parts/1
demo-film film citizen.yaml -o parts/2
demo-film join parts/1 parts/2 -o final      # --no-cards: no title cards
```

- A failing rehearsal replays only its part; a failing take loses only its part.
- Each part starts in a fresh browser: cut where the account changes, and log in at the start of the next part.
- Every part has the same `viewport` and `speed`, or `join` refuses it by name; parts filmed with demo-film older than 0.4.0 cannot be joined.
- `join` puts a title card with each part's `title` before it (quote a title containing `:` in YAML) and merges the chapters, one section per part, times shifted (to the second: a joined time may be a second early). Steps keep their per-part numbering. The card shows the `# Title` line of each part's `chapters.md`: to renumber the parts ("1. Agent", "2. Citizen"), edit that line and join again, without filming again.

How a long film holds together:

- **A preparation per part**: a script that restores a database snapshot, then creates exactly the state the part's step 1 expects. Rehearsals and failed takes are undone by running it again. When the next part depends on what this one creates, save a snapshot right after its good take, and start the next part's preparation from it.
- **A snapshot is a database, not the files**: what lives in object storage (S3-like uploads) is not in an SQL dump; the preparation recreates it.
- **Several agents in parallel**: one isolated environment each (stack, database, ports). When one agent films what another must recreate by script, write the shared values down first (names, dates, amounts) and check at the end that the parts agree.
- **Deliver outside the recipe**: the joined film goes to a folder of the user's (their desktop, a shared drive), never into a skills or configuration directory; only scenarios and preparation scripts stay in the recipe.

## 3. Finding the right names

The time goes into naming elements the way the app exposes them. Find them in this order, and **never explore the app in a browser** to collect labels — clicking through the journey by hand costs more than the whole film:

1. The repo's demo recipe, when there is one (the `demo-pr` skill says where).
2. The source: the screen's components and the translation files hold the exact labels, in the viewer's language.
3. `rehearse`: write the scenario with your best names and play it. A miss stops at the step, names what was looked for, lists the names visible on that screen, and leaves a screenshot: correct and play again, a few seconds per round.

An accessibility snapshot is for one screen only, the one where a rehearsal just failed and its message and screenshot were not enough.

- **Menus**: the visible label of the entry, which is often shorter than the page title ("Places", not "Place bookings"). Parents are often buttons, children links; `menu` handles both.
- **Home-made widgets** (dropdowns, time pickers, comboboxes): not a native `<select>`. Open them with `click` on their trigger — a button inside a `<label>` takes the label's text as its accessible name, so `click: {role: button, name: "Start time"}` — then `click` the option's text.
- **Text that appears later**: a badge or a summary may only render on the next screen; `see` what the current screen really shows.
- **Duplicated labels**: `click: "Save"` takes the first visible one; scope with `within: dialog`, `{role, name}` or a table `row`, and when the twins are genuine (one per day, one per card), pick one with `nth` — the order is the page's, so seed the data in a known order.
- **Iframes** (a mail catcher's message body): `see` looks into frames; actions do not.
- **New tabs**: assert them with `popup`; show the target afterwards by navigating to it in the app.
- **Absence** ("the error is gone", "no warning left"): `wait: {gone: "text"}` proves it on screen. An absence elsewhere ("no mail to the author") is said in `expect` and checked outside the video.
- **No-break spaces**: French labels put U+202F or U+00A0 before a colon or inside a time ("ex : Natation", "11 h 30"). Type a plain space in the scenario: any white space on the page matches it.
- **A control with no accessible name** (a `role=switch` or a checkbox with no label of its own): as a last resort, `click` the visible label next to it, then `press: Tab` and `press: Space`. Say in the hand-over that the control lacks an accessible name: the fix belongs in the app.
- **Out of the vocabulary**: file uploads, drag and drop, downloads, map markers with no text or accessible name, and the browser's own `confirm()`/`alert()` (dismissed automatically, which cancels the action). Prepare such states off camera with data, or film around them; never script around the tool.

## 4. Output

- `demo.mp4`: the page untouched (only a visible cursor and click halo), captions in a band under it, starting once the app shows.
- `chapters.md`: step, acceptance point, minute, caption, expectation. It is for you, not for the viewer: the captions already name each step, so hand over the video alone. After `join`, one section per part, on the joined video's minutes.
- Check one or two frames of key steps before handing the video over, at the minutes `chapters.md` gives (`ffmpeg -ss <t> -i demo.mp4 -frames:v 1 f.png`, then read the image).
- Still frames hide motion: stray cursor moves only show in a moving excerpt. For the parts rich in gestures, watch a short excerpt, or at least count the `hover` of their scenario — more than a handful usually means time was bought with gestures instead of `wait`.

## Never

- Install the tool, the browser or ffmpeg yourself
- Script Playwright by hand to make a demo video, or click by coordinates
- Click through the app in a browser to discover labels: read the source, then let `rehearse` tell you
- Film before `rehearse` is green, or without resetting what the rehearsal consumed
- Use `open` to move inside the app after step 1
- Write a `see` the screen does not really show at that moment
- Film a long wait in real time instead of cutting it, or a long demo as one scenario instead of parts
- Buy time with `hover` or extra gestures: wait for the condition itself (`wait: {gone}`, `wait: {enabled}`)
