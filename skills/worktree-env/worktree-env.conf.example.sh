#!/usr/bin/env bash
# wtenv.conf.sh — Template de configuration minimal pour la compétence worktree-env.
#
# Copiez ce fichier dans <repo>/.claude/wtenv.conf.sh et personnalisez-le :
#   cp skills/worktree-env/worktree-env.conf.example.sh .claude/wtenv.conf.sh
#   # Modifiez .claude/wtenv.conf.sh avec vos valeurs spécifiques au projet
#   echo '/.claude/wtenv.conf.sh' >> .git/info/exclude
#
# Il est sourcé côté hôte par worktree-env.sh et fournit des variables + hooks
# pour le moteur d'isolation.

# --- Variables essentielles ---------------------------------------------------------

# Services lancés dans l'infrastructure partagée (BD, caches, mailcatcher, etc).
# Ils sont lancés une fois par machine par le moteur d'installation et partagés
# entre tous les répertoires de travail.
# Exemple : (db postgres cache redis mailhog)
WT_INFRA_SERVICES=(db cache)

# Services lancés en mode aperçu (liés via une voie partagée ou isolés par
# répertoire de travail, selon votre mode). Utilisés lors de `wt_resolve_context`.
# Exemple : (backend frontend worker)
WT_PREVIEW_SERVICES=(backend frontend)

# Nom du service pour les exécutions de tests (isolé par répertoire de travail).
# Exemple : backend
WT_TEST_SERVICE=backend

# Nom du service pour le front-end (utilisé pour le mappage des ports et compose.override).
# Exemple : frontend
WT_FRONT_SERVICE=frontend

# Nom du service pour l'API/backend (utilisé pour le mappage des ports et compose.override).
# Exemple : backend
WT_API_SERVICE=backend

# Port hôte pour le conteneur front-end (la détection du port conteneur est automatique).
# Exemple : 3000
WT_FRONT_PORT=3000

# Port hôte pour le conteneur API.
# Exemple : 8000
WT_API_PORT=8000

# Fichiers de configuration ou env à provisionner à partir du répertoire principal dans
# le répertoire de travail avant le lancement de `up`. Relatif à la racine du répertoire principal.
# Exemple : (backend/.env frontend/.env.development)
WT_ENV_FILES=(backend/.env)

# --- Hooks (tous optionnels) ---------------------------------------------------

# Génère le nom logique de la base de données pour un slug de répertoire de travail donné.
# $1: slug du répertoire de travail (ex : « feature-auth », généré automatiquement à partir de la branche)
# Doit renvoyer un nom approprié comme nom de base de données PostgreSQL.
#
# Exemple :
# wt_project_db_name() { echo "myproject_wt_${1//-/_}"; }
wt_project_db_name() {
  echo "myproject_wt_${1//-/_}"
}

# Assure que la base de données par répertoire de travail existe (idempotente).
# Appelée par le moteur lors de l'installation.
# $1: slug du répertoire de travail
# Doit quitter proprement si la BD existe déjà.
#
# Exemple :
# wt_project_db_ensure() {
#   local db; db="$(wt_project_db_name "$1")"
#   docker compose ... exec -T db sh -c \
#     "psql -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname='${db}'\" \
#      | grep -q 1 || createdb -U postgres '${db}'"
# }
wt_project_db_ensure() {
  local db; db="$(wt_project_db_name "$1")"
  # TODO : Implémentez la logique de création de BD pour votre infrastructure
  # Exemple : wt_compose exec -T db createdb -U postgres "$db" 2>/dev/null || true
  return 0
}

# Supprime la base de données par répertoire de travail. Appelée par `clean`.
# $1: slug du répertoire de travail
# Doit quitter proprement si la BD n'existe pas.
#
# Exemple :
# wt_project_db_drop() {
#   local db; db="$(wt_project_db_name "$1")"
#   docker compose ... exec -T db dropdb -U postgres --if-exists "$db"
# }
wt_project_db_drop() {
  local db; db="$(wt_project_db_name "$1")"
  # TODO : Implémentez la logique de suppression de BD pour votre infrastructure
  # Exemple : wt_compose exec -T db dropdb -U postgres --if-exists "$db"
  return 0
}

# Remplit ou provisionne la base de données après la fin de `up`.
# $1: slug du répertoire de travail (disponible si nécessaire)
# Les assistants du moteur wt_compose et $WT_TOPLEVEL sont disponibles ici.
#
# Exemple :
# wt_project_seed() {
#   wt_compose exec -T backend python manage.py seed_data || true
# }
wt_project_seed() {
  local slug="$1"
  # TODO : Implémentez la logique de remplissage (migrations BD, fixtures, données de test, etc.)
  # Exemple : wt_compose exec -T backend ./scripts/seed.sh
  return 0
}

# Configuration supplémentaire YAML d'environnement ou de volume pour un service spécifique.
# Fusionnée dans le compose.override.yaml pour ce service.
# $1: nom du service (ex : « frontend », « backend »)
# $2: slug du répertoire de travail
#
# Exemple :
# wt_project_service_extra() {
#   case "$1" in
#     frontend)
#       echo "    environment:"
#       echo "      VITE_API_URL: \"http://api.$2.localhost/api\""
#       ;;
#     backend)
#       echo "    environment:"
#       echo "      DB_NAME: \"$(wt_project_db_name "$2")\""
#       echo "    volumes: !override"
#       echo "      - ./backend:/app"
#       ;;
#   esac
# }
wt_project_service_extra() {
  local svc="$1" slug="$2"
  case "$svc" in
    # Ajoutez des variables d'environnement ou des volumes spécifiques au service ici
    # Exemple :
    # frontend)
    #   printf '    environment:\n'
    #   printf '      VITE_API_URL: "http://api.%s.localhost/api"\n' "$slug"
    #   ;;
  esac
}

# Affichage élégant des instructions d'accès (URLs, comptes de test, etc).
# Appelée par `up` pour afficher comment accéder aux services en cours d'exécution.
# $1: slug du répertoire de travail
#
# Exemple :
# wt_project_print_access() {
#   echo "Frontend: http://myorg.$1.localhost"
#   echo "API: http://api.$1.localhost/api"
#   echo "Django admin: http://api.$1.localhost/admin"
#   echo "Test accounts (pwd: <mot-de-passe-de-test>): <compte-de-test>"
# }
wt_project_print_access() {
  local slug="$1"
  # TODO : Personnalisez les instructions d'accès pour votre projet
  # Exemple :
  # echo "Frontend: http://<org>.$slug.localhost"
  # echo "API: http://api.$slug.localhost/api"
  return 0
}
