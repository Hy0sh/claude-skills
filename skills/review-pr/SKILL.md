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

**Then close the gap a read alone can't close: attempt an actual run.** A static trace can miss a guard elsewhere in the call chain, or assume framework behavior instead of reading what it actually does (e.g. how *this* project's exception handler responds to an unhandled exception, not what DRF/Django does by default). Before finalizing severity on any blocker/major, try to **execute** the reproduction, not just read code that plausibly leads to it.

Respect the same isolation constraints as any other execution in this environment — most projects using worktrees carry their own rules for this (check the project's CLAUDE.md / memory for a worktree-docker or similar convention); absent a project-specific one, default to:
- Never restart, stop, `down`, or reconfigure a shared `docker compose` stack, and never write to a shared/dev database — other sessions may depend on either being untouched.
- Prefer something disposable and scoped to the review: a throwaway test (backend: a one-off `manage.py test` case or an isolated `manage.py shell` call exercising the exact call site; frontend: `yarn test -- --testPathPattern=<file>` or a small throwaway test typing/dragging the exact input), or an isolated container/worktree stack the project's own tooling already knows how to spin up.
- A real existing test in the repo that already exercises half the chain (e.g. the backend rejecting a value) counts as run-verification for that half — don't re-derive it by hand, but don't let it stand in for the half it doesn't cover either.

**When a run genuinely can't be set up** (no environment available, prohibitive setup cost for the finding's weight) — say so explicitly rather than quietly reporting a traced finding as if it were run-verified. Push the static trace as far as concrete evidence allows instead of stopping at "plausible": read the actual call site the finding depends on (not an assumed one), read the actual handler/middleware/framework code involved (not an assumed default), and cite any existing repo test that already proves part of the chain. Then offer the user a follow-up run if they want the remaining gap closed. Never assign blocker/major severity, or say "reproductible", on a read alone when a run was feasible and skipped — and when the user asks whether a finding actually reproduces, this is the bar to re-apply: point to the run's real output, or to the specific concrete evidence that closes every gap a run would have closed.

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
- The review text itself is output as plain text in this response

After the review (and any posting), offer to switch back to the branch the user was on before the checkout.
