---
name: sprint-check
description: Cross-check the user's assigned Jira tickets against the real state of the code — merged, open and draft pull requests — to surface the statuses that are wrong, the tickets nobody has taken, and which ticket is the next logical one to pick up, with the reason. Use when the user asks for a tour of their Jira tickets, asks what to work on next, says statuses are out of date, or prepares a sprint review. Read-only: it proposes transitions, it never applies them.
argument-hint: [PROJECT-KEY]
---

Chat with the user in their language, the labels and table headers below included; this skill file stays in English.

Jira statuses drift because they are updated by hand and the code moves faster. This skill rebuilds the truth from the code, compares it to Jira, and names the gap. It proposes, it does not transition.

## 1. Jira

Every Jira read follows the `jira-read` skill: the route (acli first, MCP as fallback), the site read from `acli jira auth status`, the `--fields` limits of `search`, the status names. Do not invent a second route.

Assigned tickets, still open, restricted to `$ARGUMENTS` when a project key is given (`AND project = <KEY>`):

```bash
acli jira workitem search \
  --jql 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' \
  --fields "key,summary,status,issuetype" --limit 50 --json
```

The epic and the last-updated date come from one `view` per ticket (`jira-read` §4), only for the tickets that end up in the report.

## 2. Real state, from the code

```bash
gh pr list --author @me --state all --limit 100 \
  --json number,title,state,headRefName,baseRefName,isDraft,mergedAt,url
```

Extract the Jira keys from each PR title, body and branch name with the pattern of `jira-read` §1. A PR can carry several keys; a ticket can have several PRs. Build the mapping both ways before concluding anything.

## 3. The three findings

**a. Statuses that contradict the code.** The board's status names are read from the search output, every run, and quoted verbatim: a board can gain a status without telling anyone. Place each one on the workflow (not started, in progress, in test) from the order the tickets themselves show, then:

- PR merged, ticket still not started or in progress → status behind, it should be in test.
- PR open or draft, ticket still not started → status behind, it should be in progress.
- Ticket in progress with no branch, no PR and no commit carrying its key → probably back to waiting, to confirm with the user.

The target status is proposed by its exact name, taken from the ones already in use across the user's tickets, or from the MCP `getTransitionsForJiraIssue` when those are not enough (`jira-read` §5). Never guess one.

**b. Tickets nobody has taken.** Same JQL with `assignee IS EMPTY AND sprint IN openSprints()`. Report them only when they belong to an epic the user is already working in — a list of everything unassigned is noise.

**c. The next logical ticket.** One proposal, not a ranking. Justify it in one or two sentences on what is actually verifiable: the epic already in progress, a dependency now unblocked by a merged PR, a ticket whose sibling was just delivered. If nothing stands out, say so instead of manufacturing a reason.

When the repository is linked to a theTribe Studio, the Studio's decisions weigh in too: cite the one touching the candidate. The link, `.claude/studio-link.json`, is untracked and therefore absent from a worktree, so read it from the main checkout:

```bash
git rev-parse --path-format=absolute --git-common-dir   # <main checkout>/.git
```

No link file: skip it without a word.

## 4. Report

Three short sections, in that order: statuses to fix (table: ticket, current status, expected status, evidence), free tickets in my epics, proposed next ticket. Each row of the first table must carry its evidence — a PR number, a merge date. A proposed correction without evidence does not get listed.

End with the list of `acli` commands that would apply the corrections, ready to run, and stop there.

## 🚫 Never

- No `acli jira workitem transition`, `assign`, `comment`, `create` or `edit`. Same for the Atlassian MCP write tools. This skill reads.
- No Jira write of any kind without an explicit go, and when the go comes, any rich text goes in as ADF, never raw Markdown.
- No conclusion that a ticket is delivered from its status alone: the proof is a merged PR carrying the key, with the acceptance criteria read against the code.
- No branch, no worktree, no stack. This skill does not start work, it decides what the work should be.
