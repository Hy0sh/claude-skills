---
name: wtm
description: >
  Use when working, running, testing or visually verifying anything inside a git
  worktree backed by worktree-manager (`wtm`), or when a new isolated worktree is
  needed for a task. `wtm` is a Go CLI that creates a worktree with its own Docker
  Compose stack (remapped ports, separate volumes) and a pre-migrated database dump
  restored in seconds (Postgres, MySQL, MariaDB, MongoDB or SQLite), so parallel
  agents never collide with the main stack or with each other. Covers the worktree
  lifecycle, reaching into the stack, and the
  isolation/runtime-proof disciplines. Invoked as `/wtm setup`, it instead guides
  registering a project in the `wtm` registry, or changing one already there.
argument-hint: [setup]
---

When communicating with the user (questions, status, summaries), write in French.
Keep commands, paths and technical identifiers unchanged.

## Never install anything on your own

`wtm`, its shell completion, Go, Docker: **never install or upgrade any of them
yourself**. If something is missing, print the exact command and ask the user to run
it, then wait. Same rule for `wtm project create`, `wtm project edit` and `wtm project
remove`: they write to the user's global registry, so show the full command and get an
explicit "go ahead" first.

Read-only commands (`wtm --version`, `wtm doctor`, `wtm list`, `wtm backup list`,
`wtm project list`) need no approval.

## Modes

- **`/wtm setup`** (argument `setup`) → follow the **"Setup mode"** section at the
  bottom: interview, then propose the `wtm project create` command. Nothing else.
- **Otherwise** → the sections below: lifecycle, working inside a worktree, and the
  two disciplines.

## When to trigger this skill

- A task needs an isolated workspace (parallel agents, a stack that must not disturb
  the main one) and the project is registered in `wtm`.
- You are already inside a worktree created by `wtm` and need to run, test or observe
  the stack.
- You need runtime proof (screenshot, API response) coming from the worktree's own
  code, not from the shared stack.

## Before anything

```bash
wtm --version     # is the binary there?
wtm doctor        # version, config path, Docker VM memory, build cache, stride and offset
wtm project list  # is this project registered?
```

If `wtm` is missing, hand the user the command and stop:

```bash
GOBIN=$HOME/.local/bin go install github.com/Hy0sh/worktree-manager/cmd/wtm@latest
```

(needs Go >= 1.25; `git` >= 2.31 and Docker Compose v2.24+ are required at runtime.)

`wtm project edit` and the step-by-step registration below need **wtm >= 0.3.0**. The
guardrails this skill relies on land in **0.4.3**: a refresh refuses to publish a dump
of a database the migrations never reached, `doctor` reports port clashes between
projects and the volumes of removed worktrees, and a refused `remove` leaves the stack
running. Three things below need **0.5.0**: `post_create`, the compose environment
`wtm run` sets, and a `remove` that also drops the images its stack built.
`wtm --version` tells you what is installed, `doctor` says when a newer one is
published, and an older binary is the user's to upgrade, not yours.

If the project is not registered, switch to Setup mode rather than improvising.

## Argument disambiguation

Every worktree command accepts `[project] <branch>`. A first argument that names a
registered project is the project; otherwise everything is a branch of the current
directory's project. So `wtm start feat/x` from inside the repo, `wtm start my-app
feat/x` from anywhere.

## Lifecycle

```bash
wtm create feat/my-branch                # worktree + stack, base = the project's own
wtm create my-app feat/my-branch main    # explicit project and base branch
wtm create feat/my-branch --no-start     # prepare the worktree, leave the stack down
wtm create feat/pushed-by-someone-else   # same command to pick up a remote branch

wtm list                                 # INDEX / BRANCH / STATUS / PATH
wtm start feat/my-branch                 # bring a stopped stack back up
wtm stop feat/my-branch                  # stop the stack, keep the worktree
wtm remove feat/my-branch                # stack, volumes and built images go, branch kept
wtm remove feat/my-branch --force        # despite modified tracked files
```

A `remove` that finds modified tracked files refuses and leaves everything as it was,
stack included, so the message is not a half-done removal. It happens for real on
projects whose dev server regenerates a tracked file (TanStack Router's
`routeTree.gen.ts`, generated clients): read the listed paths before reaching for
`--force`, since the flag discards those changes.

An existing branch is reused, and the base argument is then ignored. A local branch
is checked out as-is; a branch that only exists on a remote is checked out tracking
it, `create` fetching first in case it was pushed since the last fetch. So do not
`git fetch` and `git branch` by hand before creating a worktree on someone else's
branch: `wtm create <branch>` is the whole thing, and it errors out instead of
guessing when two remotes carry that name. Allocated ports are printed on
`create`/`start`; `wtm list` also reports whether each stack is up, and prints `-`
instead of hanging when Docker is slow or down.

Creation only happens behind the `create` verb. Any unknown word is rejected rather
than silently turned into a branch.

## Working inside a worktree

`exec` and `run` are deliberately distinct.

```bash
# inside the stack's containers
wtm exec feat/my-branch -- python manage.py seed_data
wtm exec feat/my-branch -- bash
wtm exec feat/my-branch --service db -- psql -U postgres

# on the host, with the worktree as working directory, COMPOSE_PROJECT_NAME and
# COMPOSE_FILE pointing at this worktree's stack
wtm run feat/my-branch -- git status
wtm run feat/my-branch -- scripts/some-compose-script.sh
cd $(wtm path feat/my-branch)
```

Always reach the containers through `wtm exec`. The compose project name is derived
from the repository, the worktree index and the branch: internal knowledge, do not
reconstruct it by hand and do not guess container names.

**A fresh worktree needs its own seed.** The dump restores the database as `migrate`
left it (schema, migration table, whatever the migrations create) but never the seed
data, because seeds change often and replay fast. A project with a `post_create`
seeds itself, right after the stack answers; without one, a brand-new stack prints
the reminder once, with the command to run. Run it before concluding the app is
broken.

**Never seed with the project's own reset script.** Those scripts (`reset-dev-db.sh`
and friends) drop the schema and migrate again, which throws away the restored dump
and pays for the migration history wtm exists to skip. Take the seed steps out of it
and run those alone, and if the project keeps hitting this, `post_create` is where the
seed belongs.

**Committing from a worktree.** wtm drops files of its own at the root of the
worktree (`.git-container`, `.db-snapshot`, `.wtm-snapshot.yaml`, `.wtm-ports.yaml`)
and a `.worktrees` directory in the main checkout. Since 0.3.0 they are recorded in
the repository's `.git/info/exclude`, so `git status` stays clean and `git add -A` is
safe. Never add them to the project's `.gitignore`, which is versioned and belongs to
the project, and never delete them to "clean up" a worktree: they are what its stack
mounts. On an older wtm they show up as untracked, so stage explicit paths rather than
everything.

## Discipline §3 — isolation (workflow-rules)

Once a project is managed by `wtm`, the shared stack and the worktree stacks are two
different things and must stay that way.

- **Never** run a bare `docker compose up/down/restart/stop` for a worktree stack
  from your own shell. It addresses a project named after the directory it runs from,
  and it loads neither `.wtm-snapshot.yaml` (the dump) nor `.wtm-ports.yaml` (ports
  written as literals), which wtm hands to docker as extra `-f`. Use `wtm start` /
  `wtm stop`: they also reprovision what the stack mounts and warn about the Docker
  VM's memory. Through `wtm run` those two variables are set, so a script of the
  project reaches the right stack with the right files; that is for the project's own
  scripts, not a way around the lifecycle commands.
- **Never** touch the main repository's stack, another worktree's stack, or a shared
  database, to make your own task pass.
- **Clean up your footprint** at the end of a task: `wtm stop <branch>` when you may
  come back to it, `wtm remove <branch>` when the work is done. Never stop or remove a
  worktree you did not create.
- The dump lives in `~/.config/wtm/backups/` and is shared through a `.db-snapshot`
  symlink, except for a file-based engine (SQLite): there the dump is copied into the
  worktree at the project's `db_path`, and only when nothing is there yet, so a
  database being worked in is never clobbered. Do not edit either by hand;
  `wtm backup refresh` regenerates it.

## Discipline §4 — runtime proof

Green tests do not prove observable behaviour. Before calling anything green:

```bash
# does the container actually see what you just wrote?
wtm exec feat/my-branch -- grep -r "MyNewSymbol" /app | head -3
```

If it does not (stale image, mount missing), stop and diagnose instead of concluding.
Then produce the real observation on the worktree's own remapped ports, taken from
`wtm list` or the `start` output: response body, screenshot, terminal output. Never
observe through the main stack's ports, they serve the other code.

## Troubleshooting

- `wtm doctor` reports the running version and whether a newer one is published,
  Docker VM memory against measured per-stack usage, the size of the build cache, each
  project's stride, offset and engine, the ports two projects would both publish, and
  what removed worktrees left behind: their volumes and the images their stacks built.
  Those volumes matter beyond disk: the index allocator steps over any index docker
  still holds volumes for, so a new worktree lands further out with higher ports.
  `doctor` prints the `docker volume rm` and `docker rmi` lines that drop them, which
  are the user's to run. Before 0.5.0 nothing dropped those images on `remove`, so a
  long-lived machine can have a hundred of them; the build cache is only ever
  reported, since buildkit attributes none of it to a project.
- A port clash between two projects is not something wtm can fix for you: offsets are
  handed out once, at registration. Either the two stacks do not run together, or
  `port_offset` changes in `config.json` and that project's worktrees are recreated.
- A stale dump is never a blocker: `create` says how far behind it is, and the app
  migrates on top of it. `wtm backup refresh <project>` saves the replay.
- Ports are rebased as `20000 + project offset + default port + worktree index *
  stride`. A project already remapping a port on purpose keeps its mapping, and a
  git-tracked `.env` is left alone, so starting a stack never dirties the worktree.

---

## Setup mode (`/wtm setup`)

Goal: produce the right `wtm project create` command for this project, then let the
user run it. Do not run it yourself.

### 1. Frame the project

```bash
git rev-parse --show-toplevel     # from a worktree, resolve the main repository first
wtm project list                  # already registered?
```

The directory has to be a git repository: wtm creates worktrees, and registration is
refused outright rather than failing later, mid-refresh. A checkout whose `.git` was
never created (a source tree downloaded rather than cloned) is not a wtm project.

The registry lives in `~/.config/wtm/config.json` (relocatable via `WTM_CONFIG_DIR`).
An already-registered project is changed with `wtm project edit <name>`, which touches
only the flags it is given. **Never propose `project remove` then `project create` to
change a setting**: that hands out a fresh port offset and forgets the recorded
worktree indices, so every stack already running changes ports and compose project
name.

```bash
wtm project edit my-app --dump --app-service backend   # add the backup to a project
wtm project edit my-app --base main                    # change the base branch
```

### 2. Discover the compose

```bash
docker compose config --format json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print(f\"{s:16} image={v.get('image','-')} ports={[p.get('target') for p in v.get('ports',[])]}\") for s,v in sorted(d['services'].items())]"
```

From the output and the repository, infer: which service is the database (default
`db`), which service runs the migrations (`backend`, `api`, `php-nginx`…), and the
framework's migration command. A project with no compose file works too, there is
simply no stack to start.

Two things to read in that output rather than discover later:

- **The database image.** wtm names the engine from it and only warns when it cannot,
  assuming Postgres. An unrecognised image (a proxy, an internal registry name, a
  variant nobody listed) means passing `--db-engine` explicitly, or the first refresh
  runs `pg_dump` against something else entirely.
- **`container_name:`.** wtm rebases ports, volumes and the compose project name, but
  a pinned container name is none of those, so the main stack and a worktree stack
  cannot both run. Registration warns about it; the fix belongs to the project's
  compose file, and it is worth telling the user before they discover it at the first
  parallel start.

### 3. Interview (AskUserQuestion, only what discovery cannot answer)

- **Base branch** — `main`, `develop`, something else? → `--base`
- **Pre-migrated dump** — worth it when replaying the migration history is slow.
  → `--dump`, plus `--db-service` / `--db-user` if they differ from `db` / `postgres`
- **Migration path** — the service and the commands that must run before the dump is
  taken → `--app-service`, `--deps`, `--migrate`
- **Database wiring** — how does the app learn which database to hit? `{{database}}`
  is replaced by the throwaway database's name → `--env KEY=VALUE`, repeatable. This
  is the setting that most often makes a refresh useless, so read the app's own
  configuration rather than guessing the variable name: map the very one the compose
  service already sets (`DATABASE_URL`, `DB_NAME`, `MONGO_URL`…), password and all,
  with only the database name replaced by `{{database}}`. Get it wrong and the
  migrations run against the project's real database while the throwaway one stays
  empty; since 0.4.3 the refresh fails there instead of publishing an empty dump, and
  the fix is always this mapping
- **Git-dir bind-mount** — only if the compose mounts the git-dir into a container
  → `--git-container`, otherwise leave it off, it creates nothing
- **Seed of a fresh worktree** — the command that makes a restored database usable
  (`manage.py seed_data`, a dev-users command…), played in the application service
  once the database answers → `--post-create`. Ask for the seed steps only: a script
  that resets the database undoes the restore

### 4. Present the command, do not run it

```bash
wtm project create my-app --dir ~/dev/projects/my-app --base develop \
  --dump --app-service backend \
  --deps 'poetry install --no-root --with dev' \
  --migrate 'python manage.py migrate' \
  --env 'DB_NAME={{database}}' \
  --post-create 'python manage.py create_dev_users'
```

Hand over the full command: the interview is done, and a command the user can read
beats a walk they have to answer. Mention that `wtm project create my-app` alone
would ask the same things one question at a time (services read from the compose
file, current values as defaults), which is the way out when the interview left
something unsettled. Both are theirs to run: the walk waits on their answers, so
never start it yourself.

Explain what it writes, then wait. Once the user has run it, the follow-up is
`wtm backup refresh my-app` (starts the stack if needed) and `wtm doctor` to confirm
the stride and offset. Both are theirs to launch too, `refresh` being long and
stack-mutating.

Only pass the flags the interview actually justified. A project without a dump needs
none of the backup flags.
