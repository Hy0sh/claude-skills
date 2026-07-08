#!/usr/bin/env bash
# PreToolUse hook: block raw `docker compose`/`docker-compose` lifecycle
# commands (up/down/restart/stop/start/kill), AND bare `docker <verb>`
# container-lifecycle commands (stop/start/restart/kill/rm/pause/unpause/
# update) wherever worktree-env.sh already applies -- inside a git worktree
# (isolated mode, always on) or in a principal repo with
# WT_SHARED_LANE_SERVICES configured (shared lane mode). The bare-docker
# case exists because an agent blocked on `docker compose up` can otherwise
# route around isolation via e.g. `docker update`/`docker restart` directly
# on the already-running container. Everywhere else (plain repo, no
# worktree, no lane config, or a verb outside the lifecycle set -- ps, logs,
# exec, inspect, build...) this hook is a no-op.
#
# This is a friction/nudge mechanism, not a sandbox: it pattern-matches the
# literal command text, so it cannot stop a determined agent going through
# the Docker API/socket directly, signals inside a container, etc. It closes
# the two obvious paths (compose, plain docker) cheaply.
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
# Quick filter: does the command contain `docker`/`docker-compose`/
# `docker compose` at all? Cheap substring scan -- no git call for the vast
# majority of Bash commands that have nothing to do with docker.
# ---------------------------------------------------------------------------
DOCKER_TAIL=$(printf '%s' "$CMD" | grep -oE 'docker(-compose)?[[:space:]]+.*' | head -1) || true

if [[ -z "$DOCKER_TAIL" ]]; then
  exit 0
fi

IS_COMPOSE=0
if [[ "$DOCKER_TAIL" == docker-compose* ]]; then
  IS_COMPOSE=1
  ARGS_STR="${DOCKER_TAIL#docker-compose}"
else
  ARGS_STR="${DOCKER_TAIL#docker}"
  read -r first_tok _ <<<"$ARGS_STR"
  if [[ "$first_tok" == "compose" ]]; then
    IS_COMPOSE=1
    ARGS_STR="${ARGS_STR#*compose}"
  fi
fi

VERB=""
if [[ "$IS_COMPOSE" -eq 1 ]]; then
  # compose's own global flags (-f/-p/...) precede the subcommand -- skip
  # them (and their value) to find the actual verb.
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
else
  # Plain `docker <subcommand> ...` -- the subcommand is always the first
  # positional word, no flags precede it in normal usage.
  read -r VERB _ <<<"$ARGS_STR"
  case "$VERB" in
    stop|start|restart|kill|rm|pause|unpause|update) : ;;
    *) exit 0 ;;
  esac
fi

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

if [[ "$IS_COMPOSE" -eq 1 ]]; then
  RAW_CMD_DESC="docker compose ${VERB}"
else
  RAW_CMD_DESC="docker ${VERB}"
fi

if [[ "$is_shared_lane" -eq 1 ]]; then
  cat >&2 <<EOF
BLOCKED: ${RAW_CMD_DESC} en direct est interdit ici — ce projet utilise la lane partagée de worktree-env.
Utilise à la place : ~/.claude/skills/worktree-env/worktree-env.sh claim [--mode test|interactive] / release
(ports fixes partagés / container partagé — une manipulation directe entre en collision avec le détenteur actuel de la lane.)
EOF
  exit 2
fi

cat >&2 <<EOF
BLOCKED: ${RAW_CMD_DESC} en direct est interdit dans un worktree git.
Utilise à la place : ~/.claude/skills/worktree-env/worktree-env.sh up|down|stop|clean
(isolation ports/volumes — une manipulation directe collisionne avec le stack principal ou les autres worktrees.)
EOF
exit 2
