#!/usr/bin/env bash
# The parts of a test-setup script that never change: start the branch's stack and wait
# for it, second-factor codes, the final block. A test-setup script sources this file,
# then the repo's hooks.sh, then calls ts_up / ts_account / ts_summary.
#
#   bash test-sheet-lib.sh totp <base32 secret>   # current 6-digit code
#   bash test-sheet-lib.sh selftest               # checks this file, no stack needed
#
# Hooks a repo's hooks.sh may define (all optional):
#   ts_ready <branch> <service base URL>
#       extra checks once the URL answers 200 (a CSS entry that compiles, no error in
#       the service's logs); a failure keeps waiting, with "unready" as the code.
#   ts_on_stall <branch> <elapsed minutes> <last HTTP code or "unready">
#       called every 10 s while the stack is not ready; applies the repo's known
#       recoveries, each guarded by `ts_once <name>` so it runs once.
#   ts_totp_cmd <branch> <login> <secret>
#       prints the command that gives a fresh code, when the repo has its own
#       (default: `bash <this file> totp <secret>`).

TS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
TS_POLL_SECONDS="${TS_POLL_SECONDS:-10}"
TS_TIMEOUT_SECONDS="${TS_TIMEOUT_SECONDS:-600}"
TS_ACCOUNTS=()
TS_ONCE=" "

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

# A service's address on the branch's stack: its traefik url, else its published port.
ts_url() {
  wtm ports "$1" | awk -v s="$2" '
    $1 == s "/url" { print $2; found = 1; exit }
    $1 == s && !p { p = $2 }
    END { if (!found && p) print (p ~ /^https?:/ ? p : "http://" p) }'
}

# ts_up <branch> <profile|-> <service> <path>: create or restart the stack, then wait
# until <service><path> answers 200, calling ts_on_stall while it does not.
ts_up() {
  local branch="$1" profile="$2" service="$3" path="$4"
  local args=()
  [ "$profile" != "-" ] && args=(--profile "$profile")
  # ${a[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
  if wtm path "$branch" >/dev/null 2>&1; then
    wtm start "$branch" ${args[@]+"${args[@]}"}
  else
    wtm create "$branch" ${args[@]+"${args[@]}"}
  fi

  local base url code="000" waited=0
  base="$(ts_url "$branch" "$service")"
  if [ -z "$base" ]; then
    echo "No address for service '$service' in \`wtm ports $branch\`." >&2
    return 1
  fi
  url="$base$path"
  printf 'Waiting for %s ' "$url"
  while [ "$waited" -lt "$TS_TIMEOUT_SECONDS" ]; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)"
    if [ "$code" = "200" ]; then
      # A page can answer 200 while the dev server still fails on other modules.
      if ! declare -F ts_ready >/dev/null || ts_ready "$branch" "$base" >/dev/null 2>&1; then
        echo " ready"
        return 0
      fi
      code="unready"
    fi
    if declare -F ts_on_stall >/dev/null; then
      ts_on_stall "$branch" "$((waited / 60))" "$code" >/dev/null 2>&1 || true
    fi
    printf '.'
    sleep "$TS_POLL_SECONDS"
    waited=$((waited + TS_POLL_SECONDS))
  done
  echo
  echo "The stack did not answer 200 on $url after $((TS_TIMEOUT_SECONDS / 60)) min (last code: $code)." >&2
  echo "Send this output to whoever prepared the sheet; \`wtm remove $branch\` cleans up." >&2
  return 1
}

# ts_account <login> <password> [totp secret]: an account for the final block.
ts_account() {
  TS_ACCOUNTS+=("$1"$'\t'"$2"$'\t'"${3:-}")
}

ts_summary() {
  local branch="$1" line login password secret cmd
  echo
  echo "================ Ready to test ================"
  echo "Open:"
  wtm ports "$branch" | awk '$2 ~ /^https?:/ { printf "  %-18s %s\n", $1, $2 }'
  for line in ${TS_ACCOUNTS[@]+"${TS_ACCOUNTS[@]}"}; do
    IFS=$'\t' read -r login password secret <<<"$line"
    echo
    echo "Login:     $login"
    echo "Password:  $password"
    [ -z "$secret" ] && continue
    if declare -F ts_totp_cmd >/dev/null; then
      cmd="$(ts_totp_cmd "$branch" "$login" "$secret")"
    else
      cmd="bash $TS_LIB totp $secret"
    fi
    echo "Code now:  $(bash -c "$cmd")"
    echo "New code:  $cmd"
  done
  echo
  echo "When done: wtm remove $branch"
}

ts_selftest() {
  local dir out fail=0
  # RFC 6238 appendix B, SHA-1 secret "12345678901234567890", last 6 digits.
  [ "$(ts_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59)" = "287082" ] || { echo "FAIL totp t=59"; fail=1; }
  [ "$(ts_totp gezd-gnbv-gy3t-qojq-gezd-gnbv-gy3t-qojq 1111111109)" = "081804" ] || { echo "FAIL totp spaced lowercase"; fail=1; }

  # ts_up against a fake wtm and a curl that answers 404 twice, then 200.
  dir="$(mktemp -d)"
  cat >"$dir/wtm" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/wtm.log"
case "$1" in
  path) exit 1 ;;
  ports) printf 'urls, through traefik\n  web/url  http://web.x.localhost:1\n\nports\n  db  localhost:2\n' ;;
esac
EOF
  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$(dirname "$0")/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$(dirname "$0")/n"
[ "$n" -ge 2 ] && printf 200 || printf 404
EOF
  chmod +x "$dir/wtm" "$dir/curl"
  out="$(
    PATH="$dir:$PATH" TS_POLL_SECONDS=0
    ts_on_stall() { echo "$3" >>"$dir/codes.log"; ts_once relaunch || return 0; echo stall >>"$dir/stall.log"; }
    ts_ready() { [ -f "$dir/warm" ] || { touch "$dir/warm"; return 1; }; }
    ts_up feature/ABC-1-x light web /login && ts_account a@example.test pw GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ && ts_summary feature/ABC-1-x
  )" || { echo "FAIL ts_up returned non-zero"; fail=1; }
  grep -q 'create feature/ABC-1-x --profile light' "$dir/wtm.log" || { echo "FAIL create args"; fail=1; }
  [ "$(wc -l <"$dir/stall.log" | tr -d ' ')" = "1" ] || { echo "FAIL ts_on_stall should run its recovery once"; fail=1; }
  [ "$(tr '\n' ' ' <"$dir/codes.log")" = "404 404 unready " ] || { echo "FAIL ts_ready failure should stall as unready"; fail=1; }
  grep -q 'http://web.x.localhost:1/login ..* ready' <<<"$out" || { echo "FAIL wait line"; fail=1; }
  grep -q '^New code:  bash .*test-sheet-lib.sh totp GEZD' <<<"$out" || { echo "FAIL fresh-code line"; fail=1; }
  grep -q '^Code now:  [0-9]\{6\}$' <<<"$out" || { echo "FAIL current code"; fail=1; }
  grep -q '^When done: wtm remove feature/ABC-1-x$' <<<"$out" || { echo "FAIL cleanup line"; fail=1; }
  rm -rf "$dir"
  [ "$fail" = 0 ] && echo "selftest ok"
  return "$fail"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    totp) ts_totp "$2" ;;
    selftest) ts_selftest ;;
    *) echo "usage: bash $0 totp <base32 secret> | selftest" >&2; exit 2 ;;
  esac
fi
