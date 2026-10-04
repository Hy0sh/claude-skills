---
name: demo-pr
description: Use when a pull request or a branch has to be shown working to a human who validates it step by step — before committing a ticket, when a reviewer or a PO wants to see a feature run, or when an orchestrator schedules the demos of several workers one after the other.
argument-hint: [branch|PR]
---

# Demo a pull request to a human

Chat with the user in their language; this skill file stays in English.

A green test proves what the agent checked; a demo proves what the human saw. This skill drives the running app while a human watches and validates each step. It edits no file and commits nothing: the caller decides what a KO leads to — `ticket-to-pr` fixes and replays, a reviewer writes it up.

**The human is the judge, not the agent.** The agent states what should appear *before* acting, then lets the human say what they see. An agent that acts first and then asks "it shows X, do you validate?" turns the human into a rubber stamp.

## What the caller provides

| Input | Default when invoked directly |
|---|---|
| The expected behaviour | the PR body, or the ticket via `jira-read`, with the edge cases settled for it |
| The stack and its ports | the branch's worktree stack, through `wtm` (see the `wtm` skill); never the main stack's ports, which serve other code |
| Accounts and how to log in | `~/.config/hy0sh-skills/repos/<owner>/<repo>/acceptance.md`, written by `ticket-to-pr`; absent → ask |
| The demo level | proposed from the risk below, settled by the human |
| Who relays the human's answers | the human, directly; under an orchestrator, its channel (the orchestrator passes each step on and brings back the answer) |

## 1. Pick the level

Propose one, with its reason in one line; the human settles it.

| Level | When | What it is |
|---|---|---|
| **async** | low risk: a label, a style, a contained fix | screenshots plus a checklist, validated by the human when they choose; no visible browser |
| **live** | a feature, a behaviour change | one step per acceptance criterion, in a visible browser |
| **live extended** | a migration, permissions, scoping, a central business flow | live, plus the neighbour flows the change runs through: editing or copying the object afterwards, the rows that existed before, the view of a user restricted to part of the data |

No visible surface (a command, a cron, a pure API change): the demo is the equivalent observation — a response body, a terminal output — shown with the same step loop, or one line saying why there is nothing to show.

## 2. Prepare before calling the human in

The human's time is the cost of a demo; nothing they wait on should happen after they arrive.

1. **The stack serves this code**: grep a symbol of the diff inside the container (`wtm exec <branch> -- grep -rn '<symbol>' .`).
2. **Data and session ready**: the records each step needs exist in this stack's database, the browser is logged in, the start page is open.
3. **The script**, written to the session scratchpad and sent to the human with the proposed level, in a message that ends the turn: step 1 starts once the human has settled both. The script is numbered steps, each one line *action* and one line *what you should see*. One step per acceptance criterion (plus the neighbour flows at the extended level) — not one per click. Each expectation quotes its criterion: one the ticket does not carry is a requirement invented by the script, and its KO is noise.

## 3. The visible browser

A live demo runs in a Playwright MCP server started **without** `--headless`: check the server's launch arguments (`~/.claude.json`, or the plugin's `.mcp.json`) rather than its name. Several servers may be configured — the headless ones exist for parallel agents and show the human nothing.

No headed server available → stop, report BLOCKED with that reason, and offer the async level. Never run a live demo headless.

## 4. The step loop

Each step has exactly this shape:

1. **Announce**: "Step N/M — <action>. You should see: <expectation>." Sent before acting.
2. **Act** in the visible browser.
3. **Capture**, then read the image back with `Read` (an accessibility snapshot does not show layout).
4. **Hand over and stop**: "Your verdict on step N: ok, or ko with what you see." Do not describe the result first. End the turn.

Then, by answer:
- **ok** → next step.
- **ko** → record what the human saw, verbatim, and stop the demo: see below.
- anything else (a question, "looks fine I guess", silence) → not an ok. Answer the question, then ask for the verdict again.

The last step follows the same shape: the demo is not over until its verdict is in.

### On a KO

The demo stops. Do not fix code, do not switch to another browser to investigate, do not replay. Give the caller:

- the step, its expectation, and what the human saw;
- your reading of it, in one line: **a defect** (the code does not do what the step expects) or **a scope gap** (the step expected something the ticket never asked for — a misread requirement goes back to the human or the PO, not to a fix).

After the caller's fix, replay **only the KO step and the steps whose code the fix touched**, not the whole demo.

## 5. Output

- One line per step: `N. <step> — ok` or `N. <step> — ko: <what the human saw>`.
- The screenshots in `~/Desktop/<branch slug>/` (the branch name without its `feat/` or `fix/` prefix), named `<KEY>-<step>.png`.
- One summary line the caller can put in the PR body: level, steps validated, by whom, date.

## Never

- Validate a step yourself, or treat anything but an explicit ok as one
- State the result before the human has given their verdict
- Chain two steps without a verdict in between, the last one included
- Fix code, or switch to a headless browser, during the demo
- Point the demo at the main stack's ports
