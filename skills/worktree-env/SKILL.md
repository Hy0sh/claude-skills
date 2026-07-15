---
name: worktree-env
description: Use when running, testing, or visually previewing a Docker Compose stack from a git worktree (or the principal checkout) while parallel agents work on the same project. Provides one shared infra (DB/storage/mail + Traefik) per machine, ephemeral per-worktree test containers, and named on-demand web previews at <org>.<slug>.localhost — no port collisions, no queue. Invoked as `/worktree-env setup` to create the per-project config.
---

# worktree-env

Isolation runtime pour agents parallèles sur un même projet. Les **worktrees** isolent le filesystem ; **worktree-env** isole le runtime par-dessus (DB/bucket/URL par worktree) tout en mutualisant l'infra.

## Modèle

- **Infra partagée, 1×/machine** : `worktree-env infra up` démarre DB/storage/mail + Traefik (port 80), sous le projet `wtenv-infra-<repo>`, sur le réseau `wtenv-<repo>`.
- **Tests éphémères, N en parallèle** : `worktree-env test -- <cmd>` lance un conteneur jetable (`run --rm`) monté sur le worktree, branché sur l'infra, avec la DB du worktree. Sort et disparaît.
- **Preview à la demande, ≤2** : `worktree-env preview` lève back+front du worktree, imprime `http://<org>.<slug>.localhost`. `worktree-env preview stop` coupe.

## Commandes

| Commande | Effet |
|---|---|
| `infra up` / `infra down` | infra partagée + Traefik |
| `test -- <cmd>` | test éphémère (ex. `test -- python manage.py test --keepdb`) |
| `preview` / `preview stop` | preview web nommée |
| `status` | infra + previews vivantes |
| `clean` | nettoie l'empreinte du worktree courant |

## Symétrie non-worktree

Le repo principal est traité comme un worktree de slug `basename(repo)`. Il utilise les mêmes commandes. **Le vrai parallélisme exige un worktree par agent** (isolation filesystem) : plusieurs agents dans le même checkout se marcheraient dessus sur les fichiers.

## Discipline (rappel §10/§11 de workflow-rules)

- **Ne lance pas `docker compose up|down` nu** quand l'infra tourne : passe par `worktree-env` (le hook de garde le bloque). Si un service partagé est cassé, signale-le, ne le redémarre pas.
- **Preuve runtime (§11)** : avant de dire « vert », prouve que le conteneur voit tes changements (`... exec backend grep -r MonSymbole /app/`) et fournis une observation runtime réelle (screenshot / réponse API) via l'URL de preview, pas seulement des tests verts.

## Setup — adoption par projet (`/worktree-env setup`)

C'est **la** phase d'adoption d'un projet, et le **seul** endroit où l'on touche à la configuration d'un projet cible. Elle est **initiée par l'utilisateur**, exécutée **dans son projet** (idéalement un worktree isolé), en interactif. Le développement du skill ne l'exécute jamais à la place de l'utilisateur.

**Règle dure** : `setup` n'écrit **que** le fichier local gitignoré `.claude/wtenv.conf.sh`. Il ne modifie ni ne commite **jamais** le code du projet — les ajustements runtime sont **proposés** à l'utilisateur, qui les applique lui-même (ou les approuve explicitement).

Déroulé quand l'utilisateur lance `/worktree-env setup` :

1. **Auto-découverte** du compose de base (services, ports conteneur, volumes, bind-mounts).
2. **Interview** pour remplir `.claude/wtenv.conf.sh` (KISS — n'écrire que le nécessaire) :
   - répartition `WT_INFRA_SERVICES` / `WT_PREVIEW_SERVICES` / `WT_TEST_SERVICE` ;
   - service front/api + ports conteneur (`WT_FRONT_SERVICE`/`WT_API_SERVICE`, `WT_FRONT_PORT`/`WT_API_PORT`) ;
   - dérivation du nom de DB par worktree + hooks `wt_project_db_ensure`/`wt_project_db_drop` ;
   - commande de seed (`wt_project_seed`), `WT_ENV_FILES`, sortie d'accès (`wt_project_print_access`).
3. **Proposition** (jamais auto-appliquée) des ajustements runtime que l'app requiert derrière le proxy nommé, que l'utilisateur applique lui-même dans son projet :
   - dev-server front : autoriser les hosts `*.localhost` (p.ex. `allowedHosts`) ;
   - backend : autoriser `.localhost` dans les hosts acceptés ;
   - HMR websocket derrière le proxy si nécessaire.
4. **Écrit** `.claude/wtenv.conf.sh` et l'ajoute à `.git/info/exclude` (fichier local, jamais commité).

Voir `worktree-env.conf.example.sh` pour le template annoté.
