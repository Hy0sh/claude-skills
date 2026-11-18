#!/usr/bin/env bash
# The parts of a test-setup script that never change. The script handed to the human
# is this file, then the repo's hooks.sh, then the branch's body, concatenated into one
# self-contained file (see SKILL.md). `bash test-sheet-lib.sh selftest` checks this file.
#
# Hooks a repo's hooks.sh may define (all optional):
#   ts_ready <branch> <service base URL>
#       extra checks once the URL answers 200 (a CSS entry that compiles, no error in
#       the service's logs); a failure keeps waiting, with "unready" as the code.
#   ts_on_stall <branch> <elapsed minutes> <HTTP code, "unready" or "retry">
#       called every 10 s while the stack is not ready, and between two tries of
#       ts_retry; applies the repo's known recoveries, each guarded by `ts_once <name>`.
#   ts_totp_cmd <branch> <login>
#       prints the repo's own command that prints a current code, for accounts
#       declared with `repo` as their secret.
set -euo pipefail

TS_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TS_POLL_SECONDS="${TS_POLL_SECONDS:-10}"
TS_TIMEOUT_SECONDS="${TS_TIMEOUT_SECONDS:-600}"
TS_ACCOUNTS=()
TS_ONCE=" "
TS_BRANCH=""
TS_START=$SECONDS

# RFC 6238, SHA-1, 30 s, 6 digits; python3 stdlib only. Optional 2nd arg: unix time.
ts_totp() {
  python3 -I -c '
import base64, hmac, struct, sys, time
s = sys.argv[1].replace(" ", "").replace("-", "").upper()
k = base64.b32decode(s + "=" * (-len(s) % 8))
t = int(sys.argv[2]) if len(sys.argv) > 2 else int(time.time())
h = hmac.new(k, struct.pack(">Q", t // 30), "sha1").digest()
o = h[-1] & 15
print("%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000))
' "$@"
}

# True the first time a name is seen, false after: one recovery, one try.
ts_once() {
  case "$TS_ONCE" in *" $1 "*) return 1 ;; esac
  TS_ONCE="$TS_ONCE$1 "
}

ts_stall() {
  if declare -F ts_on_stall >/dev/null; then
    ts_on_stall "$TS_BRANCH" "$(((SECONDS - TS_START) / 60))" "$1" >/dev/null 2>&1 || true
  fi
}

# A service's address on the branch's stack: its traefik url, else its published port.
ts_url() {
  wtm ports "$1" | awk -v s="$2" '
    $1 == s "/url" { print $2; found = 1; exit }
    $1 == s && !p { p = $2 }
    END { if (!found && p) print (p ~ /^https?:/ ? p : "http://" p) }'
}

# ts_up <branch> <profile|-> <service> <path>: create or restart the stack, then wait
# until <service><path> answers 200 and ts_ready passes, calling ts_on_stall meanwhile.
ts_up() {
  local branch="$1" profile="$2" service="$3" path="$4"
  local args=()
  TS_BRANCH="$branch"
  TS_START=$SECONDS
  [ "$profile" != "-" ] && args=(--profile "$profile")
  # A service late on its first start makes create fail; the wait below recovers it.
  # ${a[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
  if wtm path "$branch" >/dev/null 2>&1; then
    wtm start "$branch" ${args[@]+"${args[@]}"} || true
  else
    wtm create "$branch" ${args[@]+"${args[@]}"} || true
  fi

  local base url code="000"
  base="$(ts_url "$branch" "$service")"
  if [ -z "$base" ]; then
    echo "No address for service '$service' in \`wtm ports $branch\`." >&2
    return 1
  fi
  url="$base$path"
  printf 'Waiting for %s ' "$url"
  while [ $((SECONDS - TS_START)) -lt "$TS_TIMEOUT_SECONDS" ]; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)"
    if [ "$code" = "200" ]; then
      # A page can answer 200 while the dev server still fails on other modules.
      if ! declare -F ts_ready >/dev/null || ts_ready "$branch" "$base" >/dev/null 2>&1; then
        echo " ready"
        return 0
      fi
      code="unready"
    fi
    ts_stall "$code"
    printf '.'
    sleep "$TS_POLL_SECONDS"
  done
  echo
  echo "The stack did not get ready on $url in $((TS_TIMEOUT_SECONDS / 60)) min (last: $code)." >&2
  echo "Send this output to whoever prepared the sheet; \`wtm remove $branch\` cleans up." >&2
  return 1
}

# ts_retry <tries> <seconds> <command...>: for a data command that fails while a
# service still starts; ts_on_stall gets "retry" between two tries.
ts_retry() {
  local n="$1" pause="$2" i=1
  shift 2
  until "$@"; do
    if [ "$i" -ge "$n" ]; then
      echo "Failed $n times: $*" >&2
      return 1
    fi
    ts_stall retry
    i=$((i + 1))
    sleep "$pause"
  done
}

# ts_account <login> <password> [base32 secret | repo]: an account for the final block.
ts_account() {
  TS_ACCOUNTS+=("$1"$'\t'"$2"$'\t'"${3:-}")
}

# ts_code <branch> [login]: the current code of that account (default: the first with one).
ts_code() {
  local branch="$1" want="${2:-}" line login password secret
  for line in ${TS_ACCOUNTS[@]+"${TS_ACCOUNTS[@]}"}; do
    IFS=$'\t' read -r login password secret <<<"$line"
    [ -z "$secret" ] && continue
    [ -n "$want" ] && [ "$want" != "$login" ] && continue
    if [ "$secret" = repo ]; then
      bash -c "$(ts_totp_cmd "$branch" "$login")" 2>/dev/null | grep -E '^[0-9]{6}$' | tail -n 1
    else
      ts_totp "$secret"
    fi
    return 0
  done
  echo "No account with a second factor${want:+ named $want}." >&2
  return 1
}

ts_summary() {
  local branch="$1" line login password secret
  echo
  echo "================ Ready to test ================"
  for line in ${TS_ACCOUNTS[@]+"${TS_ACCOUNTS[@]}"}; do
    IFS=$'\t' read -r login password secret <<<"$line"
    echo "Login:     $login"
    echo "Password:  $password"
    if [ -n "$secret" ]; then
      echo "Code now:  $(ts_code "$branch" "$login")"
      echo "New code:  bash $TS_SELF totp $login"
    fi
    echo
  done
  echo "When done: wtm remove $branch"
}

# ts_open <branch> <service> <path>...: print the screens to test and open them in the
# human's browser; TS_NO_OPEN=1 (the agent's own proof) only prints them.
ts_open() {
  local branch="$1" service="$2" base path opener=""
  shift 2
  base="$(ts_url "$branch" "$service")"
  if [ -z "${TS_NO_OPEN:-}" ]; then
    if command -v open >/dev/null; then opener=open
    elif command -v xdg-open >/dev/null; then opener=xdg-open
    fi
  fi
  echo "Screens to test:"
  for path in "$@"; do
    echo "  $base$path"
    [ -n "$opener" ] && "$opener" "$base$path" >/dev/null 2>&1 || true
  done
}

ts_selftest() {
  local dir out fail=0 lib
  lib="$TS_SELF"
  # RFC 6238 appendix B, SHA-1 secret "12345678901234567890", last 6 digits.
  [ "$(ts_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59)" = "287082" ] || { echo "FAIL totp t=59"; fail=1; }
  [ "$(ts_totp gezd-gnbv-gy3t-qojq-gezd-gnbv-gy3t-qojq 1111111109)" = "081804" ] || { echo "FAIL totp spaced lowercase"; fail=1; }

  # A script built the way SKILL.md says, against a fake wtm (create fails), a curl
  # that answers 404 twice then 200, a ts_ready that fails once, a flaky data command.
  dir="$(mktemp -d)"
  cat >"$dir/wtm" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"; echo "$*" >>"$d/wtm.log"
case "$1" in
  path) exit 1 ;;
  create) exit 1 ;;
  ports) printf 'urls, through traefik\n  web/url  http://web.x.localhost:1\n\nports\n  db  localhost:2\n' ;;
  exec) n=$(cat "$d/e" 2>/dev/null || echo 0); echo $((n + 1)) >"$d/e"; [ "$n" -ge 1 ] ;;
  run) printf 'banner\n> seed:totp\n123456\n' ;;
esac
EOF
  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$(dirname "$0")/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$(dirname "$0")/n"
[ "$n" -ge 2 ] && printf 200 || printf 404
EOF
  cat >"$dir/hooks.sh" <<EOF
ts_on_stall() { echo "\$3" >>"$dir/codes.log"; ts_once relaunch || return 0; echo stall >>"$dir/stall.log"; }
ts_ready() { [ -f "$dir/warm" ] || { touch "$dir/warm"; return 1; }; }
ts_totp_cmd() { echo "wtm run \$1 -- pnpm seed:totp"; }
EOF
  cat >"$dir/body.sh" <<'EOF'
ts_account a@example.test pw GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
ts_account b@example.test pw2 repo
setup() {
  ts_up feature/ABC-1-x light web /login
  ts_retry 3 0 wtm exec feature/ABC-1-x -- create-user a@example.test
  ts_summary feature/ABC-1-x
  ts_open feature/ABC-1-x web /login /orders
}
case "${1:-}" in
  "") setup ;;
  totp) ts_code feature/ABC-1-x "${2:-}" ;;
  expire) echo expired ;;
  *) exit 2 ;;
esac
EOF
  { cat "$lib"; echo; cat "$dir/hooks.sh"; echo; cat "$dir/body.sh"; } >"$dir/test-setup.sh"
  chmod +x "$dir/wtm" "$dir/curl"
  out="$(PATH="$dir:$PATH" TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)" || { echo "FAIL setup exit: $out"; fail=1; }
  grep -q 'create feature/ABC-1-x --profile light' "$dir/wtm.log" || { echo "FAIL create args"; fail=1; }
  [ "$(wc -l <"$dir/stall.log" | tr -d ' ')" = "1" ] || { echo "FAIL recovery should run once"; fail=1; }
  [ "$(tr '\n' ' ' <"$dir/codes.log")" = "404 404 unready retry " ] || { echo "FAIL stall codes: $(tr '\n' ' ' <"$dir/codes.log")"; fail=1; }
  grep -q 'http://web.x.localhost:1/login ..* ready' <<<"$out" || { echo "FAIL wait line"; fail=1; }
  grep -q "^New code:  bash $dir/test-setup.sh totp a@example.test$" <<<"$out" || { echo "FAIL fresh-code line"; fail=1; }
  grep -q '^Code now:  123456$' <<<"$out" || { echo "FAIL repo code"; fail=1; }
  grep -q '^  http://web.x.localhost:1/orders$' <<<"$out" || { echo "FAIL screens"; fail=1; }
  grep -q '^When done: wtm remove feature/ABC-1-x$' <<<"$out" || { echo "FAIL cleanup line"; fail=1; }
  [ "$(PATH="$dir:$PATH" bash "$dir/test-setup.sh" totp a@example.test)" = "$(ts_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ)" ] || { echo "FAIL totp subcommand"; fail=1; }
  [ "$(PATH="$dir:$PATH" bash "$dir/test-setup.sh" expire)" = "expired" ] || { echo "FAIL extra subcommand"; fail=1; }
  rm -rf "$dir"
  [ "$fail" = 0 ] && echo "selftest ok"
  return "$fail"
}

if [ "$(basename "$0")" = "test-sheet-lib.sh" ]; then
  case "${1:-}" in
    selftest) ts_selftest ;;
    *) echo "usage: bash $0 selftest" >&2; exit 2 ;;
  esac
fi
