---
name: vault-update
description: Use on your own, without being asked, as soon as a session yields something durable to remember — a rule or preference the user states, a correction of your way of working, a decision, a trap found — and when the user asks to update their Obsidian vault or memory — « mets à jour Obsidian », « mets à jour le vault », « mémorise ça », « note ça dans le vault », "update my notes/memory". The vault replaces Claude Code's auto memory: writes the note and its index line, commits, says it in one line; asks only when a project note contradicts the project's business source of truth (Studio, Jira…).
---

# vault-update

`~/notes` is the user's only Claude memory (auto memory is off). Each folder's index note is named after its folder, so Obsidian's graph labels it (`commun/commun.md`, `commun/acw/acw.md`, `projets/<x>/<x>.md`). `commun/commun.md` loads in every session; `projets/<x>/<x>.md` loads in the sessions of project `<x>` because `<repo>/CLAUDE.local.md` is a symlink to it. Like the auto memory it replaces, it is kept up to date without being asked: write as soon as something durable appears, then tell the user in one line what was noted and where. The one stop: a project note that contradicts the project's source of truth waits for the user's call (step 3).

## 1. Locate

- Main repo: `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` (works from any worktree). No repo → common notes only.
- Project: `readlink "<main repo>/CLAUDE.local.md"` → `~/notes/projets/<x>/<x>.md`. No symlink → common only, and offer once to create the project (step 5).
- Source of truth: the project index names it (« Source de vérité métier : … »): the Studio (path in `<main repo>/.claude/studio-link.json`), Jira (project key), or another. Whether the vault may ever write to it is also stated there; default read-only.
- Health check first: `test -e` on the symlink target and on `~/notes/commun/workflow-rules.md`. A missing target means a note was renamed or moved in Obsidian and that session ran without it (Claude skips a broken import silently): report it before anything else and offer the fix.

## 2. Propose

From the session (and what the user just dictated), list candidates. Keep only what will still be true and useful in a month: a rule, a decision, a trap, a preference, a command. Drop session state, what git/Jira/the code already says, and anything unverified (or mark it `non vérifié`).

When the user asked for a review of the whole session (« mets à jour Obsidian »), list the candidates in a markdown file outside any repo (e.g. `~/.claude/plans/vault/<date>-maj-vault.md`), one list item per candidate, `[créer|modifier] <path> (<type>) : <the fact in one sentence>`, render it with `hy0sh-skills:visual-plan`, and write them without waiting (step 4): the page is the record of what was noted. A single fact noted on your own needs no file.
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

A divergence is the only thing asked: with AskUserQuestion, or, from an orchestrator's master, as a decision parked under `## Choix à valider` (`(a) …; (b) …`, `Reco: (a)`). The candidate waits for the answer; the others are written at once.

## 4. Write, commit, tell

Write with the `obsidian:obsidian-markdown` format:
- frontmatter `type` (regle | decision | piege | preference | reference), `projet` (`commun` or `<x>`), `maj` (today, YYYY-MM-DD);
- one subject per note, short; link it from its index with `[[...]]` and a one-line hook.
- An index stays at ~60 lines max: past that, group lines into a sub-note and link it instead.

Commit the files you wrote, and only those (another session may be writing too): `git -C ~/notes add <files> && git -C ~/notes commit -m "<projet>: <what>"`. Then one line to the user: what was noted, in which note. Undoing it is theirs to ask.

## 5. New project (on request)

Create `~/notes/projets/<x>/<x>.md` (frontmatter `type: index`, `projet`, `repos: [<repo dir name>]`, `maj`; a « Source de vérité métier » line asked to the user (Studio, Jira, other) and whether the vault may write to it; sections `## Métier`, `## Technique`), then `ln -s ~/notes/projets/<x>/<x>.md "<main repo>/CLAUDE.local.md"`, and check `git -C "<main repo>" check-ignore -q CLAUDE.local.md`; if not ignored, append `CLAUDE.local.md` to `<git-common-dir>/info/exclude`. Never an `@import` in `CLAUDE.local.md`: an import outside the project needs a per-folder approval and is silently skipped in new worktrees.

Then give the project its colour in Obsidian's graph: in `~/notes/.obsidian/graph.json`, append to `colorGroups` `{"query": "path:projets/<x>", "color": {"a": 1, "rgb": <int>}}`, with an `rgb` (0xRRGGBB as an integer) far from the colours already used. Skip it if a group with that query exists. Obsidian rewrites this file from memory: tell the user to reload with « Recharger l'application sans enregistrer » (Cmd+P), or the group is lost.

## Never

- Write to the source of truth (Studio, Jira) unless the project index allows it, or into a client repo beyond the `CLAUDE.local.md` symlink and its line in `.git/info/exclude`.
- Put one client's facts in another client's folder or in `commun/`.
- Write a project note that contradicts its source of truth before the user chose a side.
- Note session state, what git, Jira or the code already says, or a guess.
