---
name: dailysum
description: Génère ta portion du daily sum collaboratif (travail mené aujourd'hui) à coller dans le Canvas Slack client. Utiliser quand l'utilisateur demande son daily, dailysum, résumé des travaux du jour, ou récap journalier projet.
argument-hint: [YYYY-MM-DD]
---

This skill is **read-only**. It never writes to Git, GitHub, Jira, or Slack, and never posts anything. It only prints a draft block that the user pastes manually into the project's daily-sum Slack Canvas.

The output is **your portion only** of a collaborative daily sum: a short list of bullet points describing the work *you actually did today*, in the team's house style.

## Reference style (target output)

Bullets are short, in natural French, one per work item (PR / chantier). The Jira key leads the line when the chantier has one, state appended when in progress:

```
* GALLIATMA-15 fiabilisation du découpage QR des scans volumineux
* nettoyage des tables reliquats, garde-fou de schéma et fiabilisation du seed
* GAL-686 Début de la configuration des activités et créneaux d'un pôle, en cours
```

No PR numbers, no commit hashes, no stats — the Jira key is the only identifier that appears, and only at the start of the line. The conventional-commit prefix (`feat:`, `chore:`, `refactor(scope):`) is stripped. Audience is **technical but synthetic**.

## Determine the day

Use the date passed as `$ARGUMENTS` if present (format `YYYY-MM-DD`), otherwise today (system date). Window = that day `00:00:00` to `23:59:59` local time. Resolve the calendar date with `date +%F` (do not hardcode).

## Collect (the signal is *commits authored today*, not PRs merged today)

A PR merged today whose real work predates today must **not** appear. A chantier started today with no PR yet **must** appear. So drive off commits, then enrich with PR titles and Jira labels.

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

3. **Active worktree branches** (to catch WIP chantiers that have no PR — e.g. a freshly started ticket):
   ```bash
   git worktree list
   ```

4. **PRs with activity, for clean titles + state:**
   ```bash
   gh pr list --author "@me" --state all \
     --json number,title,state,headRefName,createdAt,mergedAt,updatedAt --limit 50
   ```
   Match PRs to today's commits by `headRefName` (the branch the commits live on). Use the PR title for the clean wording; use its `state` for the work state (see below).

5. **Jira keys** — match `\b(GAL|GALLIATMA)-\d+\b` (both projects; a bare `GAL-\d+` pattern silently misses every `GALLIATMA-XX`) in commit messages, PR titles and branch names. A chantier's key is what opens its bullet, so this step is not optional enrichment. Extract, dedupe, then fetch each via the Atlassian MCP tool `getJiraIssue` (load it through ToolSearch: `select:mcp__claude_ai_Atlassian__getJiraIssue`) to phrase the `Début <KEY> ...` items. If the MCP tool is unavailable, keep the key anyway and phrase from the PR title.

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
   Two gotchas: handle a null `submitted_at` (pending reviews) with `// ""` exactly as above — otherwise `startswith` errors, jq exits non-zero, and the count silently reads 0. And `submitted_at` is UTC: a review submitted late evening Paris time lands on the next UTC day — close enough for a daily count, but note it if a review seems missing.

## Synthesize the bullets

- **One bullet per chantier** (PR or branch/ticket), not per commit. Fold multiple commits on the same branch into a single bullet.
- **Wording:** take the PR title, strip the conventional-commit prefix (`type(scope): `) and the trailing key suffix (` #GAL-XXX`, ` (GAL-XXX)`).
- **Key first:** when the chantier has a Jira key, the bullet opens with it — `* GAL-666 retrait d'un enfant du dossier par un agent`. One key per bullet; when a chantier carries several, keep the one its PR title names. A chantier with no key keeps the plain wording.
- **State suffix** (heuristic — the user will correct it):
  - PR merged on the target day → no state suffix.
  - PR open, or branch with today's commits but no merged PR → append `, en cours`.
  - Brand-new branch with only today's first commits and no PR → `Début ` right after the key (`* GAL-666 Début de la validation ...`), or opening the bullet when there is no key, and append `, en cours`.
- **Exclude** purely administrative noise with no client value (e.g. a token/secret rotation bump) unless it was the day's actual work. When unsure, keep it.
- Keep it French, technical, synthetic. No PR numbers, no hashes — the Jira key is the only identifier. The **only** count allowed is the reviews line (see Output).
- **Reviews line:** when the review count from step 6 is ≥ 1, append a final bullet `* N PR reviewées` (`* 1 PR reviewée` for a single one). Omit the bullet entirely when the count is 0.

## Output

Print **the bullets only** (no `@François B.` header line — the user's name line is already in the Canvas template), inside a fenced code block so it is clean to copy-paste. The chantier bullets come first, then the `* N PR reviewées` bullet last (when ≥ 1). Then add one line outside the block reminding the user to review the guessed `, en cours` / `en relecture` states before pasting into the Slack Canvas.

If `gh` or Jira is unavailable, say so briefly and produce the best draft from the sources that did respond — never fail outright.
