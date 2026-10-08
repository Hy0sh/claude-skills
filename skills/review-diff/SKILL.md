---
name: review-diff
description: Use when a diff has to be reviewed for correctness before it ships — the current branch or working tree against its base, with no pull request needed. The canonical review method (dimensions, self-refutation, severity gate, runtime confirmation of every blocker and major) that review-pr and ticket-to-pr follow. Read-only on the code.
argument-hint: [base]
---

Chat with the user in their language; this skill file stays in English. Findings are written in the user's language; code, paths and identifiers stay as they are.

This skill reviews a diff and produces findings. It edits no file and writes nothing to GitHub or Jira: the caller decides what happens to the findings — `review-pr` drafts comments for a human reviewer, `ticket-to-pr` fixes them.

## What the caller provides

| Input | Default when invoked directly |
|---|---|
| The diff to review | the working tree against the base: `git diff origin/<base>`, plus every untracked file (`git status --porcelain`) read whole — new files are not in `git diff` |
| The checkout every file is read from | the current directory |
| The stack to observe on | the current worktree's, through `wtm exec <branch> -- …` (see the `wtm` skill); none → say so |
| The expected behaviour | the PR body, or the ticket and the edge cases settled for it |
| The mergeability verdict | not this skill's job: the caller has it (the CI on a PR, the local gates in `ticket-to-pr`) |

The base defaults to `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`, after a `git fetch origin`.

Every claim about file content comes from that checkout, never from the diff text alone or from another branch.

## Method — inline, single agent

Review the diff **yourself, in this single agent**. Do **not** use the Workflow tool and do **not** spawn review subagents: fan-out re-pays the full context for every agent spawned and is the dominant token cost; a single-context review is far cheaper and loses no rigor at the sizes seen here. Being run as a subagent by the caller is fine — the rule is against fanning out from here.

Proceed dimension by dimension, covering only the ones the diff actually touches, from: *Backend logic & security*, *Frontend*, *Tests & coverage*, *Code quality & i18n*. For each dimension, read the relevant files from the checkout (`git diff <range> -- <path>` for the exact changes) and collect findings with: `severity` (blocker | major | suggestion | positive), `file` (path:line), `snippet`, `explanation`, `suggestion`.

Whatever the dimensions, ask of every new path the diff adds **who triggers it today**: a screen and its action, an endpoint and the front component that calls it, a scheduled task, an import, traced in the code of the reviewed branch. A path nothing reachable triggers (a back-end use case no screen calls, a state no user action produces) is reported once, at the top of the output, as `Unreachable today: <path> — <why>`. It is information, not a defect: never a blocker or a major on that ground alone, and the effort the diff spends on it (performance, edge cases) is weighed against it.

**Self-verify every blocker and major before reporting it.** For each, re-read the real code and trace the full flow (e.g. frontend → backend) while actively trying to **refute your own finding**: is it already neutralised upstream? a misread of the base branch? an i18n "missing key" that pluralisation resolves? Drop refuted findings, and surface notable ones in a short "dismissed false positives" note so the reader sees what was considered and dismissed. Dedupe findings that recur across dimensions. Suggestions and positives need no verification.

The static trace is the **prerequisite**, not the proof. Every trace rests on at least one implicit assumption about the framework or the runtime ("the component does not remount when the search changes", "this middleware runs before that one"), and a wrong assumption at blocker/major severity hands the author the cost of the verification. So a finding only keeps that severity once it has been **observed at runtime** — see below.

**Do not re-run the project's checks.** A review never runs the test suite, the linters, the formatters, the type-check or the build: the mergeability verdict comes from the caller. Never report "the tests might fail" or "this might not compile" against a green verdict: if a static trace suggests a compile/lint/test failure, the trace is wrong or the gate does not cover that path — say which. Judge the tests by reading them. Driving the app to observe a specific behaviour is a different activity, required for blockers and majors.

Behaviour starts with a **rigorous static trace**: read the actual call site the finding depends on (not an assumed one), the actual handler/middleware/framework code involved (not an assumed default), and cite any existing repo test that already proves part of the chain — an existing green test exercising half the chain is real evidence for that half. For a suggestion the trace is the whole story; for a blocker or a major it is only the half that tells you what to go and observe.

## Runtime confirmation of every blocker and major

Once the static trace holds, drive the real surface until you have observed the defect: the wrong label on screen, the wrong response body, the request the frontend actually sends. Cheapest first — a scoped read-only probe (`manage.py shell` one-liner, `yarn test -- --testPathPattern=<file>`) on an **already-running** stack settles some findings in seconds. When the finding is about what a user sees, that is not enough: drive the screen.

Isolation is the hard limit, not the effort. **Never** touch the shared stack, another worktree's stack, or a shared database. Use the stack the caller provides — reach it with `wtm exec <branch> -- …` and observe on the ports `wtm` printed for it, never on the main stack's ports (they serve other code). Outside a `wtm` project, use whatever disposable equivalent the project offers. Check the container actually serves the checked-out code (`grep` a symbol from the diff inside it) before trusting what you see.

**A hand-rolled `docker run` is not that equivalent, and neither is a probe that reconstructs the input by hand.** Both are the standard way this discipline gets quietly dropped: the container is isolated, so it feels compliant, but a probe that imports one module and feeds it a literal you wrote yourself only observes the half of the chain you already believed. It proves "*if* this value arrives here, the output is wrong" — never that the value arrives. That is a static trace with extra steps, and it must be labelled as one. Drive the endpoint, the command, or the screen.

**State the evidence level of each blocker/major**, in one clause: "confirmed at runtime (screenshot)" vs "confirmed by test X, green in CI" vs "confirmed by a probe". Never present a static trace as if it were observed. **A finding that runtime did not confirm is not a blocker or a major** — either the trace was wrong and it goes away, or it stays as a suggestion saying plainly what could not be observed. When the runtime check is genuinely out of reach (no stack for this project, an environment you cannot reproduce), say that too, and downgrade rather than announce.

Suggestions and positives need no run: they cost the author nothing to dismiss.

## Severity gate — reproducibility and probability, not just plausibility

Before keeping a finding at blocker/major, apply all five checks:

1. **Reproducible by a human, deterministically.** Can a person trigger the failure through ordinary UI/API actions, without needing exact simultaneous timing between two independent actors? A scenario that only fires when two writers hit the same row within the same millisecond is not major/blocker-grade unless something in the code meaningfully widens that window (a long-held lock, a slow external call, a retry loop, high real-world concurrency on that exact row). Default such coincidence-dependent races down to a suggestion, and say why in one line.
2. **Missing test coverage is not itself a blocker/major.** If self-verification traces the change and confirms the resulting behavior is correct — consumers already handle the new state, the logic matches an established pattern elsewhere in the codebase — then the finding is "add a regression test for X," which is a suggestion, even when X is an important code path. Only keep blocker/major severity when the trace itself turns up a live, currently-wrong behavior — not when the code is right but unguarded.
3. **An unannounced behavior change is not automatically a bug.** Before flagging "this changed without being announced" as major, check whether the new behavior matches a convention already established by sibling code in the same area (same file, same component family, same layer). If it does, the finding is "call this out explicitly / confirm intentional," at suggestion level — reserve major for behavior that actually diverges from what surrounding code and users would reasonably expect.
4. **The repro has to exist outside your own fixtures.** Seed and factory data is written straight through the ORM, so it never passes the front-end validation a real user goes through, and half of it is deliberately partial. "This seeded record does not pass the form" therefore proves nothing about production. Before grading, name the path a user actually walks to that state — a draft the real flow persisted, a historical import, a creation from the agent side — and check it. If there is none, drop the finding instead of shipping it with a caveat: a caveat on an unreachable state still costs the author a reading, and the author is the one who knows it is unreachable.
5. **Check whose line it is before calling it a major of this diff.** Driving the UI turns up defects that are vivid, real, and living in files the diff never touches — a new entry point into an old bug is not a new bug. Confirm the defective line is in the diff; when it is not, report it under its own heading as a pre-existing defect, naming the untouched `file:line` and what it breaks, and let the reader choose between "fixed here" and "own ticket". Never let the blocker/major count absorb defects the diff did not introduce: it changes the verdict on the diff.

Checks 4 and 5 both guard the same trap, and it is the one runtime confirmation opens: **an observation feels like a conclusion because it was seen.** Being seen says nothing about who caused it, nor about whether anyone but you can reach it. The runtime step raises confidence that the behaviour is real — never that it belongs to this diff.

When the user pushes back asking to re-check majors/blockers on these grounds, re-run this gate on each one rather than re-asserting severity from the original pass. A withdrawn finding is stated as withdrawn, with the reason, and the verdict recomputed — not quietly softened.

Scale depth to the diff and to user emphasis: "be thorough / audit this" → cover more dimensions and refute each blocker/major harder; a quick check → a lighter pass. **Trivial diff** — ≤ 2 files, a single layer, no security/permission/data-isolation surface: a quick inline pass is enough.

## Output

The findings, grouped by severity — blockers, majors, suggestions, positives — each with its `file:line`, snippet, explanation, suggestion, and for blockers and majors the evidence level. Then the dismissed false positives, then the pre-existing defects under their own heading. The caller shapes the final presentation; invoked directly, end on one line: how many blockers and majors, and whether the diff is ready to ship.
