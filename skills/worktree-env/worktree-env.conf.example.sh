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

# --- Shared lane mode (optional, additive) ----------------------------------
# Alternative to the isolated-per-worktree mode above: ONE lane of containers
# shared across all worktrees of this repo, arbitrated by queue_daemon.py
# (`worktree-env.sh claim` / `release` / `queue up|down`). Use on heavy
# stacks where running several isolated worktree stacks in parallel already
# saturates the machine. Setting WT_SHARED_LANE_SERVICES is what opts a
# project into this mode; everything else here is optional.

# Services started once per machine via `claim`, never swapped between
# worktrees (DB, object storage, mailcatcher, ...).
# WT_SHARED_INFRA_SERVICES=(db rustfs mailhog pgadmin)

# Services bind-mounted onto the current lane holder by `claim` (no port
# remap: shared lane mode always uses the base compose file's fixed ports).
# WT_SHARED_LANE_SERVICES=(backend celery_worker celery_beat frontend)

# Seconds without a heartbeat before an interactive `claim` is auto-released
# and the lane handed to the next worktree in the FIFO queue. Default 2700 (45min).
# WT_SHARED_IDLE_TIMEOUT=2700

# Naming convention for the per-worktree logical DB and bucket that `claim`
# ensures exist (and `clean` drops). Default: "${WT_PROJECT_PREFIX}_<slug>"
# for both kinds. Override only if a project needs a different convention.
# wt_project_shared_resource_name() {
#   local kind="$1" slug="$2"   # kind: "db" or "bucket"
#   printf '%s_%s' "$WT_PROJECT_PREFIX" "$slug"
# }

# Ensure the per-worktree logical DB / bucket exist (idempotent). Run by
# `claim` before bringing the lane up. Without these hooks, `claim` skips
# provisioning and the project is responsible for it another way.
# wt_project_shared_db_ensure() {
#   local db_name="$1"
#   wt_compose_lane exec -T db createdb -U postgres "$db_name" 2>/dev/null || true
# }
# wt_project_shared_bucket_ensure() {
#   local bucket_name="$1"
#   wt_compose_lane exec -T rustfs mc mb "local/${bucket_name}" 2>/dev/null || true
# }

# Env vars to inject into a lane service so isolation is actually applied at
# runtime -- the per-worktree DB/bucket that `claim` ensures exist above are
# just names unless the containers are told to use them. The engine doesn't
# know DB_NAME/AWS_STORAGE_BUCKET_NAME by nature (project-specific), so this
# hook is the extension point: print "KEY=VALUE" lines (one per line) for a
# given service; merged into compose.override.lane.yaml's `environment:` for
# that service, alongside its `volumes: !override` block. Without this hook,
# no environment vars are injected (containers keep the base compose's fixed
# values -- fine for a project with nothing to isolate this way).
# wt_project_shared_lane_env() {
#   local svc="$1" db_name="$2" bucket_name="$3"
#   case "$svc" in
#     backend|celery_worker|celery_beat)
#       printf 'DB_NAME=%s\n' "$db_name"
#       printf 'AWS_STORAGE_BUCKET_NAME=%s\n' "$bucket_name"
#       ;;
#   esac
# }

# Drop the per-worktree logical DB / bucket. Run by `clean`.
# wt_project_shared_db_drop() {
#   local db_name="$1"
#   wt_compose_lane exec -T db dropdb -U postgres --if-exists "$db_name"
# }
# wt_project_shared_bucket_drop() {
#   local bucket_name="$1"
#   wt_compose_lane exec -T rustfs mc rb --force "local/${bucket_name}"
# }
