---
name: ticket-to-pr
description: Use when taking a Jira ticket from the ticket to the pull request — the user asks to work, take, handle, start or develop a ticket by its key, or asks whether a ticket is feasible and already covered before coding it. Covers prior art, the feasibility verdict, the isolated worktree and its stack, and the four approval gates.
argument-hint: <TICKET-KEY>
---

# Take a Jira ticket to a pull request

Orchestrator: the ticket in, a pull request out. Most steps are delegated — to the `jira-read`, `wtm` and `review-diff` skills of this plugin, and to whatever skills the project itself provides. The only new work is prior art, the business rules, the feasibility verdict and the worktree.

Chat with the user in their language; this skill file stays in English. Nothing is written to Jira, to git or to a PR before the go of one of the four gates below: the go of GATE 1 covers the worktree, the in-progress transition and the assignment of step 4.

## What the project provides

No setup step. Before step 3, work out each role below from what the repository already says, and announce the result in the feasibility report, one line per role, so the user can correct a wrong guess at GATE 1.

| Role | Project skill, when one covers it | Otherwise |
|---|---|---|
| Acceptance check | a skill whose description covers driving the app or checking a ticket against the running app | **ask the user** at GATE 1: a skill to follow, or a description (URL, accounts, how to log in, the path to walk) |
| Mergeability gates | a skill whose description covers reproducing the CI locally | read `.github/workflows/*.yml` (or `.gitlab-ci.yml`) and run the steps the diff can break |
| Commits and PR | a skill whose description covers commits or pull requests | **ask the user** at GATE 1: a skill to follow, or a description (commit format, PR title and body, draft or not). Offer what the history shows as the default answer: the shape of the last 20 commits, `.github/pull_request_template.md` if present, else the bodies of recent PRs |
| Base branch | — | `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` |
| Branch name | — | the dominant shape of `git branch -r --sort=-committerdate \| head -30`, e.g. `fix/<KEY>-<english-kebab-slug>`; `feat` or `fix` from the Jira issuetype |
| Feasibility locks | the project's `CLAUDE.md` and skills | what the code shows: migrations, feature flags, permissions |

Project skills are the ones listed in the session under their bare name, from the repository's `.claude/skills/`. Read each one at the step that needs it; never copy its content here.

### Remembered answers

The acceptance and the commits-and-PR questions are asked once per repository. The answers live outside the plugin, in the user's per-repository folder, where a plugin update cannot overwrite them:

```
~/.config/hy0sh-skills/repos/<owner>/<repo>/acceptance.md
~/.config/hy0sh-skills/repos/<owner>/<repo>/commits.md
```

`<owner>/<repo>` is `gh repo view --json nameWithOwner --jq .nameWithOwner`. A file holds either one line `skill: <name>` or the user's description, verbatim. It wins over a project skill found by its description: the user chose it.

File present → use it and name it in the report (`acceptance: acceptance.md`), no question. File absent and no project skill → ask at GATE 1, then write the answer to that file once the user has given it. A correction the user makes at GATE 1 overwrites the file.

## Checklist

```
- [ ] 0. Resolve the ticket key
- [ ] 1. Read the ticket, all comments included
- [ ] 2. Prior art: git, Jira, Studio
- [ ] 2 bis. Business rules, decisions and open questions in the Studio
- [ ] 3. Feasibility report            → GATE 1 (GO / NO-GO)
- [ ] 4. Worktree + stack, then Jira in progress + assign
- [ ] 5. Plan in milestones            → GATE 2
- [ ] 6. Implementation, one sonnet subagent per milestone
- [ ] 6 bis. Self-review, fixes, one re-review
- [ ] 7. Acceptance check
- [ ] 8. CI gates                      → GATE 3 (commits) → GATE 4 (Studio write-back, then PR)
```

A gate means: present, then stop. Waiting for a "go" is the point of the step.

## 0. Resolve the key

The command argument is the normal source (`/ticket-to-pr ABC-1234`). Branch, commits and PR stay fallbacks. Follow `jira-read` §1: probe every source in one pass, ask once when they disagree, never guess.

## 1. Read the ticket

Follow `jira-read` §2 and §3. Read the **whole** comment thread: a reduced scope, a dropped criterion or a PO arbitration lives there and nowhere else, and a later comment overrides the description.

## 2. Prior art

The question is "has this already been dealt with", and it has three answers to rule out: already delivered, a branch in flight, a duplicate ticket. Probe all three sources in one pass.

```bash
git log --all --oneline --grep 'ABC-1234'
git branch -a --list '*ABC-1234*'
gh pr list --search 'ABC-1234' --state all --json number,title,state,headRefName,url
```

Jira: `issuelinks` and sub-tasks come from step 1. Add a search on the significant words of the summary, bounded to the ticket's project, to catch the neighbour that shipped already (`jira-read` §4).

```bash
acli jira workitem search --jql 'project = ABC AND text ~ "word word" ORDER BY updated DESC' \
  --fields "key,summary,status" --limit 20 --json
```

Report what each source gave. A branch or a merged commit already carrying this key is announced **before** anything is created, and the user decides whether to continue.

Prior art is also in the code. Before writing a rule, find how the codebase already enforces the same rule or its nearest neighbour (a constraint checked on another screen, a scope applied to a sibling list, a fix just landed on the base for the same kind of defect) and reuse it rather than writing a second version. Search the **up-to-date** base: a branch cut days ago misses the fix a teammate just merged.

```bash
git fetch origin
git log --oneline "$(git merge-base HEAD origin/<base>)"..origin/<base> -- <paths the ticket touches>
```

Name in the report each neighbour found and whether the plan reuses it.

## 2 bis. Business rules, in the Studio

Only when the repository is linked to a theTribe Studio. The link, `.claude/studio-link.json`, is untracked: from a worktree it is simply absent, and a grep run there returns nothing without saying why. Resolve the main checkout first:

```bash
git rev-parse --path-format=absolute --git-common-dir   # <main checkout>/.git
```

No link file in the main checkout: skip this step and the Studio write-back of step 8, and say so in one line.

Otherwise read `studioRoot` from it. The Studio is the source of truth for the business, not Jira. A Jira ticket is a slice; the rule it has to respect, the arbitration that already narrowed it, the question still unanswered live under `studioRoot`. Read all four before writing the feasibility report:

| File under `studioRoot` | What it carries |
|---|---|
| `projet/regles-metier.md` | the numbered business rules `RM-XXX`, each with a status |
| `projet/decisions-log.md` | the dated decisions; a `superseded` one no longer binds, its replacement does |
| `projet/questions-ouvertes.md` | the `QO-XXX` the PO has not arbitrated |
| `backlog/EP-*/US-<number>-*.md` | the Studio's own write-up of this very ticket |

The backlog file name carries the Jira number **without** its project prefix, so `ABC-1158` is `backlog/EP-*/US-1158-*.md`; searching the full key in file names finds nothing. It often holds acceptance criteria the Jira description dropped.

```bash
ls "$studioRoot"/backlog/EP-*/US-1158-*.md
grep -ril '<business term>' "$studioRoot/projet" "$studioRoot/backlog"
```

Read the statuses, not just the text: an `obsolète` rule quoted as current is worse than no rule. Cite what you found in the feasibility report by its identifier (`RM-004`, `QO-002`, decision date) so the user can check the source. Nothing in the Studio on this subject is itself a finding: say so, and treat the ticket's business rule as unwritten.

## 3. Feasibility

Locate the technical surface: which layers, front or back, migrations or not. Then the locks that turn an easy ticket into a blocked one:

- the feasibility locks found above (feature flags gating the screen, migration constraints, permission catalogues, layering rules)
- a business rule or a locked decision read at step 2 bis that contradicts the ticket, or a `QO-XXX` still open on exactly the point the ticket asks you to settle
- anything the ticket needs that lives outside the application code (Helm, Ansible, cluster env)

Then trace the **entry point**: what produces, today on the up-to-date base, the data or the state the ticket handles — a screen and the action on it, an endpoint and the front component that calls it, a scheduled task, an import. Follow it in the code (the component calls the endpoint, the route is mounted, the flag gating it is on somewhere), never in the ticket's wording. A back-end path no screen calls, a state no user action can reach, a feature whose screen was ruled out by a decision: the ticket works on a zone **unreachable today**. That alone does not block it, the user may keep it on purpose ahead of a request, but it is announced at GATE 1, never discovered later by a reviewer.

Report: verdict, retained scope, **min/max range plus a risk level**, the entry point in one line (`Reached from: <screen › action | endpoint called by <component> | task | import>` or `Unreachable today: <why> — reachable once <what is missing>`), open questions, and the roles worked out in "What the project provides". When no project skill covers the acceptance check, or the commits and PR, the report ends on those questions: for each, a skill to follow or a description.

The report also lists the **edge cases** the ticket does not settle, one line each, with the reading you propose. Walk at least:

- a value the rule depends on being unknown or empty (an attribute not filled in yet)
- the intermediate and terminal states of the objects involved (pending, waiting list, refused, cancelled, archived): which ones count?
- several of the same at once (several people, several lines, several tenants)
- what already exists when the change ships: rows created before it, objects already in a state the new rule would forbid
- who sees and changes it when access is restricted to a subset (scope, tenant, role)
- volume: how many rows the largest tenant holds for what the ticket reads or loops over (families, children, lines, events), and which new path runs once per row — the place an N+1 hides

An edge case left unarbitrated is settled silently by whoever codes it. GATE 1 is where the user settles them, not the reviewer.

**GATE 1.** NO-GO on an ambiguous ticket, missing criteria, or a conflict with a locked decision. Say what is missing, where the conflict is, and which question the PO must answer. Then stop: no branch, no worktree, nothing written to Jira. A NO-GO is a deliverable, not a failure. An unreachable zone is not a NO-GO by itself: put it to the user as a question, keep it as is or wait for its entry point, with the consequence of each.

## 4. Worktree and stack

Branch name in the shape worked out above. Create it under its final name now: see `--as` below.

The worktree goes under the **main checkout's** `.claude/worktrees/`, on an explicit `origin/<base>`: `wtm` resolves a base in the main repository and never in a worktree, and a stale local base branch would cut the branch in the wrong place. Spell the absolute path out in each command — a worktree's own `.claude/worktrees/` is nested inside itself, and the isolation guard refuses a git command whose target it cannot verify, so no variables and no compound lines.

```bash
git worktree add /abs/path/to/repo/.claude/worktrees/ABC-1234 -b fix/ABC-1234-slug origin/develop
git worktree lock /abs/path/to/repo/.claude/worktrees/ABC-1234
```

The lock is what protects the worktree from the cleanup tools that delete unlocked ones.

Then `EnterWorktree` on that path (accepted from the main checkout and from another worktree alike, since the target sits under `.claude/worktrees/` of the same repository), and give it a stack where it stands, following the `wtm` skill:

```bash
wtm adopt -y     # index, remapped ports, provisioned .env, stack on the restored dump
```

Note the allocated ports the adoption prints: they are **not** the main stack's, and any URL a project skill gives assumes the main stack.

`--as` renames the branch on the way in, and adoption is the only moment it can be done: the branch is part of the compose project name, so a rename after the stack exists orphans it. Creating the branch under its final name makes `--as` unnecessary — never rename afterwards.

Project not registered in `wtm`: a plain worktree without a stack, and tell the user that `/wtm setup` would give it one.

Only now, the ticket moves: the in-progress status by its exact name (`jira-read` §5), then the assignment.

```bash
acli jira workitem transition --key ABC-1234 --status "<in-progress status>" --yes
acli jira workitem assign --key ABC-1234 --assignee '@me'
```

Transition refused, or the status absent from this workflow? Report it and ask. Do not try other status names one by one.

## 5. Plan

Milestones, each one dispatchable and each one verifiable on its own. Write it to the session scratchpad, never into the repository: the diff of this branch carries the ticket's code and nothing else.

Each milestone says what it delivers, the files it creates or modifies, how it is verified (the test, or what is observed on the running app), and which edge case settled at GATE 1 it implements. After the milestones, the risks: what the plan assumes without having checked it, a migration, a file another open branch also touches.

A milestone that adds or changes a list, a batch or a computation over many rows states its query budget: the number of queries at two volumes (it must not grow with the rows), measured in the test, and the response time on the project's volume data set when it has one. A count that grows with the rows is a defect of the milestone, not a later optimisation.

**GATE 2.** Present the plan and stop: no code and no subagent before an explicit go. A change asked here goes into the plan, which is presented again. When the work is relayed (an orchestrator or a supervising agent stands between you and the user), the plan goes to whoever relays it, and the go comes back the same way: a plan nobody approved is not approved.

## 6. Implementation

One subagent per milestone, `model: sonnet`, with a checkpoint between milestones. A red milestone stops the chain: no next milestone on a failing one.

Every agent works in the worktree, against its stack. Never `docker compose restart/stop/up/down` on a shared service, never mutate the main database.

## 6 bis. Self-review

Before the acceptance check, not after: a fix made after the captures invalidates them, while in this order step 7 proves the code that ships.

One **fresh** subagent follows the `review-diff` skill of this plugin — not a milestone agent, which carries the writer's assumptions, and not sonnet: the reviewer is at least the writer's model. Its prompt gives what `review-diff` asks the caller for:

- **The diff**: nothing is committed yet, so the working tree against the base, `git diff origin/<base>` plus the untracked files read whole — `origin/<base>...HEAD` would be empty.
- **The checkout and the stack**: the worktree path, its branch and the ports `wtm adopt` printed.
- **The expected behaviour**: the retained scope and the edge cases settled at GATE 1.
- **The mergeability verdict**: none to read — step 8 runs the gates.

Then the loop, bounded on purpose:

1. Each blocker and major the review confirmed at runtime is fixed by a sonnet subagent, one per finding, as in step 6.
2. **One** re-review by a fresh `review-diff` subagent, on the files the fixes touched (`git diff origin/<base> -- <those files>`), with the previous findings to account for: addressed, partly, not.
3. Whatever is still open goes to the GATE 3 report. No third round: a review and a fix that keep answering each other spin, and the user arbitrates a disagreement better than another pass.

Suggestions are listed at GATE 3, applied only if the user says so. Pre-existing defects are reported, never fixed here: they belong to their own ticket unless the user decides otherwise.

## 7. Acceptance check

Follow the acceptance check settled at GATE 1 — the project skill, or the user's description — with the worktree's ports. Green tests are not proof: the expected behaviour has to be observed on the real surface.

Before concluding, check the stack actually serves this code — grep a symbol written in step 6 from inside the container:

```bash
wtm exec fix/ABC-1234-slug -- grep -rn '<symbol just written>' .
```

### Prove the neighbour flows, not only the ticket's own

The ticket names one flow; the change also runs through the flows around it, and that is where reviews find the defects the happy path hid. For each row the change matches, observe the neighbour flow once on the real surface, or say why it does not apply:

| The change… | Also prove |
|---|---|
| adds a field or a relation to a central object | editing that object afterwards, duplicating or copying it, exporting it |
| adds a state, a lock or a freeze | every edit still allowed in the locked state, and every edit it must refuse |
| adds a choice (a level, an option, a price) | several items at once, each getting its own choice |
| restricts or filters by scope | the view of a user restricted to part of the data |
| adds a model tied to a person, a permission, or a registry entry | the exhaustive checks the project keeps (anonymisation, permission catalogue, predefined groups) |
| removes or transforms a field | the rows that exist before the migration |
| raises a new error | its message on every screen that calls the endpoint |

Proof that covers only the ticket's sentence is the proof the reviewer redoes.

### Look at every screenshot you take

**Read each image back before using it** — with the `Read` tool on the file, not by trusting the tool that reported writing it. An accessibility snapshot returns clean text whatever the CSS does: it reads the DOM, not the layout. A card whose text wraps one word per line, a pill overflowing its container, a column crushed to nothing, an element buried under an overlay — none of that appears in a snapshot, and all of it ships if the tree was the only thing checked.

Screenshots are this step's deliverable, so one nobody looked at fails it. What to catch: overflow past a container, text broken word by word or character by character, overlapping elements, something clipped or invisible, and a panel covering the surface (framework devtools especially — a stray click opens one and it may persist in `localStorage`).

### One folder per pull request on the Desktop

Captures go in `~/Desktop/<branch slug>/` — the branch name without its `feat/` or `fix/` prefix — named `<KEY>-<what>.png` inside it. Never loose on the Desktop.

The folder keys on the branch and not on the ticket, because one ticket can ship several pull requests and each needs its own captures; the branch is the only identifier that is 1:1 with the PR and already known when the captures are taken.

### When the acceptance check was a description

The user described how to check the ticket because the project has no acceptance skill. Add the traps met on the way to `acceptance.md`, so the next ticket starts from them. That file is the user's alone: once the check is green, offer — once, without insisting — to turn it into a project skill under `.claude/skills/`, which the rest of the team would get too. It is the user's call, and it goes in its own commit, never in this ticket's diff unless they say so.

## 8. CI gates, commits, PR

Gates scoped to what the diff can break, from the source worked out above: the non-test gates the diff can trip (format, lint, migrations in sync with models, generated schemas, translation catalogs) plus the tests of the modules touched. Never the whole test suite locally — that is the CI's job, and the report says which checks ran and which are left to the CI. From a worktree, `docker compose exec` resolves against the compose project of the current directory, so route every gate through `wtm`, which resolves the right project:

```bash
wtm exec fix/ABC-1234-slug -- <gate command>
wtm exec fix/ABC-1234-slug --service frontend -- <gate command>
```

A gate run from the main checkout validates the main tree and reports green for code never tested.

**Check the CI will actually run.** Read the workflow triggers once: a CI filtered on the base branch (`pull_request: branches: [...]`) skips a PR stacked on another feature branch, and GitHub shows "no checks" rather than a failure. On such a PR the local gates are the only net: say so in the report, and add the project's cross-cutting exhaustive tests (registries, catalogues, predefined groups) to the scoped set, since no diff-based selection points at them.

**GATE 3** before any commit, **GATE 4** before the PR, both conducted per the commits-and-PR convention settled at GATE 1 — the project skill, or the user's description. Nothing the convention does not say is added: no format, no signature, no section of your own.

### Write the decisions back to the Studio

Only when step 2 bis found a Studio. **At GATE 4, before opening the PR.** Every *business* decision taken since GATE 1 goes back to the Studio: a scope arbitration, a rule settled while coding, an interpretation of a criterion the ticket left open, a business rule found in the code and absent from `regles-metier.md`. A purely technical choice does not — that one belongs in the PR body.

`/studio:*` commands only run from the Studio folder, so the edit **is** the formalisation. Write it yourself under `studioRoot`, in the file's language and existing shape, never a new one:

| What was decided | File | Entry |
|---|---|---|
| A business rule now settled | `projet/regles-metier.md` | `### RM-XXX : <titre>` at the next free number, then `Statut` / `Règle` / `Source` / `Date` |
| An arbitration, a scope cut, a choice between two readings | `projet/decisions-log.md` | `### <AAAA-MM-JJ> — <titre>`, then `Statut` / `Contexte` / `Décision` / `Conséquences` / `Source` |
| A question you had to leave to the PO | `projet/questions-ouvertes.md` | `### QO-XXX — <question>`, then `Date` / `Source` / `Contexte` / `Statut` / `À adresser par` |

`Source` is the Jira key and the branch, e.g. `ABC-1234, fix/ABC-1234-slug`. Both files forbid deleting: an entry that replaces an older one flips that one to `superseded` and cross-links the two, exactly as their own header prescribes.

Then name in the gate report which Studio files moved and which identifiers were created. Nothing was decided beyond what the ticket already said? Write nothing, say so in one line — an invented entry pollutes the source of truth.

## Never

- Commit, push or open a PR without an explicit go at gates 3 and 4
- Merge, transition the ticket to a done status, or post an acceptance comment unasked
- Run `wtm remove` or delete the worktree: the cleanup is the user's
- Declare the ticket done because the tests or the CI gates are green
- Reach GATE 3 with a blocker or a major of the self-review neither fixed nor named in the report
- Present a stacked PR as green when no CI ran on it
- Touch a shared stack, a shared database, or anything but local
- Rename the branch after the stack exists
- Keep going past GATE 1 on an ambiguous ticket by picking an interpretation
- Guess how to check the ticket at runtime, or how to commit and write the PR, when no project skill covers it: ask
- Settle a business question on the ticket alone when a Studio exists, without having read its rules and decisions
- Open the PR while a business decision taken on the way is still only in this conversation

## When not to use

Prior art says it shipped, or the ticket is a duplicate: report and stop at step 2. A ticket with no code surface (ops, cluster, decision to take): the feasibility report is the whole deliverable. The user only wants the analysis: stop after GATE 1, which is a normal outcome and not an interruption.
