---
name: notify-pr-slack
description: Use when the user asks to announce a pull request on Slack to get it reviewed — "demande de review", "poste la PR sur Slack", "annonce ma PR", "review please" — for the current branch or for a pull request given by number or URL.
---

# Announce a pull request on Slack

One line in the project channel, nothing else:

```
[PR] fix(booking): date the occurrences on order slip lines #ABC-123
```

Only `PR` is a link, the brackets are plain text. Posting through the API is what keeps the GitHub preview away, so nothing has to be deleted afterwards.

Chat with the user in their language; this skill file stays in English.

## Steps

**1. Resolve the pull request.** A number or URL in the request wins; otherwise the current branch.

```bash
gh pr view --json title,url --jq '[.title, .url] | @tsv'   # add the number as an argument to target another PR
```

No open pull request on the branch: say so and stop.

**2. Resolve the channel.** `gh repo view --json nameWithOwner --jq .nameWithOwner`, then read `~/.config/hy0sh-skills/repos/<owner>/<repo>/slack.json`. It lives in the user's per-repository folder, outside the plugin, because channel ids are the user's own data and a plugin update would overwrite anything kept next to this file:

```json
{ "channel_id": "C0123456789", "name": "#some-channel", "connect": true }
```

File absent: find the channel with `slack_search_channels`, have the user confirm it, then write the file (creating the folder if needed) so the next call is silent.

**3. Post** with `slack_send_message`:

| Argument | Value |
|---|---|
| `channel_id` | the id from `slack.json` |
| `message` | `[[PR](<url>)] <title>`, plus any suffix the user asked for (a series marker such as `2/5` goes after the title) |
| `unfurl_app_links` | leave it out |

Post directly, without asking for a go: that is the point of the skill.

**Slack Connect channels refuse the send**, with
`mcp_externally_shared_channel_restricted`. It is a platform rule, not a
transient failure, so retrying and rewording change nothing: fall straight to
`slack_send_message_draft`, same `channel_id`, same message, and tell the user
the draft is waiting in the channel for one click. A `slack.json` marked
`"connect": true` goes to the draft directly; the first refusal on an unmarked
one adds the mark.

**4. Report** the permalink the tool returns, or the channel link for a draft.

## Traps

- The title is copied **verbatim** from GitHub. No reformatting, no translation, no ticket reference added by hand: the pull request title already carries its ticket key.
- `unfurl_app_links: true` brings back the very preview the user used to delete manually. Never set it.
- `slack_send_message` is refused by the auto mode classifier, so an approval prompt is expected. Wait for it. Never fall back to the clipboard or to another channel — the draft above is the only sanctioned fallback, and only for a Slack Connect channel.
- The connector may be installed but unauthenticated, in which case only its `authenticate` tool shows up and it just tells you to run `/mcp`. Say so and stop; there is nothing to work around.
- The outer brackets are literal text around a markdown link. Keep them outside the `[...](...)`.
