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
#   ts_foreign_worktree <path>
#       true when the worktree holding the branch is not the human's (default: an
#       agent's, under /.claude/worktrees/); ts_up then stops instead of reusing it.
set -euo pipefail

TS_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TS_POLL_SECONDS="${TS_POLL_SECONDS:-10}"
TS_TIMEOUT_SECONDS="${TS_TIMEOUT_SECONDS:-600}"
TS_ACCOUNTS=()
TS_ONCE=" "
TS_BRANCH=""
TS_BASE=""
TS_URL=""
TS_COMMIT=""
TS_START=$SECONDS
TS_CODE=""
TS_VITE_BAD=""

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

ts_foreign_worktree() {
  case "$1" in */.claude/worktrees/*) return 0 ;; esac
  return 1
}

# Vite's dependency optimizer can crash once at start (an install rewriting node_modules
# under it) and then answers 504 on every /node_modules/.vite/deps/* for good, while the
# pages still answer 200. Reads the page's entry module and requires 200 on up to 3 of its
# prebundled imports. On failure sets TS_VITE_BAD to "<url> <code>". No entry module or no
# such import (not a Vite page): nothing to check.
ts_vite_check() {
  local entry out code path
  TS_VITE_BAD=""
  entry="$(curl -s -m 5 "$TS_URL" | grep -oE 'src="/[^@"][^"]*"' | head -n 1 | sed 's/^src="//; s/"$//' || true)"
  [ -z "$entry" ] && return 0
  out="$(curl -s -m 10 -w '\n%{http_code}' "$TS_BASE$entry" || true)"
  code="${out##*$'\n'}"
  if [ "$code" != 200 ]; then
    TS_VITE_BAD="$TS_BASE$entry ${code:-000}"
    return 1
  fi
  for path in $(printf '%s' "${out%$'\n'*}" | grep -oE '/node_modules/\.vite/deps/[A-Za-z0-9_./@-]+(\?[A-Za-z0-9=&_.-]+)?' | sort -u | head -n 3 || true); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$TS_BASE$path" || true)"
    if [ "$code" != 200 ]; then
      TS_VITE_BAD="$TS_BASE$path ${code:-000}"
      return 1
    fi
  done
}

# Sets TS_CODE to 200 when TS_URL answers 200, Vite's deps load and ts_ready passes, else
# the HTTP code or "unready". Not a subshell: TS_VITE_BAD must survive for ts_up.
ts_probe() {
  TS_VITE_BAD=""
  TS_CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$TS_URL" || true)"
  # A page can answer 200 while the dev server still fails on other modules.
  if [ "$TS_CODE" = 200 ] && ! ts_vite_check; then
    TS_CODE=unready
  fi
  if [ "$TS_CODE" = 200 ] && declare -F ts_ready >/dev/null && ! ts_ready "$TS_BRANCH" "$TS_BASE" >/dev/null 2>&1; then
    TS_CODE=unready
  fi
}

# ts_up <branch> <profile|-> <service> <path>: create or restart the stack, then wait
# until <service><path> answers 200 and ts_ready passes, calling ts_on_stall meanwhile.
ts_up() {
  local branch="$1" profile="$2" service="$3" path="$4"
  local args=() held
  TS_BRANCH="$branch"
  TS_START=$SECONDS
  [ "$profile" != "-" ] && args=(--profile "$profile")
  # A service late on its first start makes create fail; the wait below recovers it.
  # ${a[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
  if held="$(wtm path "$branch" 2>/dev/null)"; then
    # git lets a branch live in one worktree only: an agent's stack can stop under us.
    if [ -z "${TS_ALLOW_FOREIGN:-}" ] && ts_foreign_worktree "$held"; then
      echo "branch $branch is held by $held; rerun once it is free" >&2
      return 1
    fi
    wtm start "$branch" ${args[@]+"${args[@]}"} || true
  else
    wtm create "$branch" ${args[@]+"${args[@]}"} || true
  fi

  local code="000"
  TS_BASE="$(ts_url "$branch" "$service")"
  if [ -z "$TS_BASE" ]; then
    echo "No address for service '$service' in \`wtm ports $branch\`." >&2
    return 1
  fi
  TS_URL="$TS_BASE$path"
  printf 'Waiting for %s ' "$TS_URL"
  while [ $((SECONDS - TS_START)) -lt "$TS_TIMEOUT_SECONDS" ]; do
    ts_probe
    code="$TS_CODE"
    if [ "$code" = 200 ]; then
      echo " ready"
      return 0
    fi
    # Vite's optimizer does not retry after a crash: restart that service, once.
    if [ "${TS_VITE_BAD##* }" = 504 ] && ts_once vite-restart; then
      echo
      echo "Vite's dependencies answer 504 ($TS_VITE_BAD); restarting $service once."
      wtm run "$branch" -- docker compose restart "$service" >/dev/null 2>&1 || true
    fi
    ts_stall "$code"
    printf '.'
    sleep "$TS_POLL_SECONDS"
  done
  echo
  if [ -n "$TS_VITE_BAD" ]; then
    echo "Service '$service' still serves a broken Vite after one restart: $TS_VITE_BAD." >&2
  fi
  echo "The stack did not get ready on $TS_URL in $((TS_TIMEOUT_SECONDS / 60)) min (last: $code)." >&2
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

# ts_commit <sha>: the commit the sheet covers; ts_summary warns when the branch moved since.
ts_commit() {
  TS_COMMIT="$1"
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

# Copies stdin's text to the clipboard (pbcopy, else xclip, else wl-copy); false when none.
ts_copy() {
  if command -v pbcopy >/dev/null; then pbcopy
  elif command -v xclip >/dev/null; then xclip -selection clipboard
  elif command -v wl-copy >/dev/null; then wl-copy
  else return 1
  fi
}

# A human at a terminal (the clipboard is theirs): not the agent's proof run (TS_NO_OPEN),
# not a pipe. TS_INTERACTIVE=1 forces it, for the selftest.
ts_interactive() {
  [ -n "${TS_INTERACTIVE:-}" ] || { [ -t 0 ] && [ -z "${TS_NO_OPEN:-}" ]; }
}

# ts_code_show <branch> [login]: prints a fresh code, and copies it for pasting.
ts_code_show() {
  local code
  code="$(ts_code "$@")" || return 1
  echo "$code"
  if ts_interactive && printf '%s' "$code" | ts_copy; then
    echo "(code copied to the clipboard)" >&2
  fi
}

# ts_paste_login <branch> [login]: the sign-in values, one at a time on the clipboard
# (login, password, then the current code, made last as it lives 30 s); Enter moves on.
# Without a human or a clipboard tool, nothing: ts_summary has printed them all.
ts_paste_login() {
  local branch="$1" want="${2:-}" line login password secret pick="" v name value
  ts_interactive || return 0
  for line in ${TS_ACCOUNTS[@]+"${TS_ACCOUNTS[@]}"}; do
    IFS=$'\t' read -r login password secret <<<"$line"
    [ -n "$want" ] && [ "$want" != "$login" ] && continue
    pick="$line"
    break
  done
  [ -z "$pick" ] && return 0
  IFS=$'\t' read -r login password secret <<<"$pick"
  echo
  echo "Sign-in: each value goes to the clipboard in turn; paste it in the form, then press Enter."
  for v in login password code; do
    case "$v" in
      login) name="the login"; value="$login" ;;
      password) name="the password"; value="$password" ;;
      code) [ -z "$secret" ] && break; name="the second-factor code"; value="$(ts_code "$branch" "$login")" ;;
    esac
    if ! printf '%s' "$value" | ts_copy; then
      echo "No clipboard tool (pbcopy, xclip, wl-copy): use the values printed above."
      return 0
    fi
    printf 'Copied %s.' "$name"
    if [ "$v" != code ] && { [ "$v" != password ] || [ -n "$secret" ]; }; then
      printf ' Enter for the next: '
      read -r _ || true
    else
      echo
    fi
  done
}

ts_summary() {
  local branch="$1" line login password secret code wt head want
  # The stack can stop during the data commands; never print a dead address.
  if [ -n "$TS_URL" ]; then
    ts_probe
    code="$TS_CODE"
    if [ "$code" != 200 ]; then
      echo "The stack stopped answering on $TS_URL (last: $code); rerun the script." >&2
      return 1
    fi
  fi
  echo
  echo "================ Ready to test ================"
  # A develop merge or a fix commit after the sheet was written makes some lines stale.
  wt="$(wtm path "$branch" 2>/dev/null || true)"
  if [ -n "$TS_COMMIT" ] && [ -n "$wt" ]; then
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    want="$(git -C "$wt" rev-parse -q --verify "$TS_COMMIT^{commit}" 2>/dev/null || true)"
    if [ -n "$head" ] && [ "$head" != "$want" ]; then
      echo "WARNING: this sheet covers $TS_COMMIT, the branch is now at ${head:0:7}; ask for a fresh sheet."
      echo
    fi
  fi
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
# human's browser, then walk the first account's sign-in values through the clipboard
# (ts_paste_login); TS_NO_OPEN=1 (the agent's own proof) only prints the screens.
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
  # Last step of the setup: the sign-in values for the form just opened.
  ts_paste_login "$branch"
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
  path) [ -n "${WTM_PATH:-}" ] && echo "$WTM_PATH" || exit 1 ;;
  create) exit 1 ;;
  ports) printf 'urls, through traefik\n  web/url  http://web.x.localhost:1\n\nports\n  db  localhost:2\n' ;;
  exec) n=$(cat "$d/e" 2>/dev/null || echo 0); echo $((n + 1)) >"$d/e"; [ "$n" -ge 1 ] ;;
  run) case "$*" in
    *restart*) [ -n "${WTM_KEEP_BROKEN:-}" ] || rm -f "$d/vite-broken" ;;
    *) printf 'banner\n> seed:totp\n123456\n' ;;
  esac ;;
esac
EOF
  # /login: 404 twice then 200 (its HTML names the entry module); the entry module imports
  # a prebundled dep; deps answer 504 while a vite-broken file exists (a restart removes it).
  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"; url=""; w=""; o=""
for a in "$@"; do
  case "$a" in -w) w=1 ;; -o) o=1 ;; esac
  url="$a"
done
code=200; body=""
case "$url" in
  */.vite/deps/*) [ -f "$d/vite-broken" ] && code=504 ;;
  */src/main.tsx) body='import r from "/node_modules/.vite/deps/react.js?v=1a";' ;;
  */login)
    if [ -n "$o" ]; then
      n=$(cat "$d/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$d/n"
      [ "$n" -ge 2 ] || code=404
    else
      body='<script type="module" src="/@vite/client"></script><script type="module" src="/src/main.tsx"></script>'
    fi ;;
esac
if [ -n "$o" ]; then printf '%s' "$code"; else printf '%s' "$body"; [ -n "$w" ] && printf '\n%s' "$code"; fi
exit 0
EOF
  cat >"$dir/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >>"$(dirname "$0")/clip.log"; echo >>"$(dirname "$0")/clip.log"
EOF
  cat >"$dir/hooks.sh" <<EOF
ts_on_stall() { echo "\$3" >>"$dir/codes.log"; ts_once relaunch || return 0; echo stall >>"$dir/stall.log"; }
ts_ready() { [ -f "$dir/warm" ] || { touch "$dir/warm"; return 1; }; }
ts_totp_cmd() { echo "wtm run \$1 -- pnpm seed:totp"; }
EOF
  cat >"$dir/body.sh" <<'EOF'
ts_commit 0000000
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
  totp) ts_code_show feature/ABC-1-x "${2:-}" ;;
  expire) echo expired ;;
  *) exit 2 ;;
esac
EOF
  { cat "$lib"; echo; cat "$dir/hooks.sh"; echo; cat "$dir/body.sh"; } >"$dir/test-setup.sh"
  chmod +x "$dir/wtm" "$dir/curl" "$dir/pbcopy"
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

  # The branch held by an agent's worktree: stop, never start or reuse its stack.
  : >"$dir/wtm.log"
  if out="$(PATH="$dir:$PATH" WTM_PATH=/x/repo/.claude/worktrees/agent-1 TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)"; then
    echo "FAIL foreign worktree should stop"; fail=1
  fi
  [ "$out" = "branch feature/ABC-1-x is held by /x/repo/.claude/worktrees/agent-1; rerun once it is free" ] || { echo "FAIL foreign line: $out"; fail=1; }
  grep -qE '^(start|create) ' "$dir/wtm.log" && { echo "FAIL foreign stack touched"; fail=1; }

  # The human's own worktree, moved past the commit the sheet covers: reuse it, and warn.
  git init -q "$dir/wt" && git -C "$dir/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
  out="$(PATH="$dir:$PATH" WTM_PATH="$dir/wt" TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)" || { echo "FAIL own worktree exit: $out"; fail=1; }
  grep -q '^start feature/ABC-1-x' "$dir/wtm.log" || { echo "FAIL own worktree not started"; fail=1; }
  grep -q '^WARNING: this sheet covers 0000000, the branch is now at ' <<<"$out" || { echo "FAIL stale warning"; fail=1; }

  # Vite's deps answer 504 behind a page that answers 200: restart the front end once,
  # wait again, and go on.
  : >"$dir/wtm.log"; touch "$dir/vite-broken"
  out="$(PATH="$dir:$PATH" TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)" || { echo "FAIL vite restart exit: $out"; fail=1; }
  [ "$(grep -c '^run feature/ABC-1-x -- docker compose restart web$' "$dir/wtm.log")" = 1 ] || { echo "FAIL vite restart once"; fail=1; }
  grep -q 'deps/react.js?v=1a 504' <<<"$out" || { echo "FAIL vite 504 line"; fail=1; }

  # Still 504 after the restart: stop, naming the service and the failing URL.
  : >"$dir/wtm.log"; touch "$dir/vite-broken"
  if out="$(PATH="$dir:$PATH" WTM_KEEP_BROKEN=1 TS_TIMEOUT_SECONDS=3 TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)"; then
    echo "FAIL vite still broken should stop"; fail=1
  fi
  grep -q "^Service 'web' still serves a broken Vite after one restart: http://web.x.localhost:1/node_modules/.vite/deps/react.js?v=1a 504\.$" <<<"$out" || { echo "FAIL vite stop line: $out"; fail=1; }
  [ "$(grep -c 'docker compose restart web$' "$dir/wtm.log")" = 1 ] || { echo "FAIL vite restart should stay once"; fail=1; }
  rm -f "$dir/vite-broken"

  # Sign-in values on the clipboard, one per Enter: login, password, then the current code.
  : >"$dir/clip.log"
  out="$(printf '\n\n\n' | PATH="$dir:$PATH" TS_INTERACTIVE=1 TS_POLL_SECONDS=0 TS_NO_OPEN=1 bash "$dir/test-setup.sh" 2>&1)" || { echo "FAIL clipboard exit: $out"; fail=1; }
  [ "$(tr '\n' ' ' <"$dir/clip.log")" = "a@example.test pw $(ts_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ) " ] || { echo "FAIL clipboard values: $(tr '\n' ' ' <"$dir/clip.log")"; fail=1; }
  grep -q '^Password:  pw$' <<<"$out" || { echo "FAIL values still printed"; fail=1; }
  # The fresh-code helper copies the code too, and still prints only it on stdout.
  : >"$dir/clip.log"
  out="$(PATH="$dir:$PATH" TS_INTERACTIVE=1 bash "$dir/test-setup.sh" totp a@example.test 2>/dev/null)"
  [ "$out" = "$(ts_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ)" ] && [ "$(cat "$dir/clip.log")" = "$out" ] || { echo "FAIL totp clipboard"; fail=1; }

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
