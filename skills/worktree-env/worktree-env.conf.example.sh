#!/usr/bin/env bash
# worktree-env.conf.sh — OPTIONAL per-project config for the worktree-env skill.
#
# Place a copy at <repo>/.claude/worktree-env.conf.sh and gitignore it:
#   echo '/.claude/worktree-env.conf.sh' >> .git/info/exclude
#
# It is sourced host-side by worktree-env.sh (never copied into the worktree).
# Everything below is OPTIONAL: with no config at all the engine auto-discovers
# every service/port from the base compose file, remaps them into a free port
# block, starts them all, and prints a raw URL list.

# --- Variables --------------------------------------------------------------
# WT_PROJECT_PREFIX="myrepo-wt"        # default: <principal-repo-basename>-wt
# WT_BLOCK_SIZE=20                     # default 20; auto-bumped if more ports
# WT_BASE_START=20000                  # first host port of block k=0
# WT_DEFAULT_SERVICES=(db backend)     # 'up' with no args; default: all discovered
WT_ENV_FILES=(backend/.env)            # provisioned from principal into the worktree

# --- Hooks (all optional) ---------------------------------------------------
# Extra YAML emitted under a service in compose.override.yaml. Use
# `wt_host_port_for <svc> <container_port>` to read the host port the engine
# assigned (indices follow the alphabetical discovery order, NOT a fixed +1/+2).
wt_project_service_extra() {
  local svc="$1" block_base="$2"
  case "$svc" in
    frontend)
      printf '    environment:\n'
      printf '      VITE_API_URL: "http://localhost:%s/api"\n' "$(wt_host_port_for backend 8000)"
      ;;
  esac
}

# Lines emitted under the top-level `volumes:` key (shared caches, etc.).
# wt_project_volumes() {
#   printf '  my_cache:\n    name: my_cache\n'   # fixed name → shared across worktrees
# }

# Runs after `up -d`. Use it to seed a fresh DB / provision accounts. The engine
# helpers wt_compose and $WT_TOPLEVEL are available here.
# wt_project_post_up() {
#   local block_base="$1"
#   wt_compose exec -T backend ./seed.sh
# }

# Pretty access output for `up` (URLs + test accounts). Falls back to a raw
# port listing when undefined.
# wt_project_print_access() {
#   local block_base="$1"
#   printf 'Frontend: http://localhost:%s\n' "$(wt_host_port_for frontend 3000)"
# }
