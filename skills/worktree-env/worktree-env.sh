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
#   worktree-env.sh stop                -- stop the current stack, keep volumes (DB, caches)
#   worktree-env.sh down               -- compose teardown of current stack + volumes
#   worktree-env.sh clean              -- force-remove current worktree's containers +
#                                         volumes + ghosts from a failed up
#
# Shared lane mode (additive, opt-in via WT_SHARED_LANE_SERVICES -- see
# worktree-env.conf.example.sh): one lane of containers shared across all
# worktrees of a repo, arbitrated by queue_daemon.py.
#   worktree-env.sh claim [--mode test|interactive] [-- <command...>]
#                                       -- block until the lane is granted, bring it up
#   worktree-env.sh release            -- explicit teardown of a held lane
#   worktree-env.sh queue up|down      -- start/stop the queue daemon (once per machine)
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

# Shared lane mode defaults (see queue_daemon.py + `claim`/`release`/`queue`).
# WT_SHARED_INFRA_SERVICES / WT_SHARED_LANE_SERVICES have no default: unset
# means the project has not opted into shared lane mode.
: "${WT_SHARED_IDLE_TIMEOUT:=2700}"        # seconds without heartbeat before auto-release (interactive)
: "${WT_SHARED_HEARTBEAT_INTERVAL:=60}"    # seconds between heartbeats while a claim is held (interactive)
: "${WT_QUEUE_PORT:=8765}"                 # fixed local port of queue_daemon.py

# Discovery globals (populated by wt_discover; set directly in tests).
WT_DISC_SERVICES=()
WT_DISC_CNAME_SERVICES=()
WT_DISC_PORT_ENTRIES=()       # entries: "<service> <container_port>"
WT_DISC_VOLBIND_ENTRIES=()    # entries: "<service> <bind source> <container target>"
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
#   SVC <name>                     -- every service, sorted
#   CNAME <name>                   -- services with a hardcoded container_name
#   PORT <name> <target>           -- one per published port, using the CONTAINER port
#   VOLBIND <name> <source> <target> -- one per bind-mount volume (skips named volumes)
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
for name in sorted(services):
    for vol in services[name].get("volumes", []):
        if vol.get("type") == "bind" and vol.get("source") and vol.get("target"):
            print("VOLBIND {} {} {}".format(name, vol["source"], vol["target"]))
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

  WT_DISC_SERVICES=(); WT_DISC_CNAME_SERVICES=(); WT_DISC_PORT_ENTRIES=(); WT_DISC_VOLBIND_ENTRIES=()
  local line kind
  while IFS= read -r line; do
    kind="${line%% *}"
    case "$kind" in
      SVC)     WT_DISC_SERVICES+=("${line#SVC }") ;;
      CNAME)   WT_DISC_CNAME_SERVICES+=("${line#CNAME }") ;;
      PORT)    WT_DISC_PORT_ENTRIES+=("${line#PORT }") ;;
      VOLBIND) WT_DISC_VOLBIND_ENTRIES+=("${line#VOLBIND }") ;;
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
# Convert "KEY=VALUE" lines (one per line, from wt_project_shared_lane_env)
# into an indented YAML mapping under a service's `environment:` key.
# ---------------------------------------------------------------------------
_wt_env_lines_to_yaml() {
  local line key val
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    printf '      %s: "%s"\n' "$key" "$val"
  done
}

# ---------------------------------------------------------------------------
# Shared lane mode -- render compose.override.lane.yaml: for each lane service
# (WT_SHARED_LANE_SERVICES), rewrite its bind-mount volumes to point at the
# CURRENT HOLDER worktree's absolute path instead of the base compose's path,
# and (via the optional wt_project_shared_lane_env hook) inject the per-
# worktree env vars (DB name, bucket name, ...) actually needed for the
# isolation to apply to the running containers -- without this, every
# worktree's containers keep reading the base compose's fixed DB_NAME/bucket.
# No port remap: shared lane mode uses one fixed set of ports, ever.
#   $1    -- absolute path of the current holder worktree
#   $2    -- per-worktree logical DB name (passed through to the hook)
#   $3    -- per-worktree logical bucket name (passed through to the hook)
#   $4... -- lane service names (WT_SHARED_LANE_SERVICES)
# Reads WT_DISC_SERVICES / WT_DISC_VOLBIND_ENTRIES (populated by wt_discover).
# ---------------------------------------------------------------------------
wt_render_shared_override() {
  local holder_path="$1" db_name="$2" bucket_name="$3"; shift 3
  local -a lane_services=("$@")
  local svc entry e_svc rest e_src e_target rel body env_lines

  printf '%s\n' \
    "# Auto-generated by worktree-env.sh -- do not edit manually." \
    "# Regenerated on each 'claim'. Gitignored (.git/info/exclude)." \
    "services:"

  for svc in "${lane_services[@]+"${lane_services[@]}"}"; do
    _wt_in_list "$svc" "${WT_DISC_SERVICES[@]+"${WT_DISC_SERVICES[@]}"}" || continue
    body=""
    for entry in "${WT_DISC_VOLBIND_ENTRIES[@]+"${WT_DISC_VOLBIND_ENTRIES[@]}"}"; do
      e_svc="${entry%% *}"
      [[ "$e_svc" == "$svc" ]] || continue
      rest="${entry#* }"
      e_src="${rest%% *}"
      e_target="${rest#* }"
      rel="${e_src#./}"
      body+="      - \"${holder_path}/${rel}:${e_target}\""$'\n'
    done
    if [[ -n "$body" ]]; then
      body="    volumes: !override"$'\n'"${body}"
    fi

    if declare -F wt_project_shared_lane_env >/dev/null; then
      env_lines=$(wt_project_shared_lane_env "$svc" "$db_name" "$bucket_name")
      if [[ -n "$env_lines" ]]; then
        body+="    environment:"$'\n'"$(printf '%s\n' "$env_lines" | _wt_env_lines_to_yaml)"$'\n'
      fi
    fi

    if [[ -n "$body" ]]; then
      printf '  %s:\n%s\n' "$svc" "$body"
    fi
  done
}

# ---------------------------------------------------------------------------
# Shared lane mode -- DB/bucket naming convention for a worktree slug. Default
# `${WT_PROJECT_PREFIX}_<slug>`, overridable via the project hook
# `wt_project_shared_resource_name <kind> <slug>` (kind: "db" or "bucket").
# ---------------------------------------------------------------------------
wt_shared_resource_name() {
  local kind="$1" slug="$2"
  if declare -F wt_project_shared_resource_name >/dev/null; then
    wt_project_shared_resource_name "$kind" "$slug"
  else
    printf '%s_%s' "$WT_PROJECT_PREFIX" "$slug"
  fi
}

# ---------------------------------------------------------------------------
# Shared lane mode -- write .env.worktree-lane in the principal repo (the
# lane's compose project is not tied to any single worktree, unlike
# .env.worktree which is per-worktree).
# ---------------------------------------------------------------------------
wt_write_lane_env_file() {
  local dir="$1" project_name="$2"
  {
    printf '# Auto-generated by worktree-env.sh -- do not edit manually.\n'
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$project_name"
  } > "${dir}/.env.worktree-lane"
}

# ---------------------------------------------------------------------------
# Shared lane mode -- docker compose invocation scoped to the fixed lane
# project (rooted at the PRINCIPAL repo, not the calling worktree).
# ---------------------------------------------------------------------------
wt_compose_lane() {
  local base
  base=$(wt_find_base_compose "$WT_PRINCIPAL_ROOT") || return 1
  docker compose \
    -f "$base" \
    -f "${WT_PRINCIPAL_ROOT}/compose.override.lane.yaml" \
    --project-directory "$WT_PRINCIPAL_ROOT" \
    --env-file "${WT_PRINCIPAL_ROOT}/.env.worktree-lane" \
    "$@"
}

# ---------------------------------------------------------------------------
# Shared lane mode -- wait until each infra service is reported "running" by
# compose. The _ensure hooks that follow `exec` into db/rustfs, which fails
# outright on the very first `claim` on a machine (infra never started
# before): `up -d` returning doesn't guarantee the container has finished
# starting. Generic (compose state only, ~10s max) -- a service slow to
# accept connections after "running" is a project concern, handled in its
# own hook, same pattern as wt_project_post_up.
#   $@ -- infra service names (WT_SHARED_INFRA_SERVICES)
# ---------------------------------------------------------------------------
wt_wait_shared_infra_ready() {
  local -a services=("$@")
  [[ "${#services[@]}" -eq 0 ]] && return 0

  local attempt running svc all_up
  for (( attempt = 1; attempt <= 20; attempt++ )); do
    running=$(wt_compose_lane ps --status running --services 2>/dev/null || true)
    all_up=1
    for svc in "${services[@]}"; do
      _wt_in_list "$svc" $running || { all_up=0; break; }
    done
    [[ "$all_up" -eq 1 ]] && return 0
    sleep 0.5
  done
  printf 'WARNING: shared infra services not confirmed running after wait -- continuing anyway.\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Shared lane mode -- thin HTTP client for queue_daemon.py. All calls fail
# (non-zero) if the daemon is unreachable or returns a non-2xx status.
# ---------------------------------------------------------------------------
wt_queue_url() {
  printf 'http://127.0.0.1:%s' "${WT_QUEUE_PORT}"
}

# Blocks until the lane is granted to (repo, worktree). No client-side
# timeout by design: this call waits as long as it takes to reach the front
# of the FIFO queue.
wt_queue_claim() {
  local repo="$1" worktree="$2" mode="$3" idle_timeout="$4" payload
  payload=$(python3 -c '
import json, sys
print(json.dumps({"repo": sys.argv[1], "worktree": sys.argv[2], "mode": sys.argv[3], "idle_timeout": int(sys.argv[4])}))
' "$repo" "$worktree" "$mode" "$idle_timeout")
  curl -sS -f -X POST -H 'Content-Type: application/json' -d "$payload" "$(wt_queue_url)/claim" >/dev/null
}

wt_queue_heartbeat() {
  local repo="$1" worktree="$2" payload
  payload=$(python3 -c 'import json, sys; print(json.dumps({"repo": sys.argv[1], "worktree": sys.argv[2]}))' "$repo" "$worktree")
  curl -sS -f -m 5 -X POST -H 'Content-Type: application/json' -d "$payload" "$(wt_queue_url)/heartbeat" >/dev/null
}

wt_queue_release() {
  local repo="$1" worktree="$2" payload
  payload=$(python3 -c 'import json, sys; print(json.dumps({"repo": sys.argv[1], "worktree": sys.argv[2]}))' "$repo" "$worktree")
  curl -sS -f -m 5 -X POST -H 'Content-Type: application/json' -d "$payload" "$(wt_queue_url)/release" >/dev/null
}

wt_queue_status_json() {
  local repo="$1" encoded
  encoded=$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))' "$repo")
  curl -sS -f -m 5 "$(wt_queue_url)/status?repo=${encoded}"
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

  if [[ -n "${WT_SHARED_LANE_SERVICES+x}" ]]; then
    printf '\nLane partagée (%s):\n' "$WT_REPO_BASENAME"
    wt_print_queue_status "$WT_REPO_BASENAME"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Shared lane mode -- print the daemon's holder + queue for a repo. Used by
# `status`. Degrades gracefully (does not fail `status`) if the daemon is down.
# ---------------------------------------------------------------------------
wt_print_queue_status() {
  local repo="$1" json
  json=$(wt_queue_status_json "$repo") || {
    printf '  (daemon de file injoignable -- "queue up" ?)\n'
    return 0
  }
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
holder = d.get("holder")
if holder:
    print(f"  Détenteur : {holder[\"worktree\"]} (mode={holder[\"mode\"]})")
else:
    print("  Détenteur : (aucun)")
q = d.get("queue", [])
print("  File      : " + (", ".join(x["worktree"] for x in q) if q else "(vide)"))
'
}

# ---------------------------------------------------------------------------
# Subcommand: stop — stop containers but keep volumes (DB, caches). Use this
# instead of `down` when pausing a worktree you intend to resume: `down -v`
# destroys postgres_data, forcing a full migration replay on the next `up`.
# ---------------------------------------------------------------------------
cmd_stop() {
  wt_resolve_context || return 1

  if [[ ! -f "${WT_TOPLEVEL}/.env.worktree" ]]; then
    printf 'No .env.worktree in %s — nothing to stop.\n' "$WT_TOPLEVEL" >&2
    return 0
  fi

  printf 'Stopping stack (volumes preserved)\n' >&2
  docker compose \
    --project-directory "$WT_TOPLEVEL" \
    --env-file "${WT_TOPLEVEL}/.env.worktree" \
    stop
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
# Subcommand: claim — block until the shared lane is granted to this
# worktree, then bring up infra + lane services bind-mounted onto it.
#   claim [--mode test|interactive] [-- <command...>]
# ---------------------------------------------------------------------------
cmd_claim() {
  local mode="interactive"
  local -a test_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --) shift; test_cmd=("$@"); break ;;
      *)
        printf 'ERROR: unknown argument to claim: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ "$mode" != "interactive" && "$mode" != "test" ]]; then
    printf 'ERROR: --mode must be "interactive" or "test" (got: %s)\n' "$mode" >&2
    return 1
  fi
  if [[ "$mode" == "test" && "${#test_cmd[@]}" -eq 0 ]]; then
    printf 'ERROR: --mode test requires a command after -- \n' >&2
    return 1
  fi

  wt_resolve_context || return 1
  if [[ -z "${WT_SHARED_LANE_SERVICES+x}" ]]; then
    printf 'ERROR: WT_SHARED_LANE_SERVICES not set — this project has no shared lane config.\n' >&2
    return 1
  fi

  wt_discover "$WT_PRINCIPAL_ROOT" || return 1

  local slug idle_timeout
  slug=$(basename "$WT_TOPLEVEL")
  idle_timeout="${WT_SHARED_IDLE_TIMEOUT}"

  printf 'Requesting shared lane for %s (repo=%s, mode=%s)... waiting for turn.\n' "$slug" "$WT_REPO_BASENAME" "$mode" >&2
  wt_queue_claim "$WT_REPO_BASENAME" "$slug" "$mode" "$idle_timeout" || {
    printf 'ERROR: queue daemon unreachable — start it with "%s queue up".\n' "$(basename "$0")" >&2
    return 1
  }
  printf 'Lane granted to %s.\n' "$slug" >&2

  wt_write_lane_env_file "$WT_PRINCIPAL_ROOT" "${WT_PROJECT_PREFIX}-lane"

  # compose.override.lane.yaml must exist before ANY wt_compose_lane call,
  # including the infra one below — wt_compose_lane always passes it via -f.
  # On a repo's first-ever claim it doesn't exist yet, so render it here
  # (db_name/bucket_name are pure string computations, no infra dependency).
  local db_name bucket_name
  db_name=$(wt_shared_resource_name db "$slug")
  bucket_name=$(wt_shared_resource_name bucket "$slug")
  wt_render_shared_override "$WT_TOPLEVEL" "$db_name" "$bucket_name" "${WT_SHARED_LANE_SERVICES[@]}" > "${WT_PRINCIPAL_ROOT}/compose.override.lane.yaml"

  # Infra first, and confirmed running, BEFORE the _ensure hooks below: on the
  # very first claim on a machine, db/rustfs don't exist yet, so exec-ing into
  # them (as the hooks do) would fail if we ran the hooks first.
  if [[ -n "${WT_SHARED_INFRA_SERVICES+x}" && "${#WT_SHARED_INFRA_SERVICES[@]}" -gt 0 ]]; then
    if ! wt_compose_lane up -d "${WT_SHARED_INFRA_SERVICES[@]}"; then
      printf 'ERROR: failed to start shared infra services — releasing the lane immediately.\n' >&2
      wt_queue_release "$WT_REPO_BASENAME" "$slug" || true
      return 1
    fi
    wt_wait_shared_infra_ready "${WT_SHARED_INFRA_SERVICES[@]}"
  fi

  if declare -F wt_project_shared_db_ensure >/dev/null; then
    wt_project_shared_db_ensure "$db_name" || printf 'WARNING: db ensure hook failed — see messages above.\n' >&2
  fi
  if declare -F wt_project_shared_bucket_ensure >/dev/null; then
    wt_project_shared_bucket_ensure "$bucket_name" || printf 'WARNING: bucket ensure hook failed — see messages above.\n' >&2
  fi

  if ! wt_compose_lane up -d "${WT_SHARED_LANE_SERVICES[@]}"; then
    printf 'ERROR: docker compose up failed — releasing the lane immediately.\n' >&2
    wt_queue_release "$WT_REPO_BASENAME" "$slug" || true
    return 1
  fi

  printf '\nShared lane active — %s now bind-mounted to %s.\n' "${WT_SHARED_LANE_SERVICES[*]}" "$slug" >&2

  if [[ "$mode" == "test" ]]; then
    printf 'Running: %s\n' "${test_cmd[*]}" >&2
    local exit_code=0
    "${test_cmd[@]}" || exit_code=$?
    wt_compose_lane down "${WT_SHARED_LANE_SERVICES[@]}" || true
    wt_queue_release "$WT_REPO_BASENAME" "$slug" || true
    return "$exit_code"
  fi

  # Interactive mode: background heartbeat until an explicit `release`, or
  # until the daemon times this holder out from inactivity.
  ( while sleep "${WT_SHARED_HEARTBEAT_INTERVAL}"; do
      wt_queue_heartbeat "$WT_REPO_BASENAME" "$slug" >/dev/null 2>&1 || true
    done ) &
  disown
  echo "$!" > "${WT_TOPLEVEL}/.worktree-env-heartbeat.pid"

  printf 'Run "%s release" when done.\n' "$(basename "$0")" >&2
}

# ---------------------------------------------------------------------------
# Subcommand: release — explicit teardown of a held shared lane.
# ---------------------------------------------------------------------------
cmd_release() {
  wt_resolve_context || return 1
  if [[ -z "${WT_SHARED_LANE_SERVICES+x}" ]]; then
    printf 'ERROR: WT_SHARED_LANE_SERVICES not set — nothing to release.\n' >&2
    return 1
  fi

  local slug pid_file
  slug=$(basename "$WT_TOPLEVEL")
  pid_file="${WT_TOPLEVEL}/.worktree-env-heartbeat.pid"

  if [[ -f "$pid_file" ]]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi

  wt_compose_lane down "${WT_SHARED_LANE_SERVICES[@]}" || true
  wt_queue_release "$WT_REPO_BASENAME" "$slug"
  printf 'Lane released.\n' >&2
}

# ---------------------------------------------------------------------------
# Subcommand: queue up|down — start/stop the queue daemon (one per machine,
# independent of any worktree or project).
# ---------------------------------------------------------------------------
cmd_queue() {
  local sub="${1:-}"
  case "$sub" in
    up)
      docker compose -f "${SCRIPT_DIR}/compose.queue.yaml" -p worktree-env-queue up -d
      ;;
    down)
      docker compose -f "${SCRIPT_DIR}/compose.queue.yaml" -p worktree-env-queue down
      ;;
    *)
      printf 'Usage: %s queue <up|down>\n' "$(basename "$0")" >&2
      return 1
      ;;
  esac
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

  if [[ -n "${WT_SHARED_LANE_SERVICES+x}" ]]; then
    local db_name bucket_name status_json holder_wt
    db_name=$(wt_shared_resource_name db "$slug")
    bucket_name=$(wt_shared_resource_name bucket "$slug")

    status_json=$(wt_queue_status_json "$WT_REPO_BASENAME" 2>/dev/null || printf '{}')
    holder_wt=$(printf '%s' "$status_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d.get("holder")
print(h["worktree"] if h else "")
' 2>/dev/null || printf '')

    if [[ "$holder_wt" == "$slug" ]]; then
      printf 'Releasing shared lane held by this worktree...\n' >&2
      rm -f "${WT_TOPLEVEL}/.worktree-env-heartbeat.pid"
      wt_compose_lane down "${WT_SHARED_LANE_SERVICES[@]}" 2>/dev/null || true
      wt_queue_release "$WT_REPO_BASENAME" "$slug" || true
    fi

    if declare -F wt_project_shared_db_drop >/dev/null; then
      wt_project_shared_db_drop "$db_name" || printf 'WARNING: db drop hook failed — see messages above.\n' >&2
    fi
    if declare -F wt_project_shared_bucket_drop >/dev/null; then
      wt_project_shared_bucket_drop "$bucket_name" || printf 'WARNING: bucket drop hook failed — see messages above.\n' >&2
    fi
  fi

  printf 'Done.\n' >&2
}

# ---------------------------------------------------------------------------
# Main dispatcher -- only runs when the script is executed directly.
# ---------------------------------------------------------------------------
main() {
  if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <up [services...]|status|stop|down|clean|claim [--mode test|interactive] [-- cmd...]|release|queue up|down>\n' "$(basename "$0")" >&2
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    up)      cmd_up "$@" ;;
    status)  cmd_status ;;
    stop)    cmd_stop ;;
    down)    cmd_down ;;
    clean)   cmd_clean ;;
    claim)   cmd_claim "$@" ;;
    release) cmd_release ;;
    queue)   cmd_queue "$@" ;;
    *)
      printf 'Unknown command: %s\n' "$cmd" >&2
      printf 'Usage: %s <up [services...]|status|stop|down|clean|claim [--mode test|interactive] [-- cmd...]|release|queue up|down>\n' "$(basename "$0")" >&2
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
