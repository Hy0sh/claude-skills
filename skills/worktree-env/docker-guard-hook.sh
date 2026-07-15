#!/usr/bin/env bash
# Garde minimal : bloque `docker compose up|down` nu quand l'infra wtenv est active.
# Fail-open systématique (jamais bloquer tout Bash sur un imprévu).
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -z "$cmd" ] && exit 0

# Gate substring rapide
case "$cmd" in *"docker compose"*|*"docker-compose"*) : ;; *) exit 0 ;; esac
# Verbe up|down (tolère les flags globaux avant le verbe)
echo "$cmd" | grep -Eq 'docker(-| +)compose( +--?[^ ]+( +[^ ]+)?)* +(up|down)\b' || exit 0

# Contexte git + repo principal
top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -z "$top" ] && exit 0
common="$(git rev-parse --git-common-dir 2>/dev/null)"; [ -z "$common" ] && exit 0
case "$common" in /*) : ;; *) common="$top/$common" ;; esac
repo="$(basename "$(cd "$(dirname "$common")" && pwd)")"

# L'infra wtenv est-elle active ?
docker network inspect "wtenv-${repo}" >/dev/null 2>&1 || exit 0

echo "🚫 Infra wtenv active : n'utilise pas 'docker compose up|down' nu (collision de ports avec l'infra partagée). Passe par : worktree-env preview / worktree-env test / worktree-env infra." >&2
exit 2
