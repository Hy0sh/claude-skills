---
name: dailysum
description: Generate the user's own portion of a collaborative daily sum (the work done today), to paste into the team's Slack Canvas. Use when the user asks for their daily, dailysum, a summary of today's work or a daily project recap, in any language ("mon daily", "résumé des travaux du jour").
argument-hint: [YYYY-MM-DD]
---

This skill is **read-only**. It never writes to Git, GitHub, Jira, or Slack, and never posts anything. It only prints a draft block that the user pastes manually into the project's daily-sum Slack Canvas.

The output is **your portion only** of a collaborative daily sum: a short list of bullet points describing the work *you actually did today*, in the team's house style.

## Reference style (target output)

Bullets are short, in the user's natural language, one per work item (a PR, or a branch or ticket without one). The Jira key leads the line when the work item has one, state appended when in progress. The examples in this file are in English; every bullet, state word and label is written in the user's language:

```
* ABCTMA-15 hardening the import of large files
* cleanup of leftover tables, schema guard and seed hardening
* ABC-686 Start of a service's slot configuration, in progress
```

No PR numbers, no commit hashes, no stats — the Jira key is the only identifier that appears, and only at the start of the line. The conventional-commit prefix (`feat:`, `chore:`, `refactor(scope):`) is stripped. Audience is **technical but synthetic**.

## Determine the day

Use the date passed as `$ARGUMENTS` if present (format `YYYY-MM-DD`), otherwise today (system date). Window = that day `00:00:00` to `23:59:59` local time. Resolve the calendar date with `date +%F` (do not hardcode).

## Collect (the signal is *commits authored today*, not PRs merged today)

A PR merged today whose real work predates today must **not** appear. A work item started today with no PR yet **must** appear. So drive off commits, then enrich with PR titles and Jira labels.

Run these from the current repo. The `.git` is shared across worktrees, so `--all` captures every worktree's branches.

1. **Author identity — both of them.** A GitHub squash-merge rewrites the resulting commit's author on the base branch to the GitHub account's noreply email, even though the original commits on the feature branch carry your local git email. Missing either identity silently drops same-day PRs that got squash-merged. Resolve both:
   ```bash
   git config user.email; git config user.name
   gh api user --jq '(.id|tostring) + "+" + .login + "@users.noreply.github.com"'
   ```

2. **Commits authored today, across all branches/worktrees, under either identity** (subject + body, with ref decoration):
   ```bash
   git log --all --author="$(git config user.email)" --author="$GH_NOREPLY_EMAIL" \
     --since="$(date +%F) 00:00:00" --until="$(date +%F) 23:59:59" \
     --pretty=format:'%h%x09%D%x09%s%n%b' --date=local
   ```
   (`$GH_NOREPLY_EMAIL` = the email resolved in step 1; multiple `--author` flags OR together. Replace `$(date +%F)` with the target date when `$ARGUMENTS` is set.)

   The `--all` walk also surfaces `refs/stash` entries (commit subjects starting with `index on <branch>: ...` or `WIP on <branch>: ...`) — these are stash artifacts, not real work; drop them before synthesizing bullets.

3. **Active worktree branches** (to catch WIP work items that have no PR — e.g. a freshly started ticket):
   ```bash
   git worktree list
   ```

4. **PRs with activity, for clean titles + state:**
   ```bash
   gh pr list --author "@me" --state all \
     --json number,title,state,headRefName,createdAt,mergedAt,updatedAt --limit 50
   ```
   Match PRs to today's commits by `headRefName` (the branch the commits live on). Use the PR title for the clean wording; use its `state` for the work state (see below).

5. **Jira keys** — match `\b[A-Z][A-Z0-9]+-\d+\b` (any Jira key: a client often has two projects, `ABC` and `ABCTMA`, and a pattern built on one prefix silently misses every key of the other) in commit messages, PR titles and branch names. A work item's key is what opens its bullet, so this step is not optional enrichment. Extract, dedupe, then fetch each via the Atlassian MCP tool `getJiraIssue` (load it through ToolSearch: `select:mcp__claude_ai_Atlassian__getJiraIssue`) to phrase the `<KEY> Start of ...` items. If the MCP tool is unavailable, keep the key anyway and phrase from the PR title.

6. **PRs you reviewed today** (a count, not a list). Get your GitHub login, then count the distinct PRs on which you submitted at least one review today:
   ```bash
   me=$(gh api user --jq .login)
   repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
   day=$(date +%F)   # or the target date when $ARGUMENTS is set
   count=0
   for n in $(gh search prs --repo "$repo" --reviewed-by="$me" --updated=">=$day" --json number --jq '.[].number'); do
     n_today=$(gh api "repos/$repo/pulls/$n/reviews" \
       --jq "[.[] | select(.user.login==\"$me\") | select((.submitted_at // \"\") | startswith(\"$day\"))] | length")
     [ "${n_today:-0}" -gt 0 ] && count=$((count+1))
   done
   echo "PRs reviewed today: $count"
   ```
   Two gotchas: handle a null `submitted_at` (pending reviews) with `// ""` exactly as above — otherwise `startswith` errors, jq exits non-zero, and the count silently reads 0. And `submitted_at` is UTC: a review submitted late evening local time lands on the next UTC day — close enough for a daily count, but note it if a review seems missing.

## Synthesize the bullets

- **One bullet per work item** (PR or branch/ticket), not per commit. Fold multiple commits on the same branch into a single bullet.
- **Wording:** take the PR title, strip the conventional-commit prefix (`type(scope): `) and the trailing key suffix (` #ABC-123`, ` (ABC-123)`).
- **Key first:** when the work item has a Jira key, the bullet opens with it — `* ABC-666 an agent removing a member from a case`. One key per bullet; when a work item carries several, keep the one its PR title names. A work item with no key keeps the plain wording.
- **State suffix** (heuristic — the user will correct it):
  - PR merged on the target day → no state suffix.
  - PR open, or branch with today's commits but no merged PR → append `, in progress`.
  - Brand-new branch with only today's first commits and no PR → `Start of ` right after the key (`* ABC-666 Start of the validation ...`), or opening the bullet when there is no key, and append `, in progress`.
- **Exclude** purely administrative noise with no client value (e.g. a token/secret rotation bump) unless it was the day's actual work. When unsure, keep it.
- Keep it in the user's language, technical, synthetic. No PR numbers, no hashes — the Jira key is the only identifier. The **only** count allowed is the reviews line (see Output).
- **Reviews line:** when the review count from step 6 is ≥ 1, append a final bullet `* N PRs reviewed` (`* 1 PR reviewed` for a single one). Omit the bullet entirely when the count is 0.

## Output

Print **the bullets only** (no header line with the user's name — it is already in the Canvas template), inside a fenced code block so it is clean to copy-paste. The work item bullets come first, then the `* N PRs reviewed` bullet last (when ≥ 1). Then add one line outside the block reminding the user to review the guessed `, in progress` / `in review` states before pasting into the Slack Canvas.

If `gh` or Jira is unavailable, say so briefly and produce the best draft from the sources that did respond — never fail outright.
