Prompt given to each classification subagent, with `<chunk>` and `<out>` replaced. Read-only: the agent reads one JSON file and writes one JSONL file.

---

You classify code-review remarks a developer received on their pull requests. Touch no repository file, call nothing else.

Input: `<chunk>`, a JSON array. Each item: `id`, `pr`, `title`, `pr_size` (added + deleted lines), `by` (reviewer), `kind` (thread = inline comment, comment = conversation, review = review summary), `path`, `resolved`, `body`, `replies` (often from the author: they say whether it was fixed or disputed).

Output: `<out>`, one JSON line per item, every item, with exactly these keys:

- `id`: copied
- `category`: one of `bug_edge_case` (wrong logic, computation, edge case, regression), `scope_permission` (tenant / perimeter / role scope, permissions, route guard, data leak), `data_integrity` (uniqueness, data migration, constraint, field editable when it should not be), `robustness` (exceptions, transactions, ordering, idempotence, partial failure), `ux_message_i18n` (labels, error messages, translations, display), `duplication_reuse` (already exists elsewhere, consistency with existing code), `front_back_split` (rule enforced on one side only), `business_question` (unsettled business rule, question for the product owner), `cleanup_readability`, `tests` (missing, broken, or freezing wrong behaviour), `performance` (queries, N+1), `conventions` (team convention, file layout, imposed style), `noise` (LGTM, thanks, summary with no request), `other`
- `nature`: `defect` (wrong today) | `risk` (breaks in a plausible case) | `improvement` | `question` | `nit` | `noise`
- `outcome`: `fixed` | `pushed_back` | `answered` | `unknown`. Only from an explicit reply; a resolved thread without a reply is `unknown`
- `catchable`: `self_review` (a careful read of the diff and of the code around it would have found it) | `needs_runtime` (only visible by running the app) | `needs_business` (needs business knowledge or a product decision) | `tacit_convention` (a team preference) | `na`
- `written_down`: true when the remark cites or applies a rule already written in the repository (a conventions file, a section number, a sister PR), else false
- `missed_check`: one short sentence, in the user's language: the precise check that would have caught it before review (e.g. "check that every endpoint of the list applies the tenant filter"). Empty for noise
- `pattern`: a short label for a recurring pattern (e.g. "tenant filter ignored", "double count", "route guard without the permission"), reused verbatim across items. Empty otherwise

Judge on the text: a remark phrased as a question that points at a real defect is a `defect` or a `risk`, not a `question`. At the end, check the file: every line parses, line count = item count. Answer in 10 lines at most: items written, the 5 most frequent patterns with counts, notable uncertainties.
