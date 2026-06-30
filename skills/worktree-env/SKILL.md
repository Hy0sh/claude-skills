---
name: worktree-env
description: >
  Use when running, testing, or visually verifying a Docker Compose stack from
  inside a git worktree (created by `claude -w` or `git worktree add`). Provides
  an isolated Compose environment per worktree — separate containers, volumes
  (DB included), and ports — so agents cannot collide with the shared principal
  stack or with each other. Project-agnostic: services and ports are
  auto-discovered from the project's compose file; project-specific behaviour
  (seeding, caches, env vars, access output) lives in an optional config file.
  Invoked as `/worktree-env setup`, it instead guides creating that per-project config.
---

## Modes

- **`/worktree-env setup`** (argument `setup`) → suis la section **« Mode setup »** en bas :
  entretien guidé pour créer/réviser la config par projet. N'exécute rien d'autre.
- **Sinon** (run/test/observe) → suis les sections ci-dessous (usage du script + disciplines).

## Quand déclencher ce skill

- Tu es dans un git worktree (le toplevel n'est pas le repo principal) **et** tu
  dois démarrer, tester, ou observer un stack Docker Compose.
- Tu dois faire une preuve visuelle (screenshot, réponse d'API) depuis le code
  du worktree (cf. §11 de workflow-rules).
- Tu veux vérifier que tes modifications sont bien vues par les conteneurs avant
  de déclarer « vert ».

## Comment utiliser le script

Le script `worktree-env.sh` est dans `~/.claude/skills/worktree-env/`. Lance-le
depuis n'importe quel répertoire **à l'intérieur** du worktree :

```bash
# Démarrer le stack (services par défaut, ou tous si aucune config)
~/.claude/skills/worktree-env/worktree-env.sh up

# Démarrer uniquement certains services
~/.claude/skills/worktree-env/worktree-env.sh up db backend

# Voir les stacks worktree actifs et leurs ports
~/.claude/skills/worktree-env/worktree-env.sh status

# Arrêter et supprimer le stack du worktree courant (volumes inclus)
~/.claude/skills/worktree-env/worktree-env.sh down

# Forcer le nettoyage du worktree COURANT : conteneurs + volumes + fantômes
# laissés par un up qui a échoué (scopé au worktree courant uniquement)
~/.claude/skills/worktree-env/worktree-env.sh clean
```

Le premier `up` :
- nomme le projet Compose `<basename-repo-principal>-wt-<slug-worktree>` ;
- alloue un bloc de ports libre (`block_base = WT_BASE_START + WT_BLOCK_SIZE*k`,
  défauts `20000` / `20`) ;
- **auto-découvre** les services, leurs `container_name` codés en dur et leurs
  ports via `docker compose -f <base> config --format json` ;
- génère deux fichiers dans le toplevel (gitignorés) : `.env.worktree`
  (`COMPOSE_PROJECT_NAME`, `WT_BLOCK`) et `compose.override.yaml`
  (container_name re-dérivés en `${COMPOSE_PROJECT_NAME}-<svc>`, ports remappés).

Les URLs résolues sont affichées au `up`. Les indices de port suivent l'ordre
alphabétique de découverte (déterministe) — donc **pas** un `+1/+2` fixe.

## Config par projet (optionnelle)

Un projet peut poser une config gitignorée à `<repo>/.claude/worktree-env.conf.sh`
(sourcée côté hôte, jamais copiée dans le worktree). Sans elle, le `up` marche en
auto-mapping brut. Avec elle, on personnalise :

- variables : `WT_PROJECT_PREFIX`, `WT_BLOCK_SIZE`, `WT_BASE_START`,
  `WT_DEFAULT_SERVICES`, `WT_ENV_FILES` (fichiers provisionnés depuis le principal) ;
- hooks : `wt_project_service_extra <svc> <bbase>` (YAML extra par service, ex.
  `VITE_API_URL`), `wt_project_volumes` (volumes top-level), `wt_project_post_up
  <bbase>` (seed après `up`), `wt_project_print_access <bbase>` (sortie d'accès).

Dans un hook, `wt_host_port_for <svc> <container_port>` rend le port hôte assigné.
Modèle complet documenté : `~/.claude/skills/worktree-env/worktree-env.conf.example.sh`.

## Discipline §10 — isolation stricte (workflow-rules)

- **Ne jamais** toucher le stack partagé du repo principal :
  `docker compose restart/stop/up/down` sans `--env-file .env.worktree` est
  interdit. Utilise uniquement les commandes ci-dessus.
- **Ne jamais** muter la DB partagée. Les volumes du worktree sont distincts
  (préfixés par `<repo>-wt-<slug>_`) ; les caches partagés à nom fixe survivent
  au `clean`.
- **Nettoie ton empreinte** en fin de tâche : `down` (teardown propre) ou `clean`
  (force + ramasse les fantômes d'un up échoué) — les deux scopés au worktree
  courant, jamais aux autres.

## Discipline §11 — preuve de fonctionnement runtime

Avant de déclarer un comportement « vert », vérifie que le conteneur voit bien
tes modifications :

```bash
# Confirmer qu'un symbole fraîchement écrit est présent dans le conteneur
docker exec <projet>-backend grep -r "MonNouveauSymbole" /app/ | head -3
```

Si le conteneur ne voit pas tes éditions (volume non monté, image stale),
arrête-toi et diagnostique avant de conclure. Les tests verts ne suffisent pas
pour une tâche à comportement observable — fournis un screenshot, un corps de
réponse, ou une sortie terminal issue de la vraie surface.

---

## Mode setup (`/worktree-env setup`)

Déclenché quand le skill est invoqué avec l'argument `setup`. Objectif : créer ou
réviser la config par projet `<repo-principal>/.claude/worktree-env.conf.sh`.

Le moteur auto-découvre services, ports et `container_name`. **La plupart des
projets n'ont besoin d'aucune config** : un simple `up` marche en auto-mapping.
La config ne sert qu'aux besoins non devinables. Conduis un court entretien, puis
n'écris **que** les hooks/variables réellement nécessaires. KISS — si rien n'est
requis, dis-le et n'écris pas de fichier.

### 1. Cadrer le projet
- Résous le repo principal : `git rev-parse --show-toplevel` puis remonte au
  `--git-common-dir` si tu es dans un worktree. La config vit à
  `<repo-principal>/.claude/worktree-env.conf.sh`.
- Si une config existe déjà, lis-la et propose de la **réviser** plutôt que d'écraser.

### 2. Montrer ce qui est déjà auto-géré
Lance la découverte pour que l'utilisateur voie ce qui ne nécessite **aucune** config :

```bash
BASE=$(for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do [ -f "$f" ] && echo "$f" && break; done)
docker compose -f "$BASE" config --format json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print(f\"{s:16} cname={v.get('container_name','-')} ports={[p.get('target') for p in v.get('ports',[])]}\") for s,v in sorted(d['services'].items())]"
```

Si `docker compose config` échoue (env_file manquant), c'est déjà un signal :
il faudra `WT_ENV_FILES`.

### 3. Interviewer sur les extras (AskUserQuestion, ciblé)
Ne pose que les questions pertinentes au vu de la découverte. Couvre :

- **Env files à provisionner** — fichiers gitignorés que Compose monte dans les
  conteneurs (ex. `backend/.env`) et qui manquent dans un worktree frais. →
  `WT_ENV_FILES=(...)`.
- **Services par défaut** — restreindre le `up` sans argument à un sous-ensemble ?
  Sinon tous les services découverts démarrent. → `WT_DEFAULT_SERVICES=(...)`.
- **Env spéciale par service** — un service a-t-il besoin de l'URL/port d'un autre
  (ex. front `VITE_API_URL` → port backend) ? → hook `wt_project_service_extra`,
  via `wt_host_port_for <svc> <container_port>`.
- **Caches partagés / volumes isolés** — caches deps (poetry/yarn/pip/npm) à
  mutualiser entre worktrees (volume à `name:` fixe), ou répertoire à isoler par
  worktree (ex. `node_modules`, volume sans `name:`) ? → `wt_project_service_extra`
  + `wt_project_volumes`. Mentionne aussi tout bind-mount du compose à retirer en
  worktree (ex. `.git`) via `volumes: !override`.
- **Bootstrap après up** — seed / création de comptes / migration à lancer une fois
  le stack prêt ? → hook `wt_project_post_up`. Il dispose de `wt_compose` et
  `$WT_TOPLEVEL`, doit être **idempotent** et ne **jamais** toucher de DB partagée.
- **Sortie d'accès** — afficher des URLs labellisées + comptes de test au `up` ?
  → hook `wt_project_print_access`. Sinon le moteur liste les URLs brutes.

### 4. Écrire la config
- Pars du modèle commenté `~/.claude/skills/worktree-env/worktree-env.conf.example.sh`.
- N'inclus **que** ce qui a été demandé — supprime les hooks non utilisés. Pas de
  scaffolding spéculatif. Commentaires en anglais.
- Écris dans `<repo-principal>/.claude/worktree-env.conf.sh`.

### 5. Gitignorer + vérifier
```bash
grep -qxF '/.claude/worktree-env.conf.sh' .git/info/exclude 2>/dev/null \
  || printf '/.claude/worktree-env.conf.sh\n' >> .git/info/exclude
git check-ignore .claude/worktree-env.conf.sh        # doit afficher le chemin
bash -n .claude/worktree-env.conf.sh && echo "syntax OK"
```

Preuve rapide optionnelle (sans démarrer de conteneurs), depuis un worktree —
`bash -c 'cd <worktree>; source ~/.claude/skills/worktree-env/worktree-env.sh; wt_ensure_env; cat compose.override.yaml'` —
puis indique la commande finale : `worktree-env.sh up`.

**À éviter** : sur-configurer (si la découverte suffit, n'écris rien) ; hardcoder
des ports (toujours `wt_host_port_for` dans les hooks — les indices suivent l'ordre
alphabétique de découverte, pas un `+1/+2`) ; committer la config (gitignorée).
