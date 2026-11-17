---
name: vault-update
description: Use when the user asks to update their Obsidian vault or memory — « mets à jour Obsidian », « mets à jour le vault », « mémorise ça », « note ça dans le vault », "update my notes/memory". Proposes what to remember from the session, checks project notes against the project's business source of truth (Studio, Jira…), writes only after approval. Never writes on its own initiative.
---

# vault-update

`~/notes` is the user's only Claude memory (auto memory is off). Each folder's index note is named after its folder, so Obsidian's graph labels it (`commun/commun.md`, `commun/acw/acw.md`, `projets/<x>/<x>.md`). `commun/commun.md` loads in every session; `projets/<x>/<x>.md` loads in the sessions of project `<x>` because `<repo>/CLAUDE.local.md` is a symlink to it. Nothing reaches the vault unless the user asked, and nothing is written before they agree.

## 1. Locate

- Main repo: `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` (works from any worktree). No repo → common notes only.
- Project: `readlink "<main repo>/CLAUDE.local.md"` → `~/notes/projets/<x>/<x>.md`. No symlink → common only, and offer once to create the project (step 5).
- Source of truth: the project index names it (« Source de vérité métier : … »): the Studio (path in `<main repo>/.claude/studio-link.json`), Jira (project key), or another. Whether the vault may ever write to it is also stated there; default read-only.
- Health check first: `test -e` on the symlink target and on `~/notes/commun/workflow-rules.md`. A missing target means a note was renamed or moved in Obsidian and that session ran without it (Claude skips a broken import silently): report it before anything else and offer the fix.

## 2. Propose

From the session (and what the user just dictated), list candidates. Keep only what will still be true and useful in a month: a rule, a decision, a trap, a preference, a command. Drop session state, what git/Jira/the code already says, and anything unverified (or mark it `non vérifié`).

Write the candidates to a markdown file outside any repo (e.g. `~/.claude/plans/vault/<date>-maj-vault.md`), grouped under one heading per destination (project notes, common notes), one list item per candidate:
`[créer|modifier] <path> (<type>) : <the fact in one sentence>`
The divergences of step 3 go in the same file. Then render it with the `hy0sh-skills:visual-plan` skill (page next to the markdown, same name, `.html`): the user reads the page, not a list in the chat.
- Destination: `commun/` if it holds on any project (dev preferences, ways of working, generic traps), `projets/<x>/notes/` otherwise (the index sorts them by theme). A project name or client fact never goes in `commun/`.
- Prefer modifying an existing note over creating one: `grep -ril` the vault first.

## 3. Check the source of truth (project notes only)

For each project candidate that touches business rules, glossary or decisions, find the matching passage in the project's source of truth: grep the Studio for its key terms, or search Jira (the `jira-read` skill) on the project key. Show every divergence side by side:

```
Écart — <subject>
  Vault  : <…>
  <source> : <…> (<file or ticket>)
```

Never decide which is right. Duplicating the source is fine; contradicting it silently is not. No source named in the index → say so and skip this step.

## 4. Ask, then write

Put the decision in the same file under `## Choix à valider`, as `(a) …; (b) …` list items, each with a `Reco: (a)`: keep all / some / none of the candidates, and a side per divergence. Re-render the page, so a board that shows it can take the answer. Outside such a board, ask with AskUserQuestion (keep / change / drop per candidate, and a side for each divergence). Then write with the `obsidian:obsidian-markdown` format:
- frontmatter `type` (regle | decision | piege | preference | reference), `projet` (`commun` or `<x>`), `maj` (today, YYYY-MM-DD);
- one subject per note, short; link it from its index with `[[...]]` and a one-line hook.
- An index stays at ~60 lines max: past that, group lines into a sub-note and link it instead.

Show `git -C ~/notes diff --stat` and the diff, commit only after the user's go: `git -C ~/notes add -A && git -C ~/notes commit -m "<projet>: <what>"`.

## 5. New project (on request)

Create `~/notes/projets/<x>/<x>.md` (frontmatter `type: index`, `projet`, `repos: [<repo dir name>]`, `maj`; a « Source de vérité métier » line asked to the user (Studio, Jira, other) and whether the vault may write to it; sections `## Métier`, `## Technique`), then `ln -s ~/notes/projets/<x>/<x>.md "<main repo>/CLAUDE.local.md"`, and check `git -C "<main repo>" check-ignore -q CLAUDE.local.md`; if not ignored, append `CLAUDE.local.md` to `<git-common-dir>/info/exclude`. Never an `@import` in `CLAUDE.local.md`: an import outside the project needs a per-folder approval and is silently skipped in new worktrees.

Then give the project its colour in Obsidian's graph: in `~/notes/.obsidian/graph.json`, append to `colorGroups` `{"query": "path:projets/<x>", "color": {"a": 1, "rgb": <int>}}`, with an `rgb` (0xRRGGBB as an integer) far from the colours already used. Skip it if a group with that query exists. Obsidian rewrites this file from memory: tell the user to reload with « Recharger l'application sans enregistrer » (Cmd+P), or the group is lost.

## Never

- Write to the source of truth (Studio, Jira) unless the project index allows it, or into a client repo beyond the `CLAUDE.local.md` symlink and its line in `.git/info/exclude`.
- Put one client's facts in another client's folder or in `commun/`.
- Write without the user's explicit agreement in this run.
