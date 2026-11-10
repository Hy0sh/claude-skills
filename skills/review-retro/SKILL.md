---
name: review-retro
description: Use when the user wants fewer review comments on their own pull requests, asks why reviewers keep finding things their self-review missed, or asks to improve the review skills (review-diff, ticket-to-pr) or a repository's review checklist from the feedback they actually received, or asks to replay the review cases after such a change. Read-only on GitHub; proposes changes, applies them only on a go.
argument-hint: [since YYYY-MM-DD]
---

Chat with the user in their language; this skill file stays in English.

The feedback a reviewer leaves is the test the self-review failed. This skill reads that feedback on the user's own pull requests, sorts out what a self-review could have caught, and turns each recurring miss into a change to the review method or to the repository's checklist.

## Inputs

| Input | Default |
|---|---|
| Repository | `gh repo view --json nameWithOwner --jq .nameWithOwner` |
| Author | `gh api user --jq .login`: the user's own PRs only, never a colleague's |
| Period | everything: the PRs before the split date are the baseline |
| Split date | the `Last retro:` line of the checklist below; none → the date the user names, else no split. The misses listed are the feedback given since that date, which judges whether the last retro's changes helped |
| Checklist | `~/.config/hy0sh-skills/repos/<owner>/<repo>/review.md`, the file `review-diff` reads |
| Cases | `~/.config/hy0sh-skills/repos/<owner>/<repo>/review-cases.md`, the misses replayed in step 5 |

## 1. Collect and measure

Work in the session scratchpad:

```
python3 -I <this skill>/scripts/fetch_feedback.py <owner/repo> <author> <scratchpad>/retro <since> <split>
```

It writes the feedback items in chunks of about 90 and prints the rates by month, PR size, base branch, folder and reviewer, plus before/after the split date at equal size. A feedback item is a remark from someone other than the author and not a bot: the opening comment of an inline thread (replies are context, not more items), a conversation comment, or the text of a review. An approval with no text is not one.

Read the rates before classifying anything. Size usually explains more than any category, and a before/after comparison not done at equal size is meaningless.

## 2. Classify

One `model: sonnet` subagent per chunk, all in one message, each given `classify-prompt.md` with its `chunkN.json` and `outN.jsonl` paths. Then:

```
python3 -I <this skill>/scripts/aggregate.py <scratchpad>/retro <split>
```

It warns about unclassified items, prints the categories against how they could have been caught, and lists the misses since the split date, the conventions, and the business questions.

## 3. Turn each miss into its fix

Group the misses by the check that would have caught them, not by category, and send each group to where it belongs:

| What the misses have in common | Where the fix goes |
|---|---|
| A way of looking at code that applies to any project (comparing twin implementations, checking sibling endpoints, counting queries) | `review-diff`, written generically |
| A step of the workflow (when edge cases are settled, how the plan is cut, what the self-review fixes) | `ticket-to-pr` |
| A rule that holds in this repository only (a helper to call, a test to run when a kind of change happens, an export format) | the checklist `review.md`, citing the PR numbers it comes from |
| A convention already written in the repository and not applied | one line in the checklist pointing at the section, never a copy of it |
| An unsettled business rule | an edge case `ticket-to-pr` must raise at GATE 1, worded generically |

A pattern is a check missed on **at least two distinct PRs**, over the whole period; a single PR is kept only when it cost a lot (data leak, wrong amount). A miss the checklist or the skills already answer is not a new change: list it as covered, with the date its check arrived, and let the next retro judge it. Before proposing a checklist line, grep every symbol it names on the up-to-date base; a symbol that no longer exists is left out and named in the report, since a check pointing at a dead helper misleads every review after it.

For each pattern kept, propose one case for the cases file (format in step 5): the PR where the miss is the clearest and the smallest. Its base is `gh api repos/<owner>/<repo>/pulls/<n> --jq .base.sha`; its head is the `original_commit_id` of the reviewer's comment, the commit they actually read, never the PR's final head where the fix already landed.

This plugin is public. A change to `review-diff` or `ticket-to-pr` names no project, client, ticket key or PR number, and its examples are neutral. Everything project-specific goes in the checklist and the cases file, which live outside every repository.

## 4. Report and gate

Report, in this order: the rates that matter (size first when it dominates), the before/after verdict at the split date, then each proposed change with the misses it answers (PR numbers, counts). State the limits plainly: one reviewer writing most of the feedback skews the categories, a resolved thread without a reply says nothing about whether it was fixed, and the classification is a model's judgement on the text.

Without a split date there is no before/after verdict: say so in one line rather than comparing periods of unequal size.

**Gate.** Present the proposed changes as diffs and stop. Edit nothing before a go. On a go: the checklist is edited in place (created when absent) and its last line becomes `Last retro: <today>`, the new cases are appended to the cases file; the skills are edited on a branch of this plugin's repository, then step 5 runs, and they are committed and pushed only on a further go.

## 5. Replay the cases

A change to the review method is otherwise judged by the next retro only, weeks later. The cases file freezes real misses at the commit the reviewer read; replaying them says whether the change catches them, and whether it lost one an earlier version caught.

One block per case:

```
## <id>: <the miss in one line>
- PR: #<n>
- Base: <sha>
- Head: <sha>
- Scope: <paths>   (optional)
- Expected: <file>:<line>: <what the review has to say>
- Last: caught | missed | never run (<date>, plugin <version>)
```

`Scope` narrows the replayed diff of a large PR to the folders around the miss; the review still reads and greps the whole checkout, so twins and neighbours outside the scope stay in reach.

For each case, from the repository's clone: `git fetch origin <head>`, then a detached worktree in the scratchpad (`git worktree add --detach <scratchpad>/case-<id> <head>`). Then one **fresh** subagent per case, all in one message, not sonnet, following `review-diff` with: the diff `git diff <base>...<head> [-- <scope>]`, that worktree as the checkout, no stack, the checklist, and the PR body as the expected behaviour. It is never told the expected finding: a reviewer that knows what to look for proves nothing. Without a stack, its blockers and majors land under *Not confirmed — runtime out of reach*, which is enough here: the replay tests what the method looks at, not what runtime confirms.

A case is **caught** when one finding, at any severity or under the not-confirmed heading, names the expected file (or the twin it disagrees with) and the same defect. A finding on that file for another reason is a miss. Rewrite each `Last:` line, remove the worktrees, and report one row per case: previous result, result now. A case caught before and missed now is a **regression**: the change is not committed until the user has seen which case it lost and why.

Each case costs a full review, so the file stays small: three to eight cases, the oldest dropped once a newer case covers the same check.
