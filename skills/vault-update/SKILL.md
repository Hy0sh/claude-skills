---
name: vault-update
description: Use when the user asks to update their Obsidian vault or memory — « mets à jour Obsidian », « mets à jour le vault », « mémorise ça », « note ça dans le vault », "update my notes/memory". Proposes what to remember from the session, checks project notes against the Studio, writes only after approval. Never writes on its own initiative.
---

# vault-update

`~/notes` is the user's only Claude memory (auto memory is off). `commun/index.md` loads in every session; `projets/<x>/index.md` loads in the sessions of project `<x>` because `<repo>/CLAUDE.local.md` is a symlink to it. Nothing reaches the vault unless the user asked, and nothing is written before they agree.

## 1. Locate

- Main repo: `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` (works from any worktree). No repo → common notes only.
- Project: `readlink "<main repo>/CLAUDE.local.md"` → `~/notes/projets/<x>/index.md`. No symlink → common only, and offer once to create the project (step 5).
- Studio: `studioRoot` in `<main repo>/.claude/studio-link.json`, if present. Read-only, always.
- Health check first: `test -e` on the symlink target and on `~/notes/commun/workflow-rules.md`. A missing target means a note was renamed or moved in Obsidian and that session ran without it (Claude skips a broken import silently): report it before anything else and offer the fix.

## 2. Propose

From the session (and what the user just dictated), list candidates. Keep only what will still be true and useful in a month: a rule, a decision, a trap, a preference, a command. Drop session state, what git/Jira/the code already says, and anything unverified (or mark it `non vérifié`).

For each candidate, one line:
`[créer|modifier] <path> — <the fact in one sentence>`
- Destination: `commun/` if it holds on any project (dev preferences, ways of working, generic traps), `projets/<x>/metier/` or `projets/<x>/technique/` otherwise. A project name or client fact never goes in `commun/`.
- Prefer modifying an existing note over creating one: `grep -ril` the vault first.

## 3. Check the Studio (project notes only)

For each project candidate that touches business rules, glossary or decisions, find the matching Studio passage (grep the Studio for its key terms). Show every divergence side by side:

```
Écart — <subject>
  Vault  : <…>
  Studio : <…> (<Studio file>)
```

Never decide which is right. Duplicating the Studio is fine; contradicting it silently is not.

## 4. Ask, then write

Ask with AskUserQuestion (keep / change / drop per candidate, and a side for each divergence). Then write with the `obsidian:obsidian-markdown` format:
- frontmatter `type` (regle | decision | piege | preference | reference), `projet` (`commun` or `<x>`), `maj` (today, YYYY-MM-DD);
- one subject per note, short; link it from its index with `[[...]]` and a one-line hook.
- An index stays at ~60 lines max: past that, group lines into a sub-note and link it instead.

Show `git -C ~/notes diff --stat` and the diff, commit only after the user's go: `git -C ~/notes add -A && git -C ~/notes commit -m "<projet>: <what>"`.

## 5. New project (on request)

Create `~/notes/projets/<x>/index.md` (frontmatter `type: index`, `projet`, `repos: [<repo dir name>]`, `maj`; Studio path if any; sections `## Métier`, `## Technique`), then `ln -s ~/notes/projets/<x>/index.md "<main repo>/CLAUDE.local.md"`, and check `git -C "<main repo>" check-ignore -q CLAUDE.local.md`; if not ignored, append `CLAUDE.local.md` to `<git-common-dir>/info/exclude`. Never an `@import` in `CLAUDE.local.md`: an import outside the project needs a per-folder approval and is silently skipped in new worktrees.

## Never

- Write to the Studio, or into a client repo beyond the `CLAUDE.local.md` symlink and its line in `.git/info/exclude`.
- Put one client's facts in another client's folder or in `commun/`.
- Write without the user's explicit agreement in this run.
