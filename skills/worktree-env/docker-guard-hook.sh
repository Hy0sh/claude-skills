#!/usr/bin/env bash
# PreToolUse hook: block raw `docker compose`/`docker-compose` lifecycle
# commands (up/down/restart/stop/start/kill) wherever worktree-env.sh already
# applies -- inside a git worktree (isolated mode, always on) or in a
# principal repo with WT_SHARED_LANE_SERVICES configured (shared lane mode).
# Everywhere else (plain repo, no worktree, no lane config, or a compose
# verb outside the lifecycle set) this hook is a no-op.
#
# Fails OPEN on any internal error (missing jq, not a git repo, no compose
# file at the resolved toplevel) -- a hook bug must never block every Bash
# command.
#
# Exit codes: 0 = allow, 2 = block (reason on stderr).

set -uo pipefail

if ! command -v jq &>/dev/null; then
  echo "[docker-guard] WARNING: jq not installed, cannot inspect command — allowing." >&2
  exit 0
fi

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z "$CMD" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Quick filter: does the command contain `docker compose`/`docker-compose`
# followed (after any value-taking flags) by a lifecycle verb? Cheap
# substring/word scan -- no git call for the vast majority of Bash commands
# that have nothing to do with docker.
# ---------------------------------------------------------------------------
COMPOSE_TAIL=$(printf '%s' "$CMD" | grep -oE 'docker(-compose|[[:space:]]+compose)[[:space:]]+.*' | head -1) || true

if [[ -z "$COMPOSE_TAIL" ]]; then
  exit 0
fi

ARGS_STR=$(printf '%s' "$COMPOSE_TAIL" | sed -E 's/^docker(-compose|[[:space:]]+compose)[[:space:]]+//')

VERB=""
skip_next=0
for tok in $ARGS_STR; do
  if [[ "$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi
  case "$tok" in
    -f|--file|-p|--project-name|--project-directory|--env-file|--profile)
      skip_next=1
      continue
      ;;
    -*)
      continue
      ;;
    *)
      VERB="$tok"
      break
      ;;
  esac
done

case "$VERB" in
  up|down|restart|stop|start|kill) : ;;
  *) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Resolve context by reusing worktree-env.sh's own logic (single source of
# truth with the CLI -- see wt_resolve_context). Sourcing is safe: the
# BASH_SOURCE guard at the bottom of worktree-env.sh prevents main() from
# running (same pattern already used by tests.sh).
# ---------------------------------------------------------------------------
SCRIPT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./worktree-env.sh
source "${SCRIPT_DIR_SELF}/worktree-env.sh"

wt_resolve_context || exit 0

is_worktree=0
if [[ "$WT_TOPLEVEL" != "$WT_PRINCIPAL_ROOT" ]]; then
  is_worktree=1
fi

is_shared_lane=0
if [[ -n "${WT_SHARED_LANE_SERVICES+x}" ]]; then
  is_shared_lane=1
fi

if [[ "$is_worktree" -eq 0 && "$is_shared_lane" -eq 0 ]]; then
  exit 0
fi

wt_find_base_compose "$WT_TOPLEVEL" >/dev/null 2>&1 || exit 0

if [[ "$is_shared_lane" -eq 1 ]]; then
  cat >&2 <<EOF
BLOCKED: docker compose ${VERB} en direct est interdit ici — ce projet utilise la lane partagée de worktree-env.
Utilise à la place : ~/.claude/skills/worktree-env/worktree-env.sh claim [--mode test|interactive] / release
(ports fixes partagés — un docker compose direct entre en collision avec le détenteur actuel de la lane.)
EOF
  exit 2
fi

cat >&2 <<EOF
BLOCKED: docker compose ${VERB} en direct est interdit dans un worktree git.
Utilise à la place : ~/.claude/skills/worktree-env/worktree-env.sh up|down|stop|clean
(isolation ports/volumes — un docker compose direct collisionne avec le stack principal ou les autres worktrees.)
EOF
exit 2
