---
name: review-pr
description: Review a GitHub pull request and provide structured, actionable feedback
argument-hint: [pr-number]
---

This skill is **read-only end to end**. It writes nothing to GitHub: not a comment, not a reply, not a review verdict, not an approval. It produces the structured review and ready-to-post drafts, and the reviewer posts by hand — see the dedicated section for why that is deliberate and not a limitation. The only writes it may perform are local and to its own workspace: the worktree and stack it sets up to observe behaviour, and the scratchpad files it writes for itself.

All outputs MUST be written in the user's language.

- Use clear, professional wording.
- Keep code, file paths, and technical identifiers in their original language (e.g., English).
- Do not translate code snippets.

Review the GitHub pull request number $ARGUMENTS.

!`gh pr view $ARGUMENTS --json title,body,author,state,files,additions,deletions,commits,headRefName,baseRefName,isCrossRepository`
!`gh pr diff $ARGUMENTS`
!`gh pr checks $ARGUMENTS || true`

`gh pr checks` exits non-zero when a job is pending (8) or failing (1) — both are
states this review has to report on, hence the `|| true`. Never drop it: without it
the skill refuses to load on any PR whose CI is not entirely green.

## ⚙️ Required setup before reading any file

The diff alone is **not enough** to review correctly: any file you `Read` would otherwise come from the currently checked-out branch (often `develop` / `main`), not from the PR. This produces incoherent reviews where claims about "missing imports", "dead code", or "stale state" reflect the base branch, not the PR.

PR branches are also **remote-authoritative**: contributors force-push freely. A local copy from a previous session is almost certainly stale. Always treat `origin/<headRefName>` as the source of truth.

**Decide where the PR gets checked out before you check it out anywhere.** Run `wtm project list` first — that single read-only command picks the route below, and getting the order wrong is not recoverable later in the session. Checking the PR branch out in the *current* worktree occupies it, and git then refuses `wtm create <headRefName>` for the rest of the session (`fatal: '<branch>' is already used by worktree at ...`). That dead end lands exactly when a blocker or major needs runtime confirmation, with no way out but abandoning the checkout — so take route A up front whenever it applies, even when you expect to find nothing worth running.

### Route A — project registered with `wtm` (preferred)

1. Verify the current worktree is clean (`git status`). If not, **stop and ask the user** — never stash or discard work.
2. `wtm create <headRefName>`. One command does the whole setup: it fetches (a branch that only exists on the remote included), checks the PR branch out in **its own** worktree, starts that worktree's isolated stack on remapped ports, and plays the project's `post_create` seed if it has one. Invoke the `wtm` skill for the lifecycle and its two disciplines.
   - The branch already has a wtm worktree (`wtm list`)? `wtm start <headRefName>`, then resync it: `wtm run <headRefName> -- git fetch origin <headRefName>` then `wtm run <headRefName> -- git reset --hard origin/<headRefName>`. A review worktree is disposable; resetting it destroys nothing.
   - `wtm create` refuses because the branch is checked out elsewhere? Free it there (`git checkout <that worktree's own branch>`) and retry. Never work around it with a throwaway branch pointing at the same commit — that gets you a stack whose branch name matches nothing on the PR.
   - No seed ran and the stack needs data? Seed it with the project's own seed command via `wtm exec`, never with a reset script (it drops the restored dump).
3. `cd $(wtm path <headRefName>)` — read every file, and run every `git diff`, from there.
4. Confirm you are on the PR head **in that worktree**: `git rev-parse --abbrev-ref HEAD` matches `headRefName`, **and** `git rev-parse HEAD` matches `git rev-parse origin/<headRefName>`. Both must agree before you read any file.
5. Clean up at the end: `wtm remove <headRefName>`, or `wtm stop <headRefName>` if the user may come back to it. Never stop or remove a worktree you did not create.

The user's own worktree is never touched on this route, so there is no branch to restore when the review ends.

### Route B — project not registered with `wtm`

1. Verify the worktree is clean (`git status`). If not, **stop and ask the user** — never stash or discard work.
2. Remember the current branch so you can offer to restore it at the end.
3. **Fetch first**: `git fetch origin <headRefName>` (or `git fetch origin` if the PR comes from a fork — see `isCrossRepository`). Never skip this — the local copy of the PR branch may be hours or days old.
4. Check out the PR with `gh pr checkout $ARGUMENTS`.
   - If `gh pr checkout` reports divergence (a stale local branch exists from a prior session and the remote was force-pushed since), the local branch is disposable — it only exists for review purposes. Resync it with `git reset --hard origin/<headRefName>` (after confirming the worktree is clean). PR branches are not user work; resetting them does not destroy anything.
   - If the worktree is dirty, network fails, or anything else blocks the checkout, surface the error and stop.
5. Confirm you are on the PR head: `git rev-parse --abbrev-ref HEAD` matches `headRefName`, **and** `git rev-parse HEAD` matches `git rev-parse origin/<headRefName>`. Both must agree before you read any file.

On either route: only then start reading files. Every claim about file content must come from the PR branch, not from the diff or the base branch.

## ♻️ Is this a first pass or a re-review?

Most PRs get reviewed more than once: the author pushes fixes, the branch is rebased, and the reviewer comes back. A second pass that re-reads the whole diff from `origin/<base>` re-derives everything already settled, and re-raises findings the author has since fixed. Decide which pass you are on **before** reading any file — the answer changes both the diff range and the setup.

Detect it with one read-only call, after the setup has told you the repo and PR number:

```bash
gh api "repos/<owner>/<repo>/pulls/<pr>/comments" \
  --jq '.[] | select(.user.login=="<reviewer-login>") | {path, line, sha: .original_commit_id, body: .body[0:80]}'
```

No comments from the reviewer: **first pass**, proceed normally.

Comments already there: **re-review**. Three things change.

1. **Narrow the diff range.** Take the most recent `original_commit_id` among those comments — that is the head that was last reviewed. Read `git diff <last-reviewed-sha>...HEAD` instead of `git diff origin/<baseRefName>...HEAD`. If that SHA is no longer reachable (the branch was rebased or force-pushed since), say so and fall back to the full range rather than guessing.
2. **Account for the standing findings first.** For each existing comment, state whether it is **addressed**, **partly addressed** or **not addressed**, with the line of code that settles it. This comes before any new finding: the reviewer's first question on a second pass is always what happened to the previous round.
3. **Reuse the environment.** If `wtm list` already knows `<headRefName>`, `wtm start` plus the resync from route A is enough — do not `wtm create` a second stack. Building nine containers again for a three-file follow-up is the single most expensive mistake this skill can make.

The severity gate, the runtime-proof requirement and the drafting rules apply unchanged to whatever new findings the narrowed range turns up.

## 🔄 Re-verify before producing the final review

PRs can be force-pushed **during** your review. Just before you write the structured review:

1. Re-run `git fetch origin <headRefName>`.
2. Compare `git rev-parse HEAD` to `git rev-parse origin/<headRefName>`.
3. If they differ, the PR moved while you were reading. Reset to the new remote head, re-read the affected files, and only then produce the review. Do not finalise a review against a known-stale snapshot.

On route A these three run inside the wtm worktree (`wtm run <headRefName> -- …`, or from `$(wtm path <headRefName>)`), never in the user's own worktree — and a reset there means the running stack now serves the new head, so re-check a symbol from the new diff inside the container before reusing any earlier observation.

If at any point the user says "you didn't pull" / "the code is outdated" / "I pulled the branch" / similar, treat that as a hard signal: re-fetch, recompare HEAD to `origin/<headRefName>`, and re-verify the diff before defending any prior comment.

## 🧠 Review method — inline, single-agent

Once you are confirmed on the PR head, review the PR **yourself, inline, in this single agent**. Do **not** use the Workflow tool and do **not** spawn review subagents (Agent/Task): the whole review runs in the main agent against the checked-out PR branch. Fan-out re-pays the full context for every agent spawned and is the dominant token cost; a single-context review is far cheaper and loses no rigor at the PR sizes seen here.

Proceed dimension by dimension, covering only the ones the diff actually touches, from: *Backend logic & security*, *Frontend*, *Tests & coverage*, *Code quality & i18n*. For each dimension, read the relevant files from the PR branch (use `git diff origin/<baseRefName>...HEAD -- <path>` to see the exact changes) and collect findings with: `severity` (blocker | major | suggestion | positive), `file` (path:line), `snippet`, `explanation`, `suggestion` — all human-readable text in the user's language.

**Self-verify every blocker and major before reporting it.** For each, re-read the real code and trace the full flow (e.g. frontend → backend) while actively trying to **refute your own finding**: is it already neutralised upstream? a misread of the base branch? an i18n "missing key" that pluralisation resolves? Drop refuted findings, and surface notable ones in a short "dismissed false positives" note so the author sees what was considered and dismissed. Dedupe findings that recur across dimensions. Suggestions and positives need no verification.

The static trace is the **prerequisite**, not the proof. Every trace rests on at least one implicit assumption about the framework or the runtime ("the component does not remount when the search changes", "this middleware runs before that one"), and a wrong assumption at blocker/major severity hands the author the cost of the verification. So a finding only keeps that severity once it has been **observed at runtime** — see the runtime-confirmation section below.

**Do not re-run the project's checks — the GitHub CI already did.** A review never re-runs the test suite, the linters, the formatters, the type-check or the build. The CI ran all of them on the PR head; `gh pr checks` (prefetched above) is the authoritative result, and replaying them locally burns minutes and produces failures caused by the local setup rather than by the PR — noise that has to be untangled before it can be discarded. This is about the mergeability gates only: driving the app to observe a specific behaviour is a different activity, required for blockers and majors, and covered below.

Read the CI signal instead, and read it precisely:
- **All green** → the suite passes, the build compiles, the format is clean, the custom gates pass. Never report "the tests might fail" or "this might not compile" against a green CI: if a static trace suggests a compile/lint/test failure, the trace is wrong or the gate does not cover that path — say which. State the CI verdict and the head SHA it ran on in the review's overview.
- **Red or missing** → name the failing job, open it (`gh run view <run-id> --log-failed` or the job URL from `gh pr checks`) and report the real failure. A red CI is itself a blocker; do not re-derive it locally.
- **Stale** (the checks ran on an older SHA than `origin/<headRefName>`) → say so explicitly rather than crediting the PR head with a run it never got.

CI covers "does it build and pass", not "does it behave correctly". Behaviour starts with a **rigorous static trace**: read the actual call site the finding depends on (not an assumed one), the actual handler/middleware/framework code involved (not an assumed default), and cite any existing repo test that already proves part of the chain — an existing green test exercising half the chain is real evidence for that half, and the CI proves it ran. For a suggestion the trace is the whole story; for a blocker or a major it is only the half that tells you what to go and observe.

**Confirm every blocker and major at runtime before announcing it.** Once the static trace holds, drive the real surface until you have observed the defect: the wrong label on screen, the wrong response body, the request the frontend actually sends. Cheapest first — a scoped read-only probe (`manage.py shell` one-liner, `yarn test -- --testPathPattern=<file>`) on an **already-running** stack settles some findings in seconds. When the finding is about what a user sees, that is not enough, and you spin up an isolated stack for the worktree and drive it.

Isolation is the hard limit, not the effort. **Never** touch the shared stack, another worktree's stack, or a shared database. On route A the stack you need is already up from the setup step — reach it with `wtm exec <headRefName> -- …` and observe on the ports `wtm create`/`wtm list` printed, never on the main stack's ports (they serve the other code). Outside a `wtm` project, use whatever disposable equivalent the project offers. Clean up your footprint when the review is done. And check the container actually serves your checked-out code (`grep` a symbol from the diff inside it) before trusting what you see.

**A hand-rolled `docker run` is not that equivalent, and neither is a probe that reconstructs the input by hand.** Both are the standard way this discipline gets quietly dropped: the container is isolated, so it feels compliant, but a probe that imports one module and feeds it a literal you wrote yourself only observes the half of the chain you already believed. It proves "*if* this value arrives here, the output is wrong" — never that the value arrives. That is a static trace with extra steps, and it must be labelled as one. Drive the endpoint, the command, or the screen, on the stack from the setup step.

**State the evidence level of each blocker/major**, in one clause: "confirmed at runtime (screenshot)" vs "confirmed by test X, green in CI" vs "confirmed by a probe". Never present a static trace as if it were observed. **A finding that runtime did not confirm is not a blocker or a major** — either the trace was wrong and it goes away, or it stays as a suggestion saying plainly what could not be observed. Say what you observed and how; when the runtime check is genuinely out of reach (no stack for this project, an environment you cannot reproduce), say that too, and downgrade rather than announce.

Suggestions and positives need no run: they cost the author nothing to dismiss.

**Severity gate — reproducibility and probability, not just plausibility.** Before keeping a finding at blocker/major, apply all five checks:

1. **Reproducible by a human, deterministically.** Can a person trigger the failure through ordinary UI/API actions, without needing exact simultaneous timing between two independent actors? A scenario that only fires when two writers hit the same row within the same millisecond (e.g. an agent and a citizen editing the same record at the same instant) is not major/blocker-grade unless something in the code meaningfully widens that window (a long-held lock, a slow external call, a retry loop, high real-world concurrency on that exact row). Default such coincidence-dependent races down to a suggestion, and say why in one line.
2. **Missing test coverage is not itself a blocker/major.** If self-verification traces the change and confirms the resulting behavior is correct — consumers already handle the new state, the logic matches an established pattern elsewhere in the codebase — then the finding is "add a regression test for X," which is a suggestion, even when X is an important code path. Only keep blocker/major severity when the trace itself turns up a live, currently-wrong behavior — not when the code is right but unguarded.
3. **An unannounced behavior change is not automatically a bug.** Before flagging "this changed without being mentioned in the PR description" as major, check whether the new behavior matches a convention already established by sibling code in the same area (same file, same component family, same layer). If it does, the finding is "call this out explicitly in the PR description / confirm intentional," at suggestion level — reserve major for behavior that actually diverges from what surrounding code and users would reasonably expect.
4. **The repro has to exist outside your own fixtures.** Seed and factory data is written straight through the ORM, so it never passes the front-end validation a real user goes through, and half of it is deliberately partial. "This seeded record does not pass the form" therefore proves nothing about production. Before grading, name the path a user actually walks to that state — a draft the real flow persisted, a historical import, a creation from the agent side — and check it. If there is none, drop the finding instead of shipping it with a caveat: a caveat on an unreachable state still costs the author a reading, and the author is the one who knows it is unreachable.
5. **Check whose line it is before calling it a major of this PR.** Driving the UI turns up defects that are vivid, real, and living in files the diff never touches — a new entry point into an old bug is not a new bug. Confirm the defective line is in the diff; when it is not, report it under its own heading as a pre-existing defect, naming the untouched `file:line` and what it breaks, and let the reviewer choose between "fixed here" and "own ticket". Never let the blocker/major count absorb defects the PR did not introduce: it changes the verdict on the PR.

Checks 4 and 5 both guard the same trap, and it is the one runtime confirmation opens: **an observation feels like a conclusion because it was seen.** Being seen says nothing about who caused it, nor about whether anyone but you can reach it. The runtime step raises confidence that the behaviour is real — never that it belongs to this PR.

When a user pushes back asking to re-check majors/blockers specifically on these grounds, re-run this gate on each one rather than re-asserting severity from the original pass. A withdrawn finding is stated as withdrawn, with the reason, and the verdict recomputed — not quietly softened.

Scale depth to the PR and to user emphasis: "be thorough / audit this" → cover more dimensions and refute each blocker/major harder; a quick check → a lighter pass. **Trivial PR** — ≤ 2 files, a single layer, no security/permission/data-isolation surface: a quick inline pass is enough.

First, summarize the purpose and scope of the PR.

Then provide a structured review:

## 🔍 Overview
- What the PR does
- Key changes
- CI verdict and the head SHA it ran on (from `gh pr checks`), in one line

## ❗ Blockers (must fix before merge)
- Critical bugs, broken logic, security issues

## ⚠️ Major Issues
- Important concerns affecting maintainability or correctness

## 💡 Suggestions (minor improvements)
- Code quality, readability, naming, etc.

## 🧪 Tests
- Are new features tested?
- Missing edge cases?
- Test quality
- Judge the tests by reading them, not by running them — the CI result already says whether they pass

## 🔒 Security
- Injection risks
- Secrets exposure
- Auth issues

## 📍 Inline Comments
For each issue:
- File path and the line the comment anchors to
- Code snippet
- Explanation
- A suggested fix **only** when it carries a choice the author could not guess (see the drafting cap below — a trivial fix is left to the author)

## ✅ Positives
- What is well done

If the PR is large, prioritize high-impact issues and skip trivial comments.

End with a short summary of blockers and overall merge readiness.

## 💬 Draft inline comments for blockers + majors (in the reviewer's voice)

After the structured review, draft one ready-to-post inline comment **per blocker and per major issue** (skip suggestions and positives). These must read as if the user wrote them — match their voice, not a generic bot tone.

**Sample the reviewer's voice first.** The reviewer is the current GitHub user. Pull a handful of their recent inline review comments on this repo to mirror their register, then write in that style:

```bash
me=$(gh api user --jq '.login')
repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
for pr in $(gh search prs --repo "$repo" --commenter "$me" --limit 30 --json number --jq '.[].number'); do
  gh api "repos/$repo/pulls/$pr/comments" --jq ".[] | select(.user.login==\"$me\") | .body" 2>/dev/null
done | head -40
```

If no samples come back, fall back to a concise, collaborative-colleague tone. Otherwise reproduce whatever you observe: informal vs formal address, `→` for the concrete consequence, `file:line` in backticks.

**Then apply this cap on top of the sampled voice — it overrides anything the samples suggest:**

- **Two to three sentences, 110 to 500 characters.** Structure is problem → consequence (`→`), no preamble. End on the technical fact.
- **No closing question, no trailing "please".** Interrogative endings get removed by hand before posting; do not introduce them.
- **Do not hand over the solution when it is trivial.** A `&&` to flip to `||`, a key to rename, an argument to add: name the defect and its consequence, the author concludes. Writing the fix is condescending and pads the thread. A fix sentence survives only when it carries a choice the author could not guess — the kind of "Move it to `bookings.vehicles.index.tsx`" that names a destination.
- **Runtime evidence does not go in the comment.** Screenshots, console traces and repro scenarios stay in the conversation: they exist to settle severity with the reviewer, not to fill the thread. A "Checked locally: …" paragraph is exactly what gets deleted by hand from a posted thread.
- **Zero to one emoji**, ideally none. Never `😅🙏` in series.

**Anchoring rule (matters when the reviewer posts).** An inline comment must attach to a line **present in the PR diff**. If the line you want to flag is *not* in the diff (e.g. an unchanged call site that should have been touched), anchor on the nearest added/changed line in the same hunk that is thematically related, and reference the true line number in the comment text. Compute the final-file line number from the diff hunk header (`@@ -a,b +c,d @@`).

## 📮 The drafts are the end of the line — this skill never posts

**This skill performs no mutation at all.** It produces the structured review and the drafts, and stops there. The reviewer reads them, rewrites them in their own words, and posts them by hand.

The reason is a rule, not a technical limit. A comment posted from here lands under the reviewer's account, so it must be the reviewer's own words: using an LLM to help read a diff is fine, but the reviewer does their own pass and rewrites anything generated before it reaches the PR. Many teams go further and ban AI-generated review comments outright.

**The rule covers replies too**: a reply posted through `gh api .../comments/<id>/replies` is a comment under the reviewer's name like any other. When a review comes in, analyse it, verify it, measure if needed, then list the response material in conversation — the point raised, what is true or false in it, the numbers, what was fixed — and let the reviewer write and post.

So: present the drafts, say which file and which line each one anchors to, and stop. Do not offer to post them, and do not propose the `gh api` command that would.

## 🚫 Important constraints
- DO NOT write anything to GitHub: no inline comment, no reply in a review thread, no `gh pr comment`, no `gh api .../comments` POST. The drafts are handed to the reviewer, who posts them.
- DO NOT approve the PR
- DO NOT request changes via GitHub (no `gh pr review`)
- DO NOT simulate a GitHub review action, and DO NOT report a comment as posted
- DO NOT run the test suite, the linters, the formatters or the build — read `gh pr checks`
- DO NOT start, stop or reconfigure a shared stack, and DO NOT create, seed or migrate a shared database
- The review text itself is output as plain text in this response

After the review, clean up the setup you created. On route A, offer `wtm remove <headRefName>` (or `wtm stop <headRefName>` if the user may come back to it) — there is no branch to restore, the user's worktree was never touched. On route B, offer to switch back to the branch the user was on before the checkout.
