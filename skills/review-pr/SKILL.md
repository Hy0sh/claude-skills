---
name: review-pr
description: Review a GitHub pull request and provide structured, actionable feedback
argument-hint: [pr-number]
---

The review itself is read-only — produce it without any write or mutation action. The **only** mutation this skill may perform is posting the drafted inline comments (see the dedicated section below), and **only** after the user explicitly says to. Never approve, never request changes, never post a GitHub review verdict.

All outputs MUST be written in French.

- Use clear, professional French.
- Keep code, file paths, and technical identifiers in their original language (e.g., English).
- Do not translate code snippets.

Review the GitHub pull request number $ARGUMENTS.

!`gh pr view $ARGUMENTS --json title,body,author,state,files,additions,deletions,commits,headRefName,baseRefName,isCrossRepository`
!`gh pr diff $ARGUMENTS`
!`gh pr checks $ARGUMENTS`

## ⚙️ Required setup before reading any file

The diff alone is **not enough** to review correctly: any file you `Read` would otherwise come from the currently checked-out branch (often `develop` / `main`), not from the PR. This produces incoherent reviews where claims about "missing imports", "dead code", or "stale state" reflect the base branch, not the PR.

PR branches are also **remote-authoritative**: contributors force-push freely. A local copy from a previous session is almost certainly stale. Always treat `origin/<headRefName>` as the source of truth.

Before producing the review:

1. Verify the worktree is clean (`git status`). If not, **stop and ask the user** — never stash or discard work.
2. Remember the current branch so you can offer to restore it at the end.
3. **Fetch first**: `git fetch origin <headRefName>` (or `git fetch origin` if the PR comes from a fork — see `isCrossRepository`). Never skip this — the local copy of the PR branch may be hours or days old.
4. Check out the PR with `gh pr checkout $ARGUMENTS`.
   - If `gh pr checkout` reports divergence (a stale local branch exists from a prior session and the remote was force-pushed since), the local branch is disposable — it only exists for review purposes. Resync it with `git reset --hard origin/<headRefName>` (after confirming the worktree is clean). PR branches are not user work; resetting them does not destroy anything.
   - If the worktree is dirty, network fails, or anything else blocks the checkout, surface the error and stop.
5. Confirm you are on the PR head: `git rev-parse --abbrev-ref HEAD` matches `headRefName`, **and** `git rev-parse HEAD` matches `git rev-parse origin/<headRefName>`. Both must agree before you read any file.
6. Only then start reading files. Every claim about file content must come from the PR branch, not from the diff or the base branch.

## 🔄 Re-verify before producing the final review

PRs can be force-pushed **during** your review. Just before you write the structured review:

1. Re-run `git fetch origin <headRefName>`.
2. Compare `git rev-parse HEAD` to `git rev-parse origin/<headRefName>`.
3. If they differ, the PR moved while you were reading. Reset to the new remote head, re-read the affected files, and only then produce the review. Do not finalise a review against a known-stale snapshot.

If at any point the user says "you didn't pull" / "the code is outdated" / "I pulled the branch" / similar, treat that as a hard signal: re-fetch, recompare HEAD to `origin/<headRefName>`, and re-verify the diff before defending any prior comment.

## 🧠 Review method — inline, single-agent

Once you are confirmed on the PR head, review the PR **yourself, inline, in this single agent**. Do **not** use the Workflow tool and do **not** spawn review subagents (Agent/Task): the whole review runs in the main agent against the checked-out PR branch. Fan-out re-pays the full context for every agent spawned and is the dominant token cost; a single-context review is far cheaper and loses no rigor at the PR sizes seen here.

Proceed dimension by dimension, covering only the ones the diff actually touches, from: *Backend logic & security*, *Frontend*, *Tests & coverage*, *Code quality & i18n*. For each dimension, read the relevant files from the PR branch (use `git diff origin/<baseRefName>...HEAD -- <path>` to see the exact changes) and collect findings with: `severity` (blocker | major | suggestion | positive), `file` (path:line), `snippet`, `explanation`, `suggestion` — all human-readable text in French.

**Self-verify every blocker and major before reporting it.** For each, re-read the real code and trace the full flow (e.g. frontend → backend) while actively trying to **refute your own finding**: is it already neutralised upstream? a misread of the base branch? an i18n "missing key" that pluralisation resolves? Drop refuted findings, and surface notable ones in a short "faux positifs écartés" note so the author sees what was considered and dismissed. Dedupe findings that recur across dimensions. Suggestions and positives need no verification.

**Do not run the project's checks — the GitHub CI already did.** A review never runs the test suite, the linters, the formatters, the type-check or the build. The CI ran all of them on the PR head; `gh pr checks` (prefetched above) is the authoritative result, and re-running them locally burns minutes, spins up stacks, mutates databases and produces failures caused by the local setup rather than by the PR — noise that has to be untangled before it can be discarded.

Read the CI signal instead, and read it precisely:
- **All green** → the suite passes, the build compiles, the format is clean, the custom gates pass. Never report "the tests might fail" or "this might not compile" against a green CI: if a static trace suggests a compile/lint/test failure, the trace is wrong or the gate does not cover that path — say which. State the CI verdict and the head SHA it ran on in the review's overview.
- **Red or missing** → name the failing job, open it (`gh run view <run-id> --log-failed` or the job URL from `gh pr checks`) and report the real failure. A red CI is itself a blocker; do not re-derive it locally.
- **Stale** (the checks ran on an older SHA than `origin/<headRefName>`) → say so explicitly rather than crediting the PR head with a run it never got.

CI covers "does it build and pass", not "does it behave correctly". Behaviour is established by a **rigorous static trace**: read the actual call site the finding depends on (not an assumed one), the actual handler/middleware/framework code involved (not an assumed default), and cite any existing repo test that already proves part of the chain — an existing green test exercising half the chain is real evidence for that half, and the CI proves it ran.

**One targeted probe is allowed, and only one kind.** When a blocker/major genuinely hinges on a fact a read cannot settle (what a value actually is at runtime, what an existing helper actually returns), a single scoped, read-only, seconds-long probe is fine — a `manage.py shell` one-liner, a single `yarn test -- --testPathPattern=<file>` on an already-running stack. Hard limits, no exceptions: never start, restart, stop or `down` a stack; never create, seed, migrate or write to any database; never install dependencies; never run a whole app's or suite's tests. If the probe needs any of that, it is not allowed — skip it.

**Always state the evidence level of each blocker/major**, in one clause: "tracé statiquement" vs "confirmé par le test X, vert en CI" vs "confirmé par une sonde". Never present a static trace as if it were observed at runtime. When the trace leaves a genuine gap, name the gap and offer the user a follow-up run they can approve — do not close it silently, and do not downgrade a well-traced finding merely because no run happened.

**Severity gate — reproducibility and probability, not just plausibility.** Before keeping a finding at blocker/major, apply both checks:

1. **Reproducible by a human, deterministically.** Can a person trigger the failure through ordinary UI/API actions, without needing exact simultaneous timing between two independent actors? A scenario that only fires when two writers hit the same row within the same millisecond (e.g. an agent and a citizen editing the same record at the same instant) is not major/blocker-grade unless something in the code meaningfully widens that window (a long-held lock, a slow external call, a retry loop, high real-world concurrency on that exact row). Default such coincidence-dependent races down to a suggestion, and say why in one line.
2. **Missing test coverage is not itself a blocker/major.** If self-verification traces the change and confirms the resulting behavior is correct — consumers already handle the new state, the logic matches an established pattern elsewhere in the codebase — then the finding is "add a regression test for X," which is a suggestion, even when X is an important code path. Only keep blocker/major severity when the trace itself turns up a live, currently-wrong behavior — not when the code is right but unguarded.
3. **An unannounced behavior change is not automatically a bug.** Before flagging "this changed without being mentioned in the PR description" as major, check whether the new behavior matches a convention already established by sibling code in the same area (same file, same component family, same layer). If it does, the finding is "call this out explicitly in the PR description / confirm intentional," at suggestion level — reserve major for behavior that actually diverges from what surrounding code and users would reasonably expect.

When a user pushes back asking to re-check majors/blockers specifically on these grounds, re-run this gate on each one rather than re-asserting severity from the original pass.

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
- File path
- Code snippet
- Explanation
- Suggested fix

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

If no samples come back, fall back to a concise, collaborative-colleague tone. Otherwise reproduce whatever you observe: tutoiement vs vouvoiement, `stp`/`svp`, light emojis (`:)` `🙏` `😅`), `→` for the concrete consequence, `file:line` in backticks, a one-line concrete fix (ideally pointing at a twin pattern already in the repo), and a soft closing question. Keep each comment short — problem → consequence → suggested fix, no preamble.

**Anchoring rule (matters for posting).** An inline comment must attach to a line **present in the PR diff**. If the line you want to flag is *not* in the diff (e.g. an unchanged call site that should have been touched), anchor on the nearest added/changed line in the same hunk that is thematically related, and reference the true line number in the comment text. Compute the final-file line number from the diff hunk header (`@@ -a,b +c,d @@`).

Present the drafts to the user for review **before** posting anything.

## 📮 Posting the comments inline (only on explicit go-ahead)

Posting is the only mutation this skill allows, and only after the user explicitly approves (e.g. "post them", "commente", "vas-y"). Until then, the comments stay as proposals in your response.

When approved, post each one as an inline review comment on the PR head. Use the verified head SHA (`git rev-parse origin/<headRefName>`):

```bash
gh api "repos/<owner>/<repo>/pulls/<pr>/comments" --method POST \
  -f commit_id="<head-sha>" \
  -f path="<path>" \
  -F line=<final-file-line> \
  -f side="RIGHT" \
  -f body="<comment text>" \
  --jq '.html_url'
```

Report the resulting `html_url` for each posted comment in a short table. If the user only wants some of them posted, post that subset.

## 🚫 Important constraints
- DO NOT approve the PR
- DO NOT request changes via GitHub (no `gh pr review`)
- DO NOT use `gh pr comment` (top-level conversation comment) — comments go inline via the `pulls/<pr>/comments` API only
- DO NOT simulate a GitHub review action
- DO NOT post anything before the user has seen the drafts AND explicitly approved posting
- DO NOT run the test suite, the linters, the formatters or the build — read `gh pr checks`
- DO NOT start, stop or reconfigure a stack, and DO NOT create, seed or migrate a database
- The review text itself is output as plain text in this response

After the review (and any posting), offer to switch back to the branch the user was on before the checkout.
