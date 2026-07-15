#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source sans exécuter main
source "$HERE/worktree-env.sh"

fail=0
check() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 : attendu [$2] obtenu [$3]"; fail=1; fi
}

check "slug basename simple" "splashing-metcalfe" "$(wt_slug_from /Users/x/.claude/worktrees/splashing-metcalfe)"
check "slug repo principal"  "demorepo"      "$(wt_slug_from /Users/x/dev/demorepo)"

PAIRS=$'splashing-metcalfe\t/a/splashing-metcalfe\nother\t/a/other'
# même slug, même path → pas de conflit (code 1)
wt_slug_conflict "splashing-metcalfe" "/a/splashing-metcalfe" "$PAIRS"; check "pas de conflit self" "1" "$?"
# même slug, path différent → conflit (code 0)
wt_slug_conflict "splashing-metcalfe" "/b/splashing-metcalfe" "$PAIRS"; check "conflit détecté" "0" "$?"
# slug absent → pas de conflit (code 1)
wt_slug_conflict "nouveau" "/c/nouveau" "$PAIRS"; check "slug neuf" "1" "$?"

# Config minimale simulée pour le rendu
WT_PREVIEW_SERVICES=(backend frontend)
WT_FRONT_SERVICE=frontend
WT_API_SERVICE=backend
wt_project_service_extra() { :; }  # pas d'extra dans ce test

OUT="$(wt_render_override splashing-metcalfe demorepo)"
echo "$OUT" | grep -q 'name: wtenv-demorepo' ; check "réseau externe nommé" "0" "$?"
echo "$OUT" | grep -q 'Host(`api.splashing-metcalfe.localhost`)' ; check "route api exacte" "0" "$?"
echo "$OUT" | grep -q 'HostRegexp' ; check "route front regexp" "0" "$?"
echo "$OUT" | grep -q 'priority=100' ; check "priorité api > front" "0" "$?"

WT_INFRA_SERVICES=(db rustfs mailhog)
OUTI="$(wt_render_infra_override demorepo)"
echo "$OUTI" | grep -q 'ports: !override \[\]' ; check "ports strippés" "0" "$?"
echo "$OUTI" | grep -q 'aliases: \[db\]' ; check "alias réseau db" "0" "$?"
echo "$OUTI" | grep -q 'name: wtenv-demorepo' ; check "réseau infra" "0" "$?"

exit $fail
