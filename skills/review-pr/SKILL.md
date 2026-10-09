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

## 🧠 Review method — follow `review-diff`

Once you are confirmed on the PR head, review it by following the `review-diff` skill of this plugin, inline in this agent — its dimensions, self-refutation, runtime confirmation of every blocker and major, and severity gate all apply unchanged. What it needs from this skill:

- **The diff**: `git diff origin/<baseRefName>...HEAD`, or the narrowed range of a re-review.
- **The checkout**: the PR worktree from the setup step.
- **The stack**: on route A, the one `wtm create` started — `wtm exec <headRefName> -- …` on the ports it printed. Clean up your footprint when the review is done.
- **The expected behaviour**: the PR title and body, and the ticket they name.
- **The mergeability verdict**: the CI, read as below.

**Do not re-run the project's checks — the GitHub CI already did.** The CI ran all of them on the PR head; `gh pr checks` (prefetched above) is the authoritative result, and replaying them locally burns minutes and produces failures caused by the local setup rather than by the PR — noise that has to be untangled before it can be discarded.

Read the CI signal instead, and read it precisely:
- **All green** → the suite passes, the build compiles, the format is clean, the custom gates pass. State the CI verdict and the head SHA it ran on in the review's overview.
- **Red or missing** → name the failing job, open it (`gh run view <run-id> --log-failed` or the job URL from `gh pr checks`) and report the real failure. A red CI is itself a blocker; do not re-derive it locally.
- **Stale** (the checks ran on an older SHA than `origin/<headRefName>`) → say so explicitly rather than crediting the PR head with a run it never got.

CI covers "does it build and pass", not "does it behave correctly": that half is `review-diff`'s, and an existing green test it cites is real evidence because the CI proves it ran.

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

## ❔ Not confirmed — runtime out of reach
- Blocker/major candidates `review-diff` could not observe, each with what blocked it; omit the heading when there are none
- The candidate accounting line from `review-diff`: produced, confirmed, refuted, out of reach

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
