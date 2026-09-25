---
name: pr-watch
description: Take stock of the user's own open pull requests in one pass — conflicts with the base branch, CI verdict, unanswered review threads, and position in a stack — then propose an ordered list of actions. Use when the user asks for the state of their PRs, asks which ones are blocked, mentions conflicts across several PRs, or asks to repair a stack of dependent PRs. Read-only: it proposes, it never merges, rebases or force-pushes on its own.
argument-hint: [repo-owner/repo-name]
---

Chat with the user in their language; this skill file stays in English.

This skill answers one question: **which of my open PRs need me right now, and in what order.** It reads, it reports, it proposes. It changes nothing.

## Why it is read-only

Rebasing a stack is destructive on the wrong guess: a force-push on the wrong branch loses commits that only exist there. The value here is the diagnosis and the ordering, which are cheap and safe. The mutations are three commands the user can run in ten seconds once they agree with the plan, and they stay the user's call.

## 1. Collect

Default to the repository of the current directory; `$ARGUMENTS` overrides it. Everything below is read-only.

```bash
gh pr list --author @me --state open --limit 50 \
  --json number,title,headRefName,baseRefName,mergeable,mergeStateStatus,isDraft,reviewDecision,updatedAt,url
```

**`mergeable` lies on first read.** GitHub computes the merge state lazily: a PR that has not been visited recently comes back `UNKNOWN`, not `CONFLICTING` or `MERGEABLE`. Never report `UNKNOWN` as "no conflict". Re-query the PRs that came back `UNKNOWN` once after a few seconds; if they are still unknown, say so explicitly rather than guessing.

CI verdict, per PR:

```bash
gh pr checks <number> || true
```

The `|| true` is not optional: `gh pr checks` exits non-zero when a job is pending (8) or failing (1), and both are states this report exists to surface.

Unanswered review threads need GraphQL — the REST comments endpoint does not carry the resolved flag:

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:50){ nodes{
        isResolved isOutdated
        comments(first:1){ nodes{ author{login} path body createdAt url } }
      }}
    }
  }
}' -f owner=<owner> -f repo=<repo> -F pr=<number> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | {path: .comments.nodes[0].path, author: .comments.nodes[0].author.login, url: .comments.nodes[0].url}'
```

## 2. Read the stacks

A PR whose `baseRefName` is not the repository's default branch sits **on top of another PR**. Build the chains from the `headRefName` → `baseRefName` edges before proposing anything.

Two consequences the report must carry:

- **Repair order is bottom-up.** Rebasing the top of a stack while its base is still stale re-creates the conflict one commit later. The PR closest to the default branch goes first, then each one above it.
- **A merged base is a trap.** When the base PR of a stack has been merged, the PR above it keeps pointing at a branch that no longer moves; GitHub may report it mergeable while its diff still shows the base PR's commits. Flag it as "base mergée, à rebaser sur la branche par défaut", not as healthy.

## 3. Report

One table, one line per PR, ordered by urgency (blocked first, then waiting on the user, then healthy):

| PR | Titre | Base | Conflit | CI | Fils ouverts | État |
|---|---|---|---|---|---|---|

Then, underneath, the **ordered action list**, each line naming the exact command the user would run. Group the ones that belong to the same stack and say so. If nothing needs doing, say that in one line rather than padding the report.

Never present an action as done. Never say a PR is clean when its merge state came back `UNKNOWN`.

## 🚫 Never

- No `git rebase`, `git merge`, `git push --force`, `gh pr merge`, `gh pr edit`, `gh pr close`.
- No comment, no reply, no review verdict on any PR. Review threads are read to be counted and summarised, never answered from here: a review reply is the user's own words, not generated text.
- No stack started, no test run, no build. The CI verdict is read, never reproduced.
- Nothing about PRs the user does not own: this is `--author @me` only.
