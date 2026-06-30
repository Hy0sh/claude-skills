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
