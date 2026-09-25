---
name: jira-read
description: Use when a task needs to read Jira — find which ticket the current branch, commits or PR are about, read a ticket in full with its comments, sub-tasks and links, or search tickets with JQL. The canonical read route (acli first with explicit fields, ADF flattened, Atlassian MCP as fallback) that other skills follow. Read-only.
---

Chat with the user in their language; this skill file stays in English.

This skill reads Jira and nothing else: no transition, no assignment, no comment. A skill that writes to Jira does it itself, behind its own approval gate.

## 1. Resolve the key

Probe **all** sources in one pass, then decide. They are local and free; stopping at the first hit only means coming back to the others when it turns out to be the wrong ticket.

```bash
git branch --show-current
git log --oneline -20
gh pr view --json title,body --jq '.title, .body' 2>/dev/null
```

Match keys with `\b[A-Z][A-Z0-9]+-\d+\b`, never with one project's prefix: a client often has two projects (`ABC` and `ABCTMA`), and a pattern built on one silently misses every key of the other.

Sources, by decreasing authority:

1. Key or URL in the user message (`ABC-1234`, `<site>/browse/ABC-1234`).
2. Current branch.
3. Commits of the branch, then PR title and body.

All agreeing, or only one source carrying a key → announce it in one line (`Ticket ABC-1234 — <summary>`) and continue.

Sources disagreeing, or several distinct keys → show in one message what each source gave (`branche : ABC-1234`, `commits : ABC-1234, ABC-1240`, `PR : ABC-1234`) and ask **once**. A branch carrying several keys is normal (a stacked PR): the user picks, or asks for all of them in sequence.

Zero keys anywhere → ask.

## 2. Pick the route

**acli first** (cheaper):

```bash
which acli >/dev/null 2>&1 && acli --version >/dev/null 2>&1 && echo "cli-ok" || echo "cli-absent"
acli jira auth status
```

`auth status` prints `✓ Authenticated` and the `Site:` it is logged into. That site is the one to use everywhere below, the MCP `cloudId` included: never hard-code one.

acli absent or not authenticated → Atlassian MCP, and say so in one sentence.

## 3. Read one ticket

```bash
acli jira workitem view ABC-1234 \
  --fields 'summary,status,issuetype,labels,description,comment,subtasks,issuelinks' \
  --json | jq -r '
def adf: [.. | objects | if .type == "text" then .text elif .type == "hardBreak" then "\n" elif (.type | IN("paragraph","heading","listItem","tableRow","panel","blockquote")) then "\n" else empty end] | join("");
"\(.key) — \(.fields.summary) [\(.fields.issuetype.name) / \(.fields.status.name)] labels=\(.fields.labels | join(","))",
"", "== DESCRIPTION ==", (.fields.description | adf),
"", "== COMMENTAIRES (\(.fields.comment.comments | length)) ==",
(.fields.comment.comments[]? | "[\(.created[0:10]) \(.author.displayName)] \(.body | adf)"),
"", "== SOUS-TACHES ==", (.fields.subtasks[]? | "\(.key) \(.fields.summary) [\(.fields.status.name)]"),
"", "== LIENS ==", (.fields.issuelinks[]? | "\(.type.name) \(.inwardIssue.key // .outwardIssue.key)")
'
```

Two traps in that command. `--fields` is not optional: the default set is `key,issuetype,summary,status,assignee,description`, so without it `comment`, `subtasks`, `issuelinks` and `labels` come back **missing** and the jq yields an empty list instead of failing. And every rich field is an ADF document, not text, hence the `adf` flattener rather than dumping the raw tree.

Read the **whole** comment thread, never only the last ones: a scope reduction, a dropped criterion or a PO arbitration lives there, and a later comment overrides the description. Very long thread (> 15) → keep the full text of the last 10 and one line per older one, and say that older comments were skimmed.

MCP fallback: `getJiraIssue` with `cloudId` = the site, `issueIdOrKey` = the key, `responseContentFormat` = `markdown`, `fields` = `summary`, `description`, `status`, `issuetype`, `comment`, `subtasks`, `issuelinks`, `labels`, `attachment`.

Empty sub-tasks in the view → JQL `parent = ABC-1234`.

## 4. Search

```bash
acli jira workitem search \
  --jql 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' \
  --fields "key,summary,status,issuetype" --limit 50 --json
```

**`search` and `view` do not accept the same `--fields`.** On `search`, the display set is limited to `issuetype,key,assignee,priority,status,summary`; anything else fails hard with `✗ Error: field '<name>' is not allowed` (seen for `parent` and `updated`). JQL can still filter and sort on those fields. When the epic or the last-updated date is needed, get it from `view`, one call per ticket, and only for the tickets that end up in the answer:

```bash
acli jira workitem view ABC-1234 --fields 'summary,status,issuetype,parent,updated' --json \
  | jq -c '{key, summary:.fields.summary, status:.fields.status.name, parent:(.fields.parent.key // "aucun"), updated:(.fields.updated[0:10])}'
```

## 5. Status names

A board's status names are its own: read them from the tickets themselves (the `status` of a search) and quote them verbatim, never translate or guess one. `acli jira workitem transition` has no flag that lists the statuses a ticket can move to; the MCP `getTransitionsForJiraIssue` is the only thing that enumerates them. A skill that later transitions a ticket and gets refused reports it and asks, rather than trying candidate names one after another.
