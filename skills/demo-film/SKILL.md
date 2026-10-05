---
name: demo-film
description: Use when a web app has to be filmed doing something — a demo video of a feature, a pull request, a bug reproduction — with `demo-film`, a Go CLI that plays a declarative YAML scenario headless, checks that each expected text is on screen, and writes an mp4 with captions under the page plus a chapter list. Covers installing it, writing a scenario in its closed vocabulary, the check / rehearse / film cycle, reading its errors, and the traps of real apps (menus, home-made widgets, iframes, new tabs).
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

## 1. The cycle

```
demo-film check scenario.yaml            # no browser: schema and rules
demo-film rehearse scenario.yaml -o dir  # plays everything, no pause, no video (seconds)
demo-film film scenario.yaml -o dir      # the take: demo.mp4 + chapters.md
```

- Iterate with `rehearse` only; film once it is green. A take lasts the length of the video.
- A failure names the step, the action and what was looked for, and leaves `rehearse-fail-step<N>.png`: **read the screenshot** before changing anything. It answers most questions (wrong label, element not shown yet, a dialog in the way).
- Before the take, reset the data the rehearsal consumed (the record it created, the mails it sent), so the take starts from the state step 1 expects. A rehearsal that creates something is not idempotent.
- Keep the scenario out of any public repo when it names a client's app, accounts or URLs.

## 2. Writing the scenario

```yaml
title: "Short title of the demo"
base_url: http://app.localhost:3000
locale: fr                 # optional: i18next language, set before the app loads
hide: [".dev-toolbar"]     # optional: dev overlays hidden while filming
speed: 1                   # optional: 0.25-4, gestures only (0.5 = twice as slow)
labels: {step: "Étape", check: "vérifie", see: "Tu dois voir :"}   # caption words in the viewer's language
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
| `fill: {field, value}` | field by label, placeholder, rank (`1`) or `password`; typed visibly |
| `select: {field, option}` | native `<select>` only |
| `press`, `hover`, `wait` | a key, the cursor onto an element, a text to wait for |
| `popup: {click, url_contains}` | a link opening a new tab: the URL is checked, the tab is not filmed |
| `confirm: "Button"` | a button of the last opened dialog (an "abandon changes?" prompt) |
| `within: dialog` | modifier on click, fill, select, hover, wait: look only in the last open dialog |

Rules `check` enforces, and why:

- **No `open` inside the app after step 1**: it reloads the app, and the video shows a blank page. Navigate through menus and links like a user.
- **A step never ends on a forward button** (Next, Suivant, Continue): its "you should see" would be shown on the next screen. Put that click first in the next step.
- **A `check` step has a `see`**: an acceptance point is proven on screen, not asserted in a caption.

## 3. Finding the right names

The time goes into naming elements the way the app exposes them. Find them in this order, and **never explore the app in a browser** to collect labels — clicking through the journey by hand costs more than the whole film:

1. The repo's demo recipe, when there is one (the `demo-pr` skill says where).
2. The source: the screen's components and the translation files hold the exact labels, in the viewer's language.
3. `rehearse`: write the scenario with your best names and play it. A miss stops at the step, names what was looked for, lists the names visible on that screen, and leaves a screenshot: correct and play again, a few seconds per round.

An accessibility snapshot is for one screen only, the one where a rehearsal just failed and its message and screenshot were not enough.

- **Menus**: the visible label of the entry, which is often shorter than the page title ("Places", not "Place bookings"). Parents are often buttons, children links; `menu` handles both.
- **Home-made widgets** (dropdowns, time pickers, comboboxes): not a native `<select>`. Open them with `click` on their trigger — a button inside a `<label>` takes the label's text as its accessible name, so `click: {role: button, name: "Start time"}` — then `click` the option's text.
- **Text that appears later**: a badge or a summary may only render on the next screen; `see` what the current screen really shows.
- **Duplicated labels**: `click: "Save"` takes the first visible one; scope with `within: dialog`, `{role, name}` or a table `row`.
- **Iframes** (a mail catcher's message body): `see` looks into frames; actions do not.
- **New tabs**: assert them with `popup`; show the target afterwards by navigating to it in the app.
- **Absence** ("no mail to the author") cannot be checked yet: say it in `expect`, and check it yourself outside the video.

## 4. Output

- `demo.mp4`: the page untouched (only a visible cursor and click halo), captions in a band under it, starting once the app shows.
- `chapters.md`: step, acceptance point, minute, caption, expectation. It is for you, not for the viewer: the captions already name each step, so hand over the video alone.
- Check one or two frames of key steps before handing the video over, at the minutes `chapters.md` gives (`ffmpeg -ss <t> -i demo.mp4 -frames:v 1 f.png`, then read the image).

## Never

- Install the tool, the browser or ffmpeg yourself
- Script Playwright by hand to make a demo video, or click by coordinates
- Click through the app in a browser to discover labels: read the source, then let `rehearse` tell you
- Film before `rehearse` is green, or without resetting what the rehearsal consumed
- Use `open` to move inside the app after step 1
- Write a `see` the screen does not really show at that moment
