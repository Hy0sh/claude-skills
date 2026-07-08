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

When communicating with the user (setup interview questions, status messages, summaries), write in French. Keep code, paths, and technical identifiers unchanged.

## Modes

- **`/worktree-env setup`** (argument `setup`) → follow the **"Setup mode"** section below:
  guided interview to create/revise the per-project config. Do nothing else.
- **Otherwise** (run/test/observe) → follow the sections below (script usage + disciplines).

## When to trigger this skill

- You are inside a git worktree (the toplevel is not the principal repo) **and** you
  need to start, test, or observe a Docker Compose stack.
- You need to produce a visual proof (screenshot, API response) from the worktree code
  (see §11 of workflow-rules).
- You want to verify that your changes are visible to the containers before
  declaring "green".

## How to use the script

The script `worktree-env.sh` lives in `~/.claude/skills/worktree-env/`. Run it
from any directory **inside** the worktree:

```bash
# Start the stack (default services, or all if no config)
~/.claude/skills/worktree-env/worktree-env.sh up

# Start specific services only
~/.claude/skills/worktree-env/worktree-env.sh up db backend

# List active worktree stacks and their ports
~/.claude/skills/worktree-env/worktree-env.sh status

# Pause the current worktree stack, keep volumes (DB, caches) — use this when
# leaving the worktree idle but intend to resume: no migration replay on next up
~/.claude/skills/worktree-env/worktree-env.sh stop

# Stop and remove the current worktree stack (volumes included)
~/.claude/skills/worktree-env/worktree-env.sh down

# Force-clean the CURRENT worktree: containers + volumes + ghosts
# left by a failed up (scoped to the current worktree only)
~/.claude/skills/worktree-env/worktree-env.sh clean
```

The first `up`:
- names the Compose project `<principal-repo-basename>-wt-<worktree-slug>`;
- allocates a free port block (`block_base = WT_BASE_START + WT_BLOCK_SIZE*k`,
  defaults `20000` / `20`);
- **auto-discovers** services, their hardcoded `container_name` values and their
  ports via `docker compose -f <base> config --format json`;
- generates two files in the toplevel (gitignored): `.env.worktree`
  (`COMPOSE_PROJECT_NAME`, `WT_BLOCK`) and `compose.override.yaml`
  (container_names re-derived as `${COMPOSE_PROJECT_NAME}-<svc>`, ports remapped).

Resolved URLs are printed on `up`. Port indices follow alphabetical discovery order
(deterministic) — so **not** a fixed `+1/+2`.

## Per-project config (optional)

A project may place a gitignored config at `<repo>/.claude/worktree-env.conf.sh`
(sourced host-side, never copied into the worktree). Without it, `up` works with
raw auto-mapping. With it, you can customise:

- variables: `WT_PROJECT_PREFIX`, `WT_BLOCK_SIZE`, `WT_BASE_START`,
  `WT_DEFAULT_SERVICES`, `WT_ENV_FILES` (files provisioned from the principal);
- hooks: `wt_project_service_extra <svc> <bbase>` (extra YAML per service, e.g.
  `VITE_API_URL`), `wt_project_volumes` (top-level volumes), `wt_project_post_up
  <bbase>` (seed after `up`), `wt_project_print_access <bbase>` (access output).

Inside a hook, `wt_host_port_for <svc> <container_port>` returns the assigned host port.
Full annotated template: `~/.claude/skills/worktree-env/worktree-env.conf.example.sh`.

## Mode lane partagée (optionnel, additif)

Alternative au mode isolé par défaut ci-dessus, pour les stacks lourdes (ex.
~9 services dont plusieurs images buildées) où faire tourner plusieurs
worktrees en parallèle sature déjà la machine à 2-3 worktrees actifs. Un seul
jeu de containers applicatifs ("lane") est partagé entre tous les worktrees
du repo, arbitré par une file d'attente à une place (`queue_daemon.py`) — les
deux modes coexistent, un projet choisit celui qui convient (ou les deux).

**Prérequis** : le projet doit définir `WT_SHARED_LANE_SERVICES` dans son
`.claude/worktree-env.conf.sh` (voir `worktree-env.conf.example.sh`). Sans
cette variable, `claim`/`release` refusent de démarrer.

```bash
# Une fois par machine : démarrer le daemon d'arbitrage
~/.claude/skills/worktree-env/worktree-env.sh queue up

# Depuis un worktree : attendre son tour puis obtenir la lane (bloquant)
~/.claude/skills/worktree-env/worktree-env.sh claim --mode interactive
# ... travailler, la lane reste montée sur ce worktree ...
~/.claude/skills/worktree-env/worktree-env.sh release

# Mode test : exécute la commande une fois la lane obtenue, puis relâche
# automatiquement (pas de heartbeat, pas d'action manuelle après)
~/.claude/skills/worktree-env/worktree-env.sh claim --mode test -- \
  docker compose exec backend python manage.py test

# Voir qui détient la lane et qui attend
~/.claude/skills/worktree-env/worktree-env.sh status

# Arrêter le daemon (une fois par machine, quand plus personne n'en a besoin)
~/.claude/skills/worktree-env/worktree-env.sh queue down
```

`claim` bloque jusqu'à obtention (ordre FIFO), puis : crée si besoin la DB
logique et le bucket du worktree (hooks `wt_project_shared_db_ensure` /
`wt_project_shared_bucket_ensure`), régénère `compose.override.lane.yaml`
pour bind-monter `WT_SHARED_LANE_SERVICES` sur le worktree courant, et lance
`up -d` sur les services d'infra + de lane. En mode `interactive`, un
heartbeat tourne en tâche de fond tant que `release` n'a pas été appelé ; sans
heartbeat pendant `WT_SHARED_IDLE_TIMEOUT` (défaut 45 min), la lane est
libérée automatiquement et attribuée au suivant en file, sans action
manuelle. `clean` DROP la DB et le bucket du worktree nettoyé (hooks
`wt_project_shared_db_drop` / `wt_project_shared_bucket_drop`) et libère la
lane si ce worktree la détenait.

## Discipline §10 — strict isolation (workflow-rules)

- **Never** touch the shared stack of the principal repo:
  `docker compose restart/stop/up/down` without `--env-file .env.worktree` is
  forbidden. Use only the commands listed above.
- **Never** mutate the shared DB. Worktree volumes are distinct
  (prefixed with `<repo>-wt-<slug>_`); shared fixed-name caches survive `clean`.
- **Clean up your footprint** at end of task: `stop` (pause, keep volumes — resume
  later without a migration replay), `down` (clean teardown) or `clean` (force +
  collect ghosts from a failed up) — all scoped to the current worktree, never to others.

## Discipline §11 — runtime proof of behaviour

Before declaring a behaviour "green", verify that the container actually sees
your changes:

```bash
# Confirm a freshly written symbol is present in the container
docker exec <project>-backend grep -r "MyNewSymbol" /app/ | head -3
```

If the container does not see your edits (volume not mounted, stale image),
stop and diagnose before concluding. Green tests are not enough for a task with
observable behaviour — provide a screenshot, a response body, or terminal output
from the real surface.

---

## Setup mode (`/worktree-env setup`)

Triggered when the skill is invoked with the argument `setup`. Goal: create or
revise the per-project config `<principal-repo>/.claude/worktree-env.conf.sh`.

The engine auto-discovers services, ports, and `container_name`. **Most projects
need no config at all**: a plain `up` works with auto-mapping. The config only
covers needs that cannot be inferred. Conduct a short interview, then write
**only** the hooks/variables that are actually needed. KISS — if nothing is
required, say so and write no file.

### 1. Frame the project
- Resolve the principal repo: `git rev-parse --show-toplevel` then walk up to
  `--git-common-dir` if inside a worktree. The config lives at
  `<principal-repo>/.claude/worktree-env.conf.sh`.
- If a config already exists, read it and offer to **revise** it rather than overwrite.

### 2. Show what is already auto-managed
Run discovery so the user can see what requires **no** config:

```bash
BASE=$(for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do [ -f "$f" ] && echo "$f" && break; done)
docker compose -f "$BASE" config --format json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print(f\"{s:16} cname={v.get('container_name','-')} ports={[p.get('target') for p in v.get('ports',[])]}\") for s,v in sorted(d['services'].items())]"
```

If `docker compose config` fails (missing env_file), that is already a signal:
`WT_ENV_FILES` will be needed.

### 3. Interview on extras (AskUserQuestion, targeted)
Ask only the questions that are relevant given the discovery output. Cover:

- **Env files to provision** — gitignored files that Compose mounts into containers
  (e.g. `backend/.env`) and that are missing in a fresh worktree. →
  `WT_ENV_FILES=(...)`.
- **Default services** — restrict `up` with no arguments to a subset?
  Otherwise all discovered services start. → `WT_DEFAULT_SERVICES=(...)`.
- **Per-service env** — does a service need the URL/port of another
  (e.g. frontend `VITE_API_URL` → backend port)? → hook `wt_project_service_extra`,
  via `wt_host_port_for <svc> <container_port>`.
- **Shared caches / isolated volumes** — dep caches (poetry/yarn/pip/npm) to share
  across worktrees (volume with a fixed `name:`), or a directory to isolate per
  worktree (e.g. `node_modules`, volume without `name:`)? → `wt_project_service_extra`
  + `wt_project_volumes`. Also mention any compose bind-mounts to drop in worktrees
  (e.g. `.git`) via `volumes: !override`.
- **Bootstrap after up** — seed / account creation / migration to run once the stack
  is ready? → hook `wt_project_post_up`. It has access to `wt_compose` and
  `$WT_TOPLEVEL`, must be **idempotent** and must **never** touch a shared DB.
- **Access output** — display labelled URLs + test accounts on `up`?
  → hook `wt_project_print_access`. Otherwise the engine lists raw URLs.

### 4. Write the config
- Start from the annotated template `~/.claude/skills/worktree-env/worktree-env.conf.example.sh`.
- Include **only** what was asked for — remove unused hooks. No speculative scaffolding.
  Comments in English.
- Write to `<principal-repo>/.claude/worktree-env.conf.sh`.

### 5. Gitignore + verify
```bash
grep -qxF '/.claude/worktree-env.conf.sh' .git/info/exclude 2>/dev/null \
  || printf '/.claude/worktree-env.conf.sh\n' >> .git/info/exclude
git check-ignore .claude/worktree-env.conf.sh        # must print the path
bash -n .claude/worktree-env.conf.sh && echo "syntax OK"
```

Optional quick proof (no containers started), from a worktree —
`bash -c 'cd <worktree>; source ~/.claude/skills/worktree-env/worktree-env.sh; wt_ensure_env; cat compose.override.yaml'` —
then state the final command: `worktree-env.sh up`.

**Avoid**: over-configuring (if discovery is enough, write nothing); hardcoding
ports (always use `wt_host_port_for` inside hooks — indices follow alphabetical
discovery order, not a fixed `+1/+2`); committing the config (it is gitignored).
