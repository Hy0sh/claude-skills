---
name: overlapping-prs
description: Plan how a set of pull requests that overlap — same files, same schema migration chain, same shared code — are cut, ordered and merged so that they stop colliding with each other: shared foundation first, a merge order fixed up front with a stack that follows it, and schema migrations kept as the last commit of each PR and regenerated at merge time instead of renumbered. Use whenever several pieces of work touch the same area, whatever groups them (a feature, a batch of bug fixes, a refactor, review follow-ups), before splitting them into PRs; or when open PRs keep falling into conflict after each merge, when every merge forces a migration renumbering on the others, or when two PRs created the same helper twice.
argument-hint: [the work items or the open PRs to plan]
---

Chat with the user in their language; this skill file stays in English.

Several PRs cut from the same base, touching the same area, and merged in whatever order the reviews come back collide in three predictable ways. What groups them does not matter (a feature, unrelated bug fixes in the same module, a refactor running next to a fix): **overlap is the criterion**. Each collision has a cheap fix, but only if it is decided **before the PRs are cut**, not after the third conflict.

## 0. Detect the overlap

Before planning, find out whether the PRs actually overlap. For work not yet started, list per item the files, migration chains (per app or schema) and shared code it will create or modify; for open PRs, read it from their diffs:

```bash
gh pr diff <n> --name-only
```

Overlap = two items share a file, a migration chain, or create the same kind of shared code (an access helper, an exception, fixtures, registry/barrel entries, translation catalogs). Items that share nothing are planned separately and merged in any order: say so and leave them out of the rest.

## The three collisions

| Collision | What it costs | Fix, decided before cutting |
|---|---|---|
| Every PR adds a schema migration on the same base head | every merge renumbers all the others, one at a time, each with a force-push | migration = last commit of the PR, regenerated at merge |
| Two PRs create the same shared code | duplicate files to merge by hand, review comments on code the other PR already wrote | a small foundation PR merged first |
| Merge order follows the reviews | each merge surprises the PRs left open | merge order written down, a stack that follows it |

## 1. Foundation PR first

List what more than one overlapping item needs: models and their migrations, permissions, shared helpers (object access, ownership checks), exceptions, test fixtures, enum values, translation keys. Put it in one small PR, reviewed and merged first. The other PRs are cut from it.

A foundation merged early is the one part that never conflicts. If nothing is shared, say so and skip this step.

## 2. Merge order fixed, and a stack that follows it

Write the merge order down with the reason (what each PR needs from the previous one). Then:

- **Dependent PRs stack in that order**: each one is based on the previous one's branch. When the bottom one merges, the next one only needs `git rebase --onto <base branch> <old head of the merged PR>`. Never a plain rebase: on a rebase-and-merge repository the merged commits get new SHAs, and a plain rebase replays them as dozens of false conflicts.
- **PRs that only share a file but not a dependency stay on the base branch**: a stack makes a slow review block everything above it. They still follow the written order, so the conflict, if any, is resolved once, by the one merged second.
- Ask for reviews in that order, bottom first, so the queue drains instead of piling up.

## 3. Migration as the last commit, regenerated at merge

A migration generated on day one is numbered against a base that will move. Renumbering it after every sibling merge is the costliest part of a busy area.

- Keep the schema migration in **its own last commit** of the PR, with nothing else in it.
- At merge time, for that PR only: drop the migration commit, rebase on the base branch, regenerate the migration with the framework's generator, commit it again as the last commit, push. The other open PRs are not touched.
- The migration commit is regenerated, so the review is about the models, not the generated file: say so in the PR body.
- **Does not apply to data migrations** (hand-written operations, data copies): those are not regenerated and still get renumbered by hand, with a re-read of their body against the new schema.
- Where the project has a renumbering tool, it remains the fallback for a PR that cannot follow this rule. Run one renumbering at a time when each needs a running stack.

What collides, and what "regenerate" means, depends on how the tool orders migrations:

| Ordering | Typical tools | What collides | At merge time |
|---|---|---|---|
| Sequential numbers | Django, Flyway | the number itself (two PRs create the same `0076`) | generated: regenerate; hand-written SQL: rename to the next free number |
| Revision graph | Alembic, Django's dependencies | two heads on the same parent | autogenerated: regenerate; otherwise re-point the parent to the new head |
| Timestamps | Rails, Laravel, Doctrine, Prisma | not the name, but the shared schema file (`schema.rb`, `structure.sql`, `schema.prisma`) and the order of application | regenerate the schema file from the base plus this PR; check the timestamp still sorts after the base's latest |

A hand-written migration is never regenerated, whatever the family: it is renamed or re-pointed, then re-read.

## 4. Output

When asked to plan, give back, in this order:

1. The overlap found (which items share what), and the items left out because they share nothing.
2. The foundation PR content, or "none needed" with the reason.
3. The overlapping PRs in merge order, each with its base (base branch or the PR below it) and the one-line reason for that position.
4. Which PRs carry a schema migration, and which of those are data migrations (the exception above).
5. The order in which to request reviews.

When called on PRs already open, read them first (base, migrations they add, files created by more than one), then say which of the three collisions are happening and what can still be applied to the work not yet cut.

## What this skill does not do

It plans, it does not rebase, push or merge. Repairing an existing stack is a job for a PR-state tool; the history rules of the project (amend before review, fixup after, force-push policy) still apply on top of this plan.
