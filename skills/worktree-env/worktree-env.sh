#!/usr/bin/env bash
# worktree-env v2 — infra mutualisée + tests éphémères + preview Traefik nommée.
set -uo pipefail
WT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wt_slug_from() { basename "$1"; }

# Retourne 0 (conflit) si <slug> est déjà associé à un chemin != <current_path>.
wt_slug_conflict() {
  local slug="$1" current="$2" pairs="$3" s p
  while IFS=$'\t' read -r s p; do
    [ -z "$s" ] && continue
    if [ "$s" = "$slug" ] && [ "$p" != "$current" ]; then
      echo "$p"
      return 0
    fi
  done <<< "$pairs"
  return 1
}

wt_die() { echo "❌ $*" >&2; exit 1; }

# Liste "slug<TAB>path" des toplevels connus (repo principal + worktrees).
wt_collect_slug_pairs() {
  local principal="$1" wt
  echo -e "$(basename "$principal")\t$principal"
  if [ -d "$principal/.claude/worktrees" ]; then
    for wt in "$principal"/.claude/worktrees/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      echo -e "$(basename "$wt")\t$wt"
    done
  fi
}

wt_resolve_context() {
  WT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || wt_die "Pas un dépôt git."
  local common f; common="$(git rev-parse --git-common-dir 2>/dev/null)"
  case "$common" in /*) : ;; *) common="$WT_TOPLEVEL/$common" ;; esac
  WT_PRINCIPAL_ROOT="$(cd "$(dirname "$common")" && pwd)"
  WT_REPO="$(basename "$WT_PRINCIPAL_ROOT")"
  WT_SLUG="$(wt_slug_from "$WT_TOPLEVEL")"
  WT_NETWORK="wtenv-${WT_REPO}"
  WT_BASE_COMPOSE=""
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$WT_PRINCIPAL_ROOT/$f" ] && { WT_BASE_COMPOSE="$WT_PRINCIPAL_ROOT/$f"; break; }
  done
  [ -n "$WT_BASE_COMPOSE" ] || wt_die "Aucun fichier compose de base trouvé dans $WT_PRINCIPAL_ROOT."
  WT_CONF="$WT_PRINCIPAL_ROOT/.claude/wtenv.conf.sh"
  # shellcheck disable=SC1090
  [ -f "$WT_CONF" ] && source "$WT_CONF"
  # garde-fou slug
  local other
  if other="$(wt_slug_conflict "$WT_SLUG" "$WT_TOPLEVEL" "$(wt_collect_slug_pairs "$WT_PRINCIPAL_ROOT")")"; then
    wt_die "Slug '$WT_SLUG' déjà utilisé par un autre chemin : $other. Renomme ce worktree (basename unique requis)."
  fi
}

# Imprime le compose.override.yaml du worktree courant.
wt_render_override() {
  local slug="$1" repo="$2" svc
  echo "# généré par worktree-env — ne pas éditer"
  echo "networks:"
  echo "  wtenv:"
  echo "    external: true"
  echo "    name: wtenv-${repo}"
  echo "services:"
  for svc in "${WT_PREVIEW_SERVICES[@]}"; do
    echo "  ${svc}:"
    echo "    networks:"
    echo "      wtenv:"
    echo "        aliases: [${svc}]"
    if [ "$svc" = "$WT_FRONT_SERVICE" ]; then
      echo "    labels:"
      echo "      - traefik.enable=true"
      echo "      - \"traefik.http.routers.${slug}-front.rule=HostRegexp(\`^[a-z0-9-]+\\\\.${slug}\\\\.localhost\$\`)\""
      echo "      - traefik.http.routers.${slug}-front.priority=1"
      echo "      - traefik.http.services.${slug}-front.loadbalancer.server.port=${WT_FRONT_PORT:-3000}"
    fi
    if [ "$svc" = "$WT_API_SERVICE" ]; then
      echo "    labels:"
      echo "      - traefik.enable=true"
      echo "      - \"traefik.http.routers.${slug}-api.rule=Host(\`api.${slug}.localhost\`)\""
      echo "      - traefik.http.routers.${slug}-api.priority=100"
      echo "      - traefik.http.services.${slug}-api.loadbalancer.server.port=${WT_API_PORT:-8000}"
    fi
    wt_project_service_extra "$svc" "$slug"
  done
}

# Imprime le compose.override.yaml pour les services d'infra (mutualisés).
wt_render_infra_override() {
  local repo="$1" svc
  echo "# généré par worktree-env — infra partagée"
  echo "networks:"
  echo "  wtenv:"
  echo "    external: true"
  echo "    name: wtenv-${repo}"
  echo "services:"
  for svc in "${WT_INFRA_SERVICES[@]}"; do
    echo "  ${svc}:"
    echo "    ports: !override []"
    echo "    networks:"
    echo "      wtenv:"
    echo "        aliases: [${svc}]"
  done
}

wt_infra_override_path() { echo "$WT_PRINCIPAL_ROOT/.claude/.wtenv-infra.override.yaml"; }

cmd_infra() {
  wt_resolve_context
  local action="${1:-up}" proj="wtenv-infra-${WT_REPO}" ovr; ovr="$(wt_infra_override_path)"
  case "$action" in
    up)
      docker network inspect "$WT_NETWORK" >/dev/null 2>&1 || docker network create "$WT_NETWORK" >/dev/null
      wt_render_infra_override "$WT_REPO" > "$ovr"
      WT_NETWORK="$WT_NETWORK" docker compose -p "$proj" \
        --project-directory "$WT_PRINCIPAL_ROOT" \
        -f "$WT_BASE_COMPOSE" -f "$ovr" -f "$WT_SCRIPT_DIR/compose.traefik.yaml" \
        up -d "${WT_INFRA_SERVICES[@]}" traefik
      echo "✅ Infra + Traefik démarrés (projet $proj, réseau $WT_NETWORK)."
      ;;
    down)
      WT_NETWORK="$WT_NETWORK" docker compose -p "$proj" \
        --project-directory "$WT_PRINCIPAL_ROOT" \
        -f "$WT_BASE_COMPOSE" -f "$ovr" -f "$WT_SCRIPT_DIR/compose.traefik.yaml" \
        down
      docker network rm "$WT_NETWORK" 2>/dev/null || true
      echo "✅ Infra arrêtée."
      ;;
    *) wt_die "infra : action inconnue '$action' (up|down)." ;;
  esac
}

wt_override_path() { echo "$WT_TOPLEVEL/compose.override.wtenv.yaml"; }
wt_project() { echo "wtenv-${WT_REPO}-${WT_SLUG}"; }

# Compose scopé au worktree courant.
wt_compose() {
  local ovr; ovr="$(wt_override_path)"
  wt_render_override "$WT_SLUG" "$WT_REPO" > "$ovr"
  WT_NETWORK="$WT_NETWORK" docker compose -p "$(wt_project)" \
    --project-directory "$WT_TOPLEVEL" \
    -f "$WT_BASE_COMPOSE" -f "$ovr" "$@"
}

wt_require_infra() {
  docker network inspect "$WT_NETWORK" >/dev/null 2>&1 || \
    wt_die "Infra non démarrée. Lance d'abord : worktree-env infra up"
}

# Copie dans le worktree courant les fichiers env déclarés dans WT_ENV_FILES,
# depuis le dépôt principal, s'ils sont absents (les worktrees n'embarquent pas
# les fichiers gitignorés comme backend/.env).
wt_provision_env_files() {
  local rel
  for rel in "${WT_ENV_FILES[@]:-}"; do
    [ -z "$rel" ] && continue
    if [ ! -f "$WT_TOPLEVEL/$rel" ] && [ -f "$WT_PRINCIPAL_ROOT/$rel" ]; then
      mkdir -p "$(dirname "$WT_TOPLEVEL/$rel")"
      cp "$WT_PRINCIPAL_ROOT/$rel" "$WT_TOPLEVEL/$rel"
    fi
  done
}

# Nombre de previews vivantes (projets wtenv-<repo>-* hors infra).
wt_preview_count() {
  docker compose ls --format '{{.Name}}' 2>/dev/null \
    | grep -E "^wtenv-${WT_REPO}-" | grep -vc "^wtenv-infra-${WT_REPO}$"
}

cmd_test() {
  wt_resolve_context; wt_require_infra
  wt_provision_env_files
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || wt_die "Usage : worktree-env test -- <commande de test>"
  wt_compose run --rm "$WT_TEST_SERVICE" "$@"
}

cmd_preview() {
  wt_resolve_context; wt_require_infra
  wt_provision_env_files
  local action="${1:-up}"
  case "$action" in
    up)
      local n; n="$(wt_preview_count)"
      # Autoriser si ce worktree est déjà une des previews vivantes
      if [ "$n" -ge 2 ] && ! docker compose ls --format '{{.Name}}' | grep -qx "$(wt_project)"; then
        echo "⛔ Plafond de 2 previews atteint. Previews vivantes :" >&2
        docker compose ls --format '{{.Name}}' | grep -E "^wtenv-${WT_REPO}-" | grep -v "^wtenv-infra-${WT_REPO}$" >&2
        wt_die "Arrête-en une : worktree-env preview stop (dans son worktree)."
      fi
      declare -f wt_project_db_ensure >/dev/null && wt_project_db_ensure "$WT_SLUG"
      wt_compose up -d "${WT_PREVIEW_SERVICES[@]}"
      declare -f wt_project_seed >/dev/null && wt_project_seed "$WT_SLUG"
      echo "=== Accès ==="
      if declare -f wt_project_print_access >/dev/null; then
        wt_project_print_access "$WT_SLUG"
      else
        echo "Front : http://<org>.${WT_SLUG}.localhost"
        echo "API   : http://api.${WT_SLUG}.localhost"
      fi
      ;;
    stop)
      wt_compose down
      echo "✅ Preview arrêtée pour $WT_SLUG."
      ;;
    *) wt_die "preview : action inconnue '$action' (up|stop)." ;;
  esac
}

cmd_status() {
  wt_resolve_context
  echo "Repo        : $WT_REPO"
  echo "Worktree    : $WT_SLUG ($WT_TOPLEVEL)"
  echo "Réseau      : $WT_NETWORK ($(docker network inspect "$WT_NETWORK" >/dev/null 2>&1 && echo actif || echo absent))"
  echo "Previews vivantes :"
  docker compose ls --format '{{.Name}}' 2>/dev/null | grep -E "^wtenv-${WT_REPO}-" | grep -v "^wtenv-infra-${WT_REPO}$" || echo "  (aucune)"
}

cmd_clean() {
  wt_resolve_context
  wt_compose down -v 2>/dev/null || true
  declare -f wt_project_db_drop >/dev/null && wt_project_db_drop "$WT_SLUG"
  rm -f "$(wt_override_path)"
  echo "✅ Empreinte de $WT_SLUG nettoyée."
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    infra)   cmd_infra "$@" ;;
    test)    cmd_test "$@" ;;
    preview) cmd_preview "$@" ;;
    status)  cmd_status "$@" ;;
    clean)   cmd_clean "$@" ;;
    ""|help|-h|--help)
      cat <<'EOF'
worktree-env — infra mutualisée + tests éphémères + preview nommée
  infra up|down        démarre/arrête l'infra partagée + Traefik (1×/machine)
  test -- <cmd>        lance <cmd> dans un conteneur éphémère (DB du worktree)
  preview [up]|stop    lève/coupe la preview web du worktree (URL <org>.<slug>.localhost)
  status               état infra + previews vivantes
  clean                nettoie l'empreinte du worktree courant
EOF
      ;;
    *) wt_die "Commande inconnue : $cmd (voir : worktree-env help)." ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
