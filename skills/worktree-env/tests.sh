#!/usr/bin/env bash
# tests.sh — TDD test harness for worktree-env.sh (pure logic only, no docker)
# Run: bash tests.sh
# Exits 0 if all tests pass, 1 on first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script without executing main
source "${SCRIPT_DIR}/worktree-env.sh"

# ---------------------------------------------------------------------------
# Minimal test framework
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; echo "       Expected: $2"; echo "       Got:      $3"; TESTS_FAILED=$(( TESTS_FAILED + 1 )); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc" "$expected" "$actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc" "(contains) $needle" "$haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if echo "$haystack" | grep -qF "$needle"; then
    fail "$desc" "(not contains) $needle" "(found in) $haystack"
  else
    pass "$desc"
  fi
}

# ---------------------------------------------------------------------------
# Helper: create a fake .env.worktree with a given WT_BLOCK value
# ---------------------------------------------------------------------------
make_env_worktree() {
  local dir="$1" k="$2"
  mkdir -p "$dir"
  echo "COMPOSE_PROJECT_NAME=myrepo-wt-test-${k}" > "${dir}/.env.worktree"
  echo "WT_BLOCK=${k}" >> "${dir}/.env.worktree"
}

# ---------------------------------------------------------------------------
# Test suite: wt_block_base
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_block_base ==="

WT_BASE_START=20000; WT_BLOCK_SIZE=20
assert_eq "k=0 → 20000"  "20000" "$(wt_block_base 0)"
assert_eq "k=1 → 20020"  "20020" "$(wt_block_base 1)"
assert_eq "k=2 → 20040"  "20040" "$(wt_block_base 2)"
assert_eq "k=10 → 20200" "20200" "$(wt_block_base 10)"

echo ""
echo "=== wt_block_base — configurable size ==="
WT_BLOCK_SIZE=30
assert_eq "size=30 k=1 → 20030" "20030" "$(wt_block_base 1)"
WT_BLOCK_SIZE=20   # restore default for later suites

# ---------------------------------------------------------------------------
# Test suite: wt_alloc_block
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_alloc_block — empty state ==="

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

EMPTY_DIR="${TMPDIR_BASE}/empty_worktrees"
mkdir -p "$EMPTY_DIR"
assert_eq "Empty state → k=0" "0" "$(wt_alloc_block "$EMPTY_DIR" "")"

echo ""
echo "=== wt_alloc_block — k=0 taken via env file ==="
WT_DIR="${TMPDIR_BASE}/worktrees_k0"
make_env_worktree "${WT_DIR}/wt-a" "0"
assert_eq "k=0 taken → k=1" "1" "$(wt_alloc_block "$WT_DIR" "")"

echo ""
echo "=== wt_alloc_block — k=0 and k=1 taken via env files ==="
WT_DIR2="${TMPDIR_BASE}/worktrees_k01"
make_env_worktree "${WT_DIR2}/wt-a" "0"
make_env_worktree "${WT_DIR2}/wt-b" "1"
assert_eq "k=0,k=1 taken → k=2" "2" "$(wt_alloc_block "$WT_DIR2" "")"

echo ""
echo "=== wt_alloc_block — k=0 taken via docker_blocks ==="
WT_DIR3="${TMPDIR_BASE}/worktrees_empty_docker"
mkdir -p "$WT_DIR3"
assert_eq "docker k=0 → k=1" "1" "$(wt_alloc_block "$WT_DIR3" "0")"

echo ""
echo "=== wt_alloc_block — k=0 docker + k=1 file → k=2 ==="
WT_DIR4="${TMPDIR_BASE}/worktrees_mixed"
make_env_worktree "${WT_DIR4}/wt-x" "1"
assert_eq "k=0 docker + k=1 file → k=2" "2" "$(wt_alloc_block "$WT_DIR4" "0")"

echo ""
echo "=== wt_alloc_block — non-contiguous gap k=0,k=2 → k=1 ==="
WT_DIR5="${TMPDIR_BASE}/worktrees_gap"
make_env_worktree "${WT_DIR5}/wt-a" "0"
make_env_worktree "${WT_DIR5}/wt-b" "2"
assert_eq "k=0,k=2 taken → k=1" "1" "$(wt_alloc_block "$WT_DIR5" "")"

echo ""
echo "=== wt_alloc_block — non-existent dir → k=0 ==="
assert_eq "Non-existent dir → k=0" "0" "$(wt_alloc_block "/does/not/exist/for/real" "")"

# ---------------------------------------------------------------------------
# Test suite: wt_parse_compose_json
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_parse_compose_json ==="
read -r -d '' COMPOSE_JSON <<'JSON' || true
{"services":{
  "backend":{"container_name":"gallia-backend","ports":[{"target":8000,"published":"8000"}]},
  "celery_worker":{},
  "db":{"container_name":"gallia-db","ports":[{"target":5432,"published":"5432"}]},
  "frontend":{"container_name":"gallia-frontend","ports":[{"target":3000,"published":"3000"}]},
  "pgadmin":{"ports":[{"target":80,"published":"5050"}]}
}}
JSON
PARSED=$(printf '%s' "$COMPOSE_JSON" | wt_parse_compose_json)
assert_contains "lists all services" "SVC celery_worker" "$PARSED"
assert_contains "backend has cname" "CNAME backend" "$PARSED"
assert_not_contains "pgadmin has no cname" "CNAME pgadmin" "$PARSED"
assert_not_contains "celery has no cname" "CNAME celery_worker" "$PARSED"
assert_contains "backend target port" "PORT backend 8000" "$PARSED"
assert_contains "pgadmin target port (80 not 5050)" "PORT pgadmin 80" "$PARSED"
assert_not_contains "pgadmin not mapped on published" "PORT pgadmin 5050" "$PARSED"

# ---------------------------------------------------------------------------
# Test suite: wt_find_base_compose
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_find_base_compose ==="
BC_DIR="${TMPDIR_BASE}/basecompose"
mkdir -p "$BC_DIR"
touch "${BC_DIR}/docker-compose.yml"
assert_eq "falls back to docker-compose.yml" "${BC_DIR}/docker-compose.yml" "$(wt_find_base_compose "$BC_DIR")"
touch "${BC_DIR}/compose.yaml"
assert_eq "prefers compose.yaml" "${BC_DIR}/compose.yaml" "$(wt_find_base_compose "$BC_DIR")"

# ---------------------------------------------------------------------------
# Test suite: wt_render_override — generic, no hooks
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_render_override — generic, no hooks ==="
# Fake discovery: db (cname, 5432), backend (cname, 8000), pgadmin (ports only, 80)
WT_DISC_SERVICES=(backend db pgadmin)
WT_DISC_CNAME_SERVICES=(backend db)
WT_DISC_PORT_ENTRIES=("backend 8000" "db 5432" "pgadmin 80")
unset -f wt_project_service_extra wt_project_volumes 2>/dev/null || true

# Render via redirect (not command substitution) so WT_RENDER_BLOCK_BASE persists
# into this shell — mirrors production (wt_ensure_env renders to a file).
RENDER_OUT="${TMPDIR_BASE}/override.yaml"
wt_render_override "myrepo-wt-feat" "20000" > "$RENDER_OUT"
OVERRIDE=$(cat "$RENDER_OUT")

assert_contains "backend cname re-derived" 'container_name: ${COMPOSE_PROJECT_NAME}-backend' "$OVERRIDE"
assert_contains "db cname re-derived"      'container_name: ${COMPOSE_PROJECT_NAME}-db' "$OVERRIDE"
assert_not_contains "pgadmin gets no cname" 'container_name: ${COMPOSE_PROJECT_NAME}-pgadmin' "$OVERRIDE"
# Indices follow WT_DISC_PORT_ENTRIES order: backend=0, db=1, pgadmin=2
assert_contains "backend port 20000:8000" '"20000:8000"' "$OVERRIDE"
assert_contains "db port 20001:5432"      '"20001:5432"' "$OVERRIDE"
assert_contains "pgadmin port 20002:80"   '"20002:80"'   "$OVERRIDE"
assert_contains "ports tagged !override"  'ports: !override' "$OVERRIDE"
# No top-level volumes block when no wt_project_volumes hook (none anywhere here)
assert_not_contains "no stray volumes block" "volumes:" "$OVERRIDE"

echo ""
echo "=== wt_host_port_for after render ==="
assert_eq "host port for backend:8000" "20000" "$(wt_host_port_for backend 8000)"
assert_eq "host port for db:5432"      "20001" "$(wt_host_port_for db 5432)"

# ---------------------------------------------------------------------------
# Test: port mappings for a different block (k=1, base=20020) — no collision
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_render_override — port mappings (base=20020) ==="
OVERRIDE_K1=$(wt_render_override "myrepo-wt-feat" "20020")
assert_contains "k=1 backend port 20020:8000" '"20020:8000"' "$OVERRIDE_K1"
assert_not_contains "k=1 doesn't reuse 20000" '"20000:8000"' "$OVERRIDE_K1"

# ---------------------------------------------------------------------------
# Test suite: wt_render_override — service_extra + volumes hooks
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_render_override — service_extra + volumes hooks ==="
wt_project_service_extra() {
  local svc="$1" bbase="$2"
  if [[ "$svc" == "backend" ]]; then
    local api; api=$(wt_host_port_for backend 8000)
    printf '    environment:\n      API_PORT: "%s"\n' "$api"
  fi
}
wt_project_volumes() { printf '  shared_cache:\n    name: shared_cache\n'; }

OVERRIDE2=$(wt_render_override "myrepo-wt-feat" "20000")
assert_contains "service_extra spliced under backend" 'API_PORT: "20000"' "$OVERRIDE2"
assert_contains "volumes hook emits top-level block" $'volumes:\n  shared_cache:' "$OVERRIDE2"
unset -f wt_project_service_extra wt_project_volumes

# ---------------------------------------------------------------------------
# Test suite: wt_provision_env_files — iterates WT_ENV_FILES
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_provision_env_files — iterates WT_ENV_FILES ==="
PR_ROOT="${TMPDIR_BASE}/principal"; WT_ROOT="${TMPDIR_BASE}/wt"
mkdir -p "${PR_ROOT}/backend" "${WT_ROOT}/backend"
echo "SECRET=1" > "${PR_ROOT}/backend/.env"
WT_ENV_FILES=("backend/.env")
wt_provision_env_files "$WT_ROOT" "$PR_ROOT"
assert_eq "env file copied into worktree" "SECRET=1" "$(cat "${WT_ROOT}/backend/.env")"
# Idempotent: existing worktree file is not overwritten
echo "LOCAL=2" > "${WT_ROOT}/backend/.env"
wt_provision_env_files "$WT_ROOT" "$PR_ROOT"
assert_eq "existing file preserved" "LOCAL=2" "$(cat "${WT_ROOT}/backend/.env")"
WT_ENV_FILES=()

# ---------------------------------------------------------------------------
# Test: wt_write_env_file
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_write_env_file ==="
ENV_TEST_DIR="${TMPDIR_BASE}/env_write_test"
mkdir -p "$ENV_TEST_DIR"
wt_write_env_file "$ENV_TEST_DIR" "myrepo-wt-myslug" "3"
ENV_CONTENT=$(cat "${ENV_TEST_DIR}/.env.worktree")
assert_contains "env file has COMPOSE_PROJECT_NAME" "COMPOSE_PROJECT_NAME=myrepo-wt-myslug" "$ENV_CONTENT"
assert_contains "env file has WT_BLOCK" "WT_BLOCK=3" "$ENV_CONTENT"

# ---------------------------------------------------------------------------
# Test suite: wt_render_shared_override — shared lane bind-mount rewriting
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_render_shared_override — bind mounts point to holder worktree ==="
WT_DISC_SERVICES=(backend frontend db)
WT_DISC_VOLBIND_ENTRIES=("backend ./backend /app" "frontend ./frontend /app")

SHARED_A=$(wt_render_shared_override "/worktrees/wt-a" "" "" backend frontend)
assert_contains "backend bind-mounted to wt-a" '"/worktrees/wt-a/backend:/app"' "$SHARED_A"
assert_contains "frontend bind-mounted to wt-a" '"/worktrees/wt-a/frontend:/app"' "$SHARED_A"
assert_not_contains "db not a lane service, no override emitted" "  db:" "$SHARED_A"
assert_contains "volumes tagged !override" "volumes: !override" "$SHARED_A"

SHARED_B=$(wt_render_shared_override "/worktrees/wt-b" "" "" backend frontend)
assert_contains "backend re-pointed to wt-b after re-claim" '"/worktrees/wt-b/backend:/app"' "$SHARED_B"
assert_not_contains "stale wt-a path gone after re-claim" "/worktrees/wt-a" "$SHARED_B"

# Without a wt_project_shared_lane_env hook, no environment block is emitted
# (zero-config regression safety — a project with no such need sees no change).
assert_not_contains "no environment block without hook" "environment:" "$SHARED_A"
WT_DISC_VOLBIND_ENTRIES=()

# ---------------------------------------------------------------------------
# Test suite: wt_render_shared_override — env hook injects DB_NAME/bucket
# (Bug 1: isolation was rendered in volumes only, never actually applied to
# the containers because no environment vars were emitted at all.)
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_render_shared_override — env hook merges with volumes (single mapping) ==="
WT_DISC_SERVICES=(backend celery_worker db)
WT_DISC_VOLBIND_ENTRIES=("backend ./backend /app")

wt_project_shared_lane_env() {
  local svc="$1" db_name="$2" bucket_name="$3"
  case "$svc" in
    backend|celery_worker)
      printf 'DB_NAME=%s\n' "$db_name"
      printf 'AWS_STORAGE_BUCKET_NAME=%s\n' "$bucket_name"
      ;;
  esac
}

SHARED_ENV=$(wt_render_shared_override "/worktrees/wt-a" "gallia_wt_a" "gallia-media-wt-a" backend celery_worker)
assert_contains "DB_NAME injected for backend" 'DB_NAME: "gallia_wt_a"' "$SHARED_ENV"
assert_contains "bucket name injected for backend" 'AWS_STORAGE_BUCKET_NAME: "gallia-media-wt-a"' "$SHARED_ENV"
assert_contains "volumes still present alongside env for backend" '"/worktrees/wt-a/backend:/app"' "$SHARED_ENV"
assert_contains "env-only service (no volbind) still gets env" 'DB_NAME: "gallia_wt_a"' "$SHARED_ENV"
BACKEND_KEY_COUNT=$(printf '%s\n' "$SHARED_ENV" | grep -c '^  backend:')
assert_eq "single backend mapping, no duplicated service key" "1" "$BACKEND_KEY_COUNT"

unset -f wt_project_shared_lane_env
WT_DISC_VOLBIND_ENTRIES=()

# ---------------------------------------------------------------------------
# Test suite: wt_shared_resource_name — DB/bucket naming convention
# ---------------------------------------------------------------------------
echo ""
echo "=== wt_shared_resource_name — default convention + hook override ==="
WT_PROJECT_PREFIX="myrepo-wt"
unset -f wt_project_shared_resource_name 2>/dev/null || true
assert_eq "default db name"     "myrepo-wt_jazzy" "$(wt_shared_resource_name db jazzy)"
assert_eq "default bucket name" "myrepo-wt_jazzy" "$(wt_shared_resource_name bucket jazzy)"

wt_project_shared_resource_name() {
  local kind="$1" slug="$2"
  printf 'custom_%s_%s' "$kind" "$slug"
}
assert_eq "hook overrides naming convention" "custom_db_jazzy" "$(wt_shared_resource_name db jazzy)"
unset -f wt_project_shared_resource_name

# ---------------------------------------------------------------------------
# Queue daemon integration tests — real queue_daemon.py subprocess, no docker.
# ---------------------------------------------------------------------------
QUEUE_DAEMON_PID=""

start_queue_daemon() {
  local port="$1" state_file="$2" watchdog_interval="${3:-1}"
  WT_QUEUE_PORT="$port" WT_QUEUE_STATE_FILE="$state_file" WT_QUEUE_WATCHDOG_INTERVAL="$watchdog_interval" \
    python3 "${SCRIPT_DIR}/queue_daemon.py" >/dev/null 2>&1 &
  QUEUE_DAEMON_PID=$!
  local i=0
  until curl -sS -f "http://127.0.0.1:${port}/status?repo=__ping__" >/dev/null 2>&1; do
    sleep 0.2
    i=$(( i + 1 ))
    if [[ "$i" -gt 50 ]]; then
      echo "  ERROR: queue_daemon.py did not start on port ${port}" >&2
      return 1
    fi
  done
}

stop_queue_daemon() {
  [[ -n "$QUEUE_DAEMON_PID" ]] && kill "$QUEUE_DAEMON_PID" 2>/dev/null || true
  wait "$QUEUE_DAEMON_PID" 2>/dev/null || true
  QUEUE_DAEMON_PID=""
}

echo ""
echo "=== queue_daemon — FIFO ordering between two concurrent claims ==="
QSTATE_FIFO="${TMPDIR_BASE}/queue_state_fifo.json"
start_queue_daemon 18765 "$QSTATE_FIFO" 1
WT_QUEUE_PORT=18765

wt_queue_claim "testrepo" "wt-a" "interactive" "2700"
STATUS1=$(wt_queue_status_json "testrepo")
assert_contains "wt-a granted immediately (no prior holder)" '"worktree": "wt-a"' "$STATUS1"

wt_queue_claim "testrepo" "wt-b" "interactive" "2700" >/dev/null &
CLAIM_B_PID=$!
sleep 0.5
STATUS2=$(wt_queue_status_json "testrepo")
assert_contains "wt-a still holder while wt-b waits" '"worktree": "wt-a"' "$STATUS2"
assert_contains "wt-b queued behind wt-a" '"wt-b"' "$STATUS2"

wt_queue_release "testrepo" "wt-a"
wait "$CLAIM_B_PID"
STATUS3=$(wt_queue_status_json "testrepo")
assert_contains "wt-b becomes holder in FIFO order after wt-a releases" '"worktree": "wt-b"' "$STATUS3"

stop_queue_daemon

echo ""
echo "=== queue_daemon — idle timeout auto-releases an inactive interactive holder ==="
QSTATE_TIMEOUT="${TMPDIR_BASE}/queue_state_timeout.json"
start_queue_daemon 18766 "$QSTATE_TIMEOUT" 1
WT_QUEUE_PORT=18766

wt_queue_claim "repo2" "wt-x" "interactive" "1"   # idle_timeout=1s, no heartbeat sent
wt_queue_claim "repo2" "wt-y" "interactive" "2700" >/dev/null &
CLAIM_Y_PID=$!
sleep 3   # > idle_timeout(1s) + watchdog sweep interval(1s)
wait "$CLAIM_Y_PID"
STATUS_TIMEOUT=$(wt_queue_status_json "repo2")
assert_contains "wt-y granted after wt-x's idle timeout elapses, no manual action" '"worktree": "wt-y"' "$STATUS_TIMEOUT"

stop_queue_daemon

echo ""
echo "=== queue_daemon — heartbeat keeps a holder from being timed out ==="
QSTATE_HB="${TMPDIR_BASE}/queue_state_heartbeat.json"
start_queue_daemon 18767 "$QSTATE_HB" 1
WT_QUEUE_PORT=18767

wt_queue_claim "repo3" "wt-z" "interactive" "2"   # idle_timeout=2s
( for _ in 1 2 3 4 5; do sleep 0.5; wt_queue_heartbeat "repo3" "wt-z" >/dev/null 2>&1 || true; done ) &
HB_PID=$!
sleep 3
STATUS_HB=$(wt_queue_status_json "repo3")
assert_contains "wt-z still holder thanks to heartbeats" '"worktree": "wt-z"' "$STATUS_HB"
wait "$HB_PID" 2>/dev/null || true

stop_queue_daemon

# ---------------------------------------------------------------------------
# Test suite: cmd_clean — shared-mode lane release + DB/bucket drop hooks
# ---------------------------------------------------------------------------
echo ""
echo "=== cmd_clean — releases a held lane and calls DB/bucket drop hooks ==="

CLEAN_PRINCIPAL="${TMPDIR_BASE}/clean_principal"
mkdir -p "${CLEAN_PRINCIPAL}/backend"
git -C "$CLEAN_PRINCIPAL" init -q
git -C "$CLEAN_PRINCIPAL" config user.email test@test.com
git -C "$CLEAN_PRINCIPAL" config user.name test
cat > "${CLEAN_PRINCIPAL}/compose.yaml" <<'YAML'
services:
  backend:
    image: python:3.12-alpine
    volumes:
      - ./backend:/app
    ports:
      - "8000:8000"
  db:
    image: postgres:16-alpine
YAML
touch "${CLEAN_PRINCIPAL}/backend/.keep"
git -C "$CLEAN_PRINCIPAL" add -A
git -C "$CLEAN_PRINCIPAL" commit -q -m init

CLEAN_WT="${TMPDIR_BASE}/clean_worktree"
git -C "$CLEAN_PRINCIPAL" worktree add -q -b clean-test-branch "$CLEAN_WT" >/dev/null

QSTATE_CLEAN="${TMPDIR_BASE}/queue_state_clean.json"
start_queue_daemon 18768 "$QSTATE_CLEAN" 1
WT_QUEUE_PORT=18768

DOCKER_CALLS_LOG="${TMPDIR_BASE}/docker_calls.log"
: > "$DOCKER_CALLS_LOG"
docker() {
  echo "docker $*" >> "$DOCKER_CALLS_LOG"
  return 0
}

DB_DROP_LOG="${TMPDIR_BASE}/db_drop.log"
BUCKET_DROP_LOG="${TMPDIR_BASE}/bucket_drop.log"
: > "$DB_DROP_LOG"; : > "$BUCKET_DROP_LOG"
wt_project_shared_db_drop()     { echo "DROP DB $1" >> "$DB_DROP_LOG"; }
wt_project_shared_bucket_drop() { echo "DROP BUCKET $1" >> "$BUCKET_DROP_LOG"; }

ORIG_PWD="$PWD"
cd "$CLEAN_WT"
unset WT_PROJECT_PREFIX   # avoid leaking the prefix set by the naming-convention suite above
wt_resolve_context
WT_SHARED_LANE_SERVICES=(backend)
CLEAN_SLUG=$(basename "$WT_TOPLEVEL")
wt_queue_claim "$WT_REPO_BASENAME" "$CLEAN_SLUG" "interactive" "2700"

cmd_clean

cd "$ORIG_PWD"

STATUS_CLEAN=$(WT_QUEUE_PORT=18768 wt_queue_status_json "$WT_REPO_BASENAME")
assert_contains "lane released by clean (holder now null)" '"holder": null' "$STATUS_CLEAN"
assert_contains "clean tore down the lane via docker compose down" "down" "$(cat "$DOCKER_CALLS_LOG")"
assert_contains "db drop hook called with per-worktree name" "DROP DB clean_principal-wt_${CLEAN_SLUG}" "$(cat "$DB_DROP_LOG")"
assert_contains "bucket drop hook called with per-worktree name" "DROP BUCKET clean_principal-wt_${CLEAN_SLUG}" "$(cat "$BUCKET_DROP_LOG")"

unset -f docker wt_project_shared_db_drop wt_project_shared_bucket_drop
unset WT_SHARED_LANE_SERVICES
stop_queue_daemon

# ---------------------------------------------------------------------------
# Test suite: cmd_claim — infra started (and waited on) BEFORE the _ensure
# hooks, which are called BEFORE the lane services start (Bug 2: previously
# the _ensure hooks ran first and `exec`'d into containers that might not
# exist yet on the first claim on a machine).
#
# wt_discover, wt_queue_claim/release and wt_compose_lane are stubbed here —
# queue FIFO/daemon behavior is already covered above, and no real docker is
# available in this pure-logic harness. Restored via re-source afterwards.
# ---------------------------------------------------------------------------
echo ""
echo "=== cmd_claim — infra up+ready, then _ensure hooks, then lane up (bug 2) ==="

CLAIM_PRINCIPAL="${TMPDIR_BASE}/claim_principal"
mkdir -p "$CLAIM_PRINCIPAL"
git -C "$CLAIM_PRINCIPAL" init -q
git -C "$CLAIM_PRINCIPAL" config user.email test@test.com
git -C "$CLAIM_PRINCIPAL" config user.name test
touch "${CLAIM_PRINCIPAL}/.keep"
git -C "$CLAIM_PRINCIPAL" add -A
git -C "$CLAIM_PRINCIPAL" commit -q -m init

CLAIM_WT="${TMPDIR_BASE}/claim_worktree"
git -C "$CLAIM_PRINCIPAL" worktree add -q -b claim-test-branch "$CLAIM_WT" >/dev/null

CLAIM_ORDER=""
wt_discover()      { WT_DISC_SERVICES=(); WT_DISC_VOLBIND_ENTRIES=(); }
wt_queue_claim()   { return 0; }
wt_queue_release() { return 0; }
wt_compose_lane() {
  if [[ "$1" == "up" && "$2" == "-d" ]]; then
    shift 2
    if [[ " $* " == *" backend "* ]]; then
      CLAIM_ORDER+="LANE_UP;"
    else
      # Bug 3 regression guard: wt_compose_lane always passes
      # `-f compose.override.lane.yaml` to docker compose (see wt_compose_lane
      # definition) -- on a repo's first-ever claim this file must already
      # exist by the time the INFRA services are started, not just by the
      # time the LANE services are started (which is too late).
      if [[ -f "${WT_PRINCIPAL_ROOT}/compose.override.lane.yaml" ]]; then
        CLAIM_ORDER+="OVERRIDE_PRESENT_AT_INFRA_UP;"
      else
        CLAIM_ORDER+="OVERRIDE_MISSING_AT_INFRA_UP;"
      fi
      CLAIM_ORDER+="INFRA_UP;"
    fi
  elif [[ "$1" == "ps" ]]; then
    printf 'db\n'   # reports the infra service already running -> no retry wait
  elif [[ "$1" == "down" ]]; then
    CLAIM_ORDER+="LANE_DOWN;"
  fi
  return 0
}
wt_project_shared_db_ensure()     { CLAIM_ORDER+="ENSURE_DB;"; }
wt_project_shared_bucket_ensure() { CLAIM_ORDER+="ENSURE_BUCKET;"; }

ORIG_PWD2="$PWD"
cd "$CLAIM_WT"
unset WT_PROJECT_PREFIX   # avoid leaking the prefix set by earlier suites
WT_SHARED_INFRA_SERVICES=(db)
WT_SHARED_LANE_SERVICES=(backend)

cmd_claim --mode test -- true

cd "$ORIG_PWD2"

assert_eq "compose.override.lane.yaml exists before infra up (bug 3), then infra up -> ensure hooks -> lane up -> lane down" \
  "OVERRIDE_PRESENT_AT_INFRA_UP;INFRA_UP;ENSURE_DB;ENSURE_BUCKET;LANE_UP;LANE_DOWN;" "$CLAIM_ORDER"

unset WT_SHARED_INFRA_SERVICES WT_SHARED_LANE_SERVICES
# Restore the real wt_discover/wt_queue_*/wt_compose_lane/hooks stubbed above.
source "${SCRIPT_DIR}/worktree-env.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Tests run:    ${TESTS_RUN}"
echo "Tests failed: ${TESTS_FAILED}"
echo "========================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi

echo "All tests passed."
