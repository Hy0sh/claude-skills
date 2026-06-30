#!/usr/bin/env bash
# worktree-env.sh — Isolated Docker Compose environment per git worktree.
#
# Project-agnostic engine. The Compose topology (services, hardcoded
# container_names, published container ports) is auto-discovered from the
# project's base compose file; ports are remapped into a free 20-port block so
# stacks never collide. Project-specific behaviour (seeding, caches, special
# env vars, pretty access output) is supplied by optional hooks loaded from
# <principal-repo>/.claude/worktree-env.conf.sh — a project with no config file
# still works end-to-end with raw auto-mapping.
#
# Usage:
#   worktree-env.sh up [services...]   -- start the worktree stack
#   worktree-env.sh status             -- list active worktree stacks
#   worktree-env.sh down               -- compose teardown of current stack + volumes
#   worktree-env.sh clean              -- force-remove current worktree's containers +
#                                         volumes + ghosts from a failed up
#
# Pure functions (wt_alloc_block, wt_parse_compose_json, wt_render_override, …)
# are sourced by tests.sh without executing main.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — a project config may override these before they are used.
# ---------------------------------------------------------------------------
: "${WT_BASE_START:=20000}"   # first host port of block k=0
: "${WT_BLOCK_SIZE:=20}"      # ports per block (auto-bumped if more are discovered)
: "${WT_ENV_FILES:=}"         # files provisioned from principal into the worktree

# Discovery globals (populated by wt_discover; set directly in tests).
WT_DISC_SERVICES=()
WT_DISC_CNAME_SERVICES=()
WT_DISC_PORT_ENTRIES=()       # entries: "<service> <container_port>"
WT_RENDER_BLOCK_BASE=0        # block_base of the last render (for wt_host_port_for)

# ---------------------------------------------------------------------------
# Pure helper: given a block index k, return its block_base.
# ---------------------------------------------------------------------------
wt_block_base() {
  local k="$1"
  echo $(( WT_BASE_START + WT_BLOCK_SIZE * k ))
}

# ---------------------------------------------------------------------------
# Pure function: find the smallest free block index k.
#   $1 -- directory to scan for sibling .env.worktree files (WT_BLOCK=N lines)
#   $2 -- newline-separated list of block indices already in use (from docker)
# ---------------------------------------------------------------------------
wt_alloc_block() {
  local worktrees_dir="$1"
  local docker_blocks_input="$2"

  local -a taken=()

  if [[ -d "$worktrees_dir" ]]; then
    while IFS= read -r env_file; do
      local block
      block=$(grep -E '^WT_BLOCK=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]') || true
      if [[ -n "$block" && "$block" =~ ^[0-9]+$ ]]; then
        taken+=("$block")
      fi
    done < <(find "$worktrees_dir" -maxdepth 2 -name ".env.worktree" 2>/dev/null)
  fi

  if [[ -n "$docker_blocks_input" ]]; then
    while IFS= read -r bk; do
      bk=$(echo "$bk" | tr -d '[:space:]')
      if [[ -n "$bk" && "$bk" =~ ^[0-9]+$ ]]; then
        taken+=("$bk")
      fi
    done <<< "$docker_blocks_input"
  fi

  local k=0
  while true; do
    local free=1
    for t in "${taken[@]+"${taken[@]}"}"; do
      if [[ "$t" == "$k" ]]; then
        free=0
        break
      fi
    done
    if [[ "$free" == "1" ]]; then
      echo "$k"
      return 0
    fi
    (( k++ )) || true
  done
}

# ---------------------------------------------------------------------------
# Pure function: parse `docker compose config --format json` (read on stdin)
# into flat lines:
#   SVC <name>            -- every service, sorted
#   CNAME <name>          -- services with a hardcoded container_name
#   PORT <name> <target>  -- one per published port, using the CONTAINER port
# Deterministic ordering -> stable port-block indices -> predictable URLs.
# ---------------------------------------------------------------------------
wt_parse_compose_json() {
  # Code passed via -c so stdin stays the piped JSON (a heredoc would hijack it).
  python3 -c '
import sys, json
data = json.load(sys.stdin)
services = data.get("services", {})
for name in sorted(services):
    print(f"SVC {name}")
for name in sorted(services):
    if services[name].get("container_name"):
        print(f"CNAME {name}")
for name in sorted(services):
    for port in services[name].get("ports", []):
        target = port.get("target")
        if target is not None:
            print(f"PORT {name} {target}")
'
}

# ---------------------------------------------------------------------------
# Detect the base compose file (deliberately excludes the generated override).
# ---------------------------------------------------------------------------
wt_find_base_compose() {
  local dir="$1" name
  for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "${dir}/${name}" ]]; then
      echo "${dir}/${name}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Populate WT_DISC_* by parsing the BASE compose only, so a second 'up' does
# not feed remapped ports / re-derived container names back into discovery.
# ---------------------------------------------------------------------------
wt_discover() {
  local toplevel="$1" base json
  base=$(wt_find_base_compose "$toplevel") || {
    printf 'ERROR: no compose file found in %s\n' "$toplevel" >&2
    return 1
  }
  json=$(docker compose -f "$base" config --format json 2>/dev/null) || {
    printf 'ERROR: `docker compose -f %s config` failed (missing env_file? set WT_ENV_FILES)\n' "$base" >&2
    return 1
  }

  WT_DISC_SERVICES=(); WT_DISC_CNAME_SERVICES=(); WT_DISC_PORT_ENTRIES=()
  local line kind
  while IFS= read -r line; do
    kind="${line%% *}"
    case "$kind" in
      SVC)   WT_DISC_SERVICES+=("${line#SVC }") ;;
      CNAME) WT_DISC_CNAME_SERVICES+=("${line#CNAME }") ;;
      PORT)  WT_DISC_PORT_ENTRIES+=("${line#PORT }") ;;
    esac
  done < <(printf '%s' "$json" | wt_parse_compose_json)
}

# ---------------------------------------------------------------------------
# Host port assigned to a (service, container_port). For use inside hooks.
# The index is the global position of the entry in WT_DISC_PORT_ENTRIES; the
# host port is WT_RENDER_BLOCK_BASE + index (set by the last wt_render_override).
# bash 3.2 compatible (no associative arrays).
# ---------------------------------------------------------------------------
wt_host_port_for() {
  local svc="$1" cport="$2" i=0 entry e_svc e_cport
  for entry in "${WT_DISC_PORT_ENTRIES[@]+"${WT_DISC_PORT_ENTRIES[@]}"}"; do
    e_svc="${entry%% *}"; e_cport="${entry##* }"
    if [[ "$e_svc" == "$svc" && "$e_cport" == "$cport" ]]; then
      echo $(( WT_RENDER_BLOCK_BASE + i ))
      return 0
    fi
    (( i++ )) || true
  done
}

# Membership test for a plain array.
_wt_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Render compose.override.yaml from the discovered topology.
#   $1 -- COMPOSE_PROJECT_NAME    $2 -- block_base
# Re-derives every hardcoded container_name to ${COMPOSE_PROJECT_NAME}-<svc>,
# remaps every published container port into the block (index = position in
# WT_DISC_PORT_ENTRIES). Per-service extras and top-level volumes come from
# optional project hooks. Populates WT_PORT_ASSIGN for wt_host_port_for.
# ---------------------------------------------------------------------------
wt_render_override() {
  local project_name="$1" block_base="$2"
  local entry svc cport

  # Record the block_base so wt_host_port_for resolves ports for this render.
  WT_RENDER_BLOCK_BASE="$block_base"

  printf '%s\n' \
    "# Auto-generated by worktree-env.sh -- do not edit manually." \
    "# Regenerated on each 'up'. Gitignored (.git/info/exclude)." \
    "services:"

  # Pass 2: emit one section per discovered service, omitting empty ones.
  local body
  for svc in "${WT_DISC_SERVICES[@]+"${WT_DISC_SERVICES[@]}"}"; do
    body=""

    if _wt_in_list "$svc" "${WT_DISC_CNAME_SERVICES[@]+"${WT_DISC_CNAME_SERVICES[@]}"}"; then
      body+="    container_name: \${COMPOSE_PROJECT_NAME}-${svc}"$'\n'
    fi

    local -a svc_ports=()
    for entry in "${WT_DISC_PORT_ENTRIES[@]+"${WT_DISC_PORT_ENTRIES[@]}"}"; do
      if [[ "${entry%% *}" == "$svc" ]]; then
        cport="${entry##* }"
        svc_ports+=("      - \"$(wt_host_port_for "$svc" "$cport"):${cport}\"")
      fi
    done
    if [[ "${#svc_ports[@]}" -gt 0 ]]; then
      # !override: Compose CONCATENATES ports across files; without the tag the
      # base host ports stay published and collide.
      body+="    ports: !override"$'\n'
      local p
      for p in "${svc_ports[@]}"; do body+="${p}"$'\n'; done
    fi

    if declare -F wt_project_service_extra >/dev/null; then
      local extra; extra=$(wt_project_service_extra "$svc" "$block_base")
      [[ -n "$extra" ]] && body+="${extra}"$'\n'
    fi

    if [[ -n "$body" ]]; then
      printf '  %s:\n%s\n' "$svc" "$body"
    fi
  done

  # Top-level volumes from the project hook (if any).
  if declare -F wt_project_volumes >/dev/null; then
    local vols; vols=$(wt_project_volumes)
    if [[ -n "$vols" ]]; then
      printf 'volumes:\n%s\n' "$vols"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Parse active docker block indices from running <prefix>-* containers.
# Derives k from any published host port in the engine's range.
# ---------------------------------------------------------------------------
wt_docker_active_blocks() {
  local blocks="" line port k
  command -v docker &>/dev/null || { echo ""; return 0; }
  while IFS= read -r line; do
    while read -r port; do
      if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= WT_BASE_START )); then
        k=$(( (port - WT_BASE_START) / WT_BLOCK_SIZE ))
        blocks+="${k}"$'\n'
      fi
    done < <(echo "$line" | grep -oE '0\.0\.0\.0:[0-9]+' | grep -oE '[0-9]+$')
  done < <(docker ps --filter "name=${WT_PROJECT_PREFIX}-" --format "{{.Ports}}" 2>/dev/null)
  echo "$blocks"
}

# ---------------------------------------------------------------------------
# Write .env.worktree in the given toplevel directory.
# ---------------------------------------------------------------------------
wt_write_env_file() {
  local dir="$1" project_name="$2" k="$3"
  {
    printf '# Auto-generated by worktree-env.sh -- do not edit manually.\n'
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$project_name"
    printf 'WT_BLOCK=%s\n' "$k"
  } > "${dir}/.env.worktree"
}

# ---------------------------------------------------------------------------
# Source the project config (host-side bash) from the principal repo. Absent =
# zero-config mode (raw auto-mapping, no seed/caches).
# ---------------------------------------------------------------------------
wt_load_project_config() {
  local principal_root="$1"
  local conf="${principal_root}/.claude/worktree-env.conf.sh"
  if [[ -f "$conf" ]]; then
    # shellcheck source=/dev/null
    source "$conf"
    printf 'Loaded project config: %s\n' "$conf" >&2
  fi
}

# ---------------------------------------------------------------------------
# Provision each WT_ENV_FILES entry from the principal repo into the worktree
# (worktrees do not carry gitignored files). Idempotent.
# ---------------------------------------------------------------------------
wt_provision_env_files() {
  local toplevel="$1" principal_root="$2" rel
  for rel in ${WT_ENV_FILES[@]+"${WT_ENV_FILES[@]}"}; do
    [[ -f "${toplevel}/${rel}" ]] && continue
    if [[ -f "${principal_root}/${rel}" ]]; then
      mkdir -p "$(dirname "${toplevel}/${rel}")"
      cp "${principal_root}/${rel}" "${toplevel}/${rel}"
      printf 'Provisioned %s from principal repo\n' "$rel" >&2
    else
      printf 'ERROR: %s missing in both worktree and principal repo (%s).\n' "$rel" "$principal_root" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Resolve worktree toplevel + principal root, load config, set the project
# prefix. Sets WT_TOPLEVEL, WT_PRINCIPAL_ROOT, WT_REPO_BASENAME, WT_PROJECT_PREFIX.
# ---------------------------------------------------------------------------
wt_resolve_context() {
  local git_common_dir
  # Resolve from the CWD (the worktree the user runs from), never from
  # SCRIPT_DIR: the skill itself may live in its own git repo, which would
  # otherwise be mistaken for the worktree.
  WT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
      printf 'ERROR: not inside a git repository (run from inside the worktree)\n' >&2
      return 1
    }

  git_common_dir=$(git -C "$WT_TOPLEVEL" rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$git_common_dir" && "$git_common_dir" != ".git" ]]; then
    WT_PRINCIPAL_ROOT=$(dirname "$git_common_dir")
  else
    WT_PRINCIPAL_ROOT="$WT_TOPLEVEL"
  fi
  WT_REPO_BASENAME=$(basename "$WT_PRINCIPAL_ROOT")

  wt_load_project_config "$WT_PRINCIPAL_ROOT"
  : "${WT_PROJECT_PREFIX:=${WT_REPO_BASENAME}-wt}"
}

# ---------------------------------------------------------------------------
# Ensure .env.worktree + compose.override.yaml exist and are current.
# ---------------------------------------------------------------------------
wt_ensure_env() {
  local slug project_name k block_base worktrees_dir docker_blocks nports

  wt_resolve_context || return 1

  # Provision env files BEFORE discovery (compose config may need env_file).
  wt_provision_env_files "$WT_TOPLEVEL" "$WT_PRINCIPAL_ROOT" || return 1

  # Discover topology and size the block to fit all ports.
  wt_discover "$WT_TOPLEVEL" || return 1
  nports="${#WT_DISC_PORT_ENTRIES[@]}"
  if (( nports > WT_BLOCK_SIZE )); then
    WT_BLOCK_SIZE=$(( (nports + 9) / 10 * 10 ))
  fi

  if [[ -f "${WT_TOPLEVEL}/.env.worktree" ]]; then
    # shellcheck source=/dev/null
    source "${WT_TOPLEVEL}/.env.worktree"
    if [[ -z "${COMPOSE_PROJECT_NAME:-}" || -z "${WT_BLOCK:-}" ]]; then
      printf 'WARNING: .env.worktree incomplete, reinitializing...\n' >&2
      rm -f "${WT_TOPLEVEL}/.env.worktree"
    fi
  fi

  if [[ ! -f "${WT_TOPLEVEL}/.env.worktree" ]]; then
    slug=$(basename "$WT_TOPLEVEL")
    project_name="${WT_PROJECT_PREFIX}-${slug}"
    worktrees_dir="${WT_PRINCIPAL_ROOT}/.claude/worktrees"
    docker_blocks=$(wt_docker_active_blocks)
    k=$(wt_alloc_block "$worktrees_dir" "$docker_blocks")
    wt_write_env_file "$WT_TOPLEVEL" "$project_name" "$k"
    printf 'Allocated block k=%s for project %s\n' "$k" "$project_name" >&2
  else
    k="${WT_BLOCK}"
    project_name="${COMPOSE_PROJECT_NAME}"
  fi

  block_base=$(wt_block_base "$k")
  wt_render_override "$project_name" "$block_base" > "${WT_TOPLEVEL}/compose.override.yaml"

  export WT_TOPLEVEL WT_PROJECT_NAME="$project_name"
  export WT_BLOCK="$k" WT_BLOCK_BASE="$block_base"
}

# ---------------------------------------------------------------------------
# docker compose invocation scoped to the current worktree project.
# ---------------------------------------------------------------------------
wt_compose() {
  docker compose \
    --project-directory "$WT_TOPLEVEL" \
    --env-file "${WT_TOPLEVEL}/.env.worktree" \
    "$@"
}

# ---------------------------------------------------------------------------
# Print resolved access info. Delegates to the project hook when present,
# otherwise prints a raw URL list from the discovered topology.
# ---------------------------------------------------------------------------
wt_print_access() {
  local bbase="$1"
  if declare -F wt_project_print_access >/dev/null; then
    wt_project_print_access "$bbase"
    return
  fi
  printf '\n=== Accès (auto-mappé) ===\n'
  local entry svc cport
  for entry in "${WT_DISC_PORT_ENTRIES[@]+"${WT_DISC_PORT_ENTRIES[@]}"}"; do
    svc="${entry%% *}"; cport="${entry##* }"
    printf '  %-16s http://localhost:%s  (conteneur %s)\n' "$svc" "$(wt_host_port_for "$svc" "$cport")" "$cport"
  done
  printf '\n'
}

# ---------------------------------------------------------------------------
# Subcommand: up
# ---------------------------------------------------------------------------
cmd_up() {
  local services=("$@")

  wt_ensure_env

  if [[ "${#services[@]}" -eq 0 ]]; then
    if [[ -n "${WT_DEFAULT_SERVICES:-}" ]]; then
      services=("${WT_DEFAULT_SERVICES[@]}")
    else
      services=("${WT_DISC_SERVICES[@]}")
    fi
  fi

  printf 'Starting stack: project=%s, block_base=%s\n' "$WT_PROJECT_NAME" "$WT_BLOCK_BASE" >&2
  printf 'Services: %s\n' "${services[*]}" >&2

  wt_compose up -d "${services[@]}"

  if declare -F wt_project_post_up >/dev/null; then
    wt_project_post_up "$WT_BLOCK_BASE" || printf 'WARNING: post_up hook failed — see messages above.\n' >&2
  fi

  wt_print_access "$WT_BLOCK_BASE"
}

# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------
cmd_status() {
  wt_resolve_context || return 1

  printf 'Stacks worktree actifs (%s-*):\n\n' "$WT_PROJECT_PREFIX"
  local found=0 name
  while IFS= read -r name; do
    [[ "$name" == ${WT_PROJECT_PREFIX}-* ]] || continue
    found=1
    printf '  Projet : %s\n' "$name"
    docker ps --filter "label=com.docker.compose.project=${name}" \
      --format '    {{.Names}}  {{.Ports}}' 2>/dev/null
    printf '\n'
  done < <(docker compose ls --all --format '{{.Name}}' 2>/dev/null)

  [[ "$found" -eq 0 ]] && printf '  (aucun)\n'
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand: down
# ---------------------------------------------------------------------------
cmd_down() {
  wt_resolve_context || return 1

  if [[ ! -f "${WT_TOPLEVEL}/.env.worktree" ]]; then
    printf 'No .env.worktree in %s — nothing to bring down.\n' "$WT_TOPLEVEL" >&2
    return 0
  fi

  printf 'Stopping and removing stack (volumes included)\n' >&2
  docker compose \
    --project-directory "$WT_TOPLEVEL" \
    --env-file "${WT_TOPLEVEL}/.env.worktree" \
    down -v
}

# ---------------------------------------------------------------------------
# Subcommand: clean — scoped to the CURRENT worktree only (never other
# worktrees or shared infra, per workflow-rules §10).
# ---------------------------------------------------------------------------
cmd_clean() {
  wt_resolve_context || return 1

  local slug project_name
  slug=$(basename "$WT_TOPLEVEL")
  project_name="${WT_PROJECT_PREFIX}-${slug}"

  printf 'Cleaning worktree stack %s (containers + volumes + ghosts)...\n' "$project_name" >&2

  docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null \
    | xargs -r docker rm -f 2>/dev/null || true

  # Per-worktree volumes carry the project-name prefix; shared fixed-name caches
  # (no project prefix) are NOT matched, so they survive.
  docker volume ls -q --filter "name=${project_name}_" 2>/dev/null \
    | xargs -r docker volume rm -f 2>/dev/null || true

  docker network ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null \
    | xargs -r docker network rm 2>/dev/null || true

  printf 'Done.\n' >&2
}

# ---------------------------------------------------------------------------
# Main dispatcher -- only runs when the script is executed directly.
# ---------------------------------------------------------------------------
main() {
  if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <up [services...]|status|down|clean>\n' "$(basename "$0")" >&2
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    up)     cmd_up "$@" ;;
    status) cmd_status ;;
    down)   cmd_down ;;
    clean)  cmd_clean ;;
    *)
      printf 'Unknown command: %s\n' "$cmd" >&2
      printf 'Usage: %s <up [services...]|status|down|clean>\n' "$(basename "$0")" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Entry point guard -- allows 'source'-ing the file for tests.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
