---
name: wtm
description: >
  Use when working, running, testing or visually verifying anything inside a git
  worktree backed by worktree-manager (`wtm`), or when a new isolated worktree is
  needed for a task. `wtm` is a Go CLI that creates a worktree with its own Docker
  Compose stack (remapped ports, separate volumes) and a pre-migrated database dump
  restored in seconds (Postgres, MySQL, MariaDB, MongoDB or SQLite), so parallel
  agents never collide with the main stack or with each other. Covers the worktree
  lifecycle, adopting a worktree another tool cut (`claude --worktree`, `git worktree
  add`), reaching into the stack, and the isolation/runtime-proof disciplines.
  Invoked as `/wtm setup`, it instead guides registering a project in the `wtm`
  registry, or changing one already there.
argument-hint: [setup]
---

When communicating with the user (questions, status, summaries), write in French.
Keep commands, paths and technical identifiers unchanged.

## Never install anything on your own

`wtm`, its shell completion, Go, Docker: **never install or upgrade any of them
yourself**. If something is missing, print the exact command and ask the user to run
it, then wait. Same rule for `wtm project create`, `wtm project edit` and `wtm project
remove`: they write to the user's global registry, so show the full command and get an
explicit "go ahead" first. `wtm backup remove` belongs to the same list: it throws
away the migration history the tool exists not to replay, only a long
`backup refresh` brings it back, and called without an argument it takes the current
directory's project.

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
- You are inside a worktree another tool cut (`claude --worktree` under
  `.claude/worktrees`, a plain `git worktree add`) and the task needs a stack of its
  own: `wtm adopt` gives it one where it stands.
- You need runtime proof (screenshot, API response) coming from the worktree's own
  code, not from the shared stack.

Being in *a* worktree is not the same as being in one wtm knows. Until it is adopted,
a worktree another tool cut has no index, no provisioned `.env`, no stack, and `wtm
list` does not show it. Since **0.10.0** that is a state to leave rather than a dead
end: `wtm adopt` from inside it, and every command below works on it afterwards. On an
older binary it really is a dead end, and the upgrade is the user's to run.

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

(needs Go >= 1.24; `git` >= 2.31 and Docker Compose v2.24+ are required at runtime.)
Without Go, the [latest release](https://github.com/Hy0sh/worktree-manager/releases/latest)
carries a binary per platform (darwin and linux, arm64 and amd64) plus a `SHA256SUMS`;
that download and its move onto the PATH are the user's to run too.

`wtm project edit` and the step-by-step registration below need **wtm >= 0.3.0**, and
the guardrails this skill relies on land in **0.4.3**: a refresh refuses to publish a
dump of a database the migrations never reached, `doctor` reports port clashes between
projects and the volumes of removed worktrees, and a refused `remove` leaves the stack
running. What the sections below describe then arrived version by version:

- **0.5.0** — `post_create`, the compose environment `wtm run` sets, and a `remove`
  that also drops the images its stack built.
- **0.6.0** — `--migrations-path`, without which a project whose migrations live
  outside the default pathspec has its dump called up to date forever.
- **0.7.0** — the wait on the application service before `post_create`, bounded by
  `--ready-timeout` and `--ready-interval`.
- **0.8.0** — `--no-post-create`, `stop --all`, `remove --all`.
- **0.9.0** — `create --run` and `--exec`, and the memory question a create asks when
  it runs on a terminal, with `--ignore-memory` to answer it in advance.
- **0.10.0** — `wtm adopt`, `create --from-here`, and the three `doctor` reports this
  skill leans on for a machine that has drifted: two worktrees of one project fighting
  over a port, recorded indices no worktree stands behind, anonymous volumes nothing
  mounts. A refresh now also stops the database it started for itself, an index whose
  ports clash with a recorded worktree is skipped instead of failing at `docker
  compose up`, and on a native docker the dump is at last readable by the container
  that restores it: before, every worktree on Linux came up on an empty database
  without a word.

`wtm --version` tells you what is installed, `doctor` says when a newer one is
published, and an older binary is the user's to upgrade, not yours.

If the project is not registered, switch to Setup mode rather than improvising.

## Argument disambiguation

Every worktree command accepts `[project] <branch>`. A first argument that names a
registered project is the project; otherwise everything is a branch of the current
directory's project. So `wtm start feat/x` from inside the repo, `wtm start my-app
feat/x` from anywhere. `adopt` is the one whose branch is optional: with none it takes
the worktree of the current directory.

## Lifecycle

```bash
wtm create feat/my-branch                # worktree + stack, base = the project's own
wtm create my-app feat/my-branch main    # explicit project and base branch
wtm create feat/my-branch --no-start     # prepare the worktree, leave the stack down
wtm create feat/pushed-by-someone-else   # same command to pick up a remote branch
wtm create feat/my-branch --no-post-create        # stack up, seed skipped
wtm create feat/my-branch --ignore-memory         # never ask, however tight the RAM
wtm create feat/my-branch --exec 'npm run seed'   # a shell line in the app container
wtm create feat/my-branch --run 'pnpm install'    # a shell line on the host, once ready
wtm create feat/my-branch --from-here    # base = the branch of the current directory

wtm adopt                                # this worktree, wherever another tool cut it
wtm adopt --as feat/my-branch            # renaming the branch on the way in
wtm adopt my-app worktree-curry -y       # named from anywhere, nothing asked

wtm list                                 # INDEX / BRANCH / STATUS / PATH
wtm start feat/my-branch                 # bring a stopped stack back up
wtm stop feat/my-branch                  # stop the stack, keep the worktree
wtm stop --all                           # every worktree of the project
wtm remove feat/my-branch                # stack, volumes and built images go, branch kept
wtm remove feat/my-branch --force        # despite modified tracked files, or a lock
wtm remove --all -y                      # lists them, asks once, -y answers for you
```

`--all` walks every worktree of the project and a failure never stops the walk: the
locked or dirty ones are reported together at the end, with a non-zero exit. It also
takes the whole project, other people's worktrees included, which the isolation
discipline below rules out unless you created them all.

`remove` on an adopted worktree stops at the stack: it takes the containers, volumes
and built images down, takes wtm's own files back out of the checkout, releases the
index, and leaves the directory exactly where it found it. wtm removes what it built,
never a checkout it did not create, so whatever cut that worktree stays the one that
disposes of it.

A `remove` that finds modified tracked files, or a worktree git has locked, refuses
and leaves everything as it was, stack included, so the message is not a half-done
removal. An adopted worktree is spared that check, since nothing of it is deleted and
one being worked in always holds uncommitted work. It happens for real on projects
whose dev server regenerates a tracked file (TanStack Router's `routeTree.gen.ts`,
generated clients): read the listed paths
before reaching for `--force`, since the flag discards those changes.

The base is resolved in the main repository, never in the worktree the command was
typed from, so from a worktree on `feat/a` a create starts from the project's base and
not from `feat/a`. `--from-here` is for the other intent: it resolves the branch of
the current directory and cuts from it. A create also says when the local base it cuts
from trails its remote (`develop is 12 commits behind origin/develop`) and does not
move the cut: unpushed commits on that base would silently be left out.

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

**A create can stop and ask about memory.** Before a stack goes up, wtm measures what
the pool it has to fit into already holds (the containers' own budget under Docker
Desktop, the whole machine on a native Linux docker, session and browser included) and
asks whether to go ahead when one more stack looks like too much. The question only
comes on a terminal, so an agent under one can hang on it: pass `--ignore-memory` when
nobody is there to answer. Answering no leaves the worktree without its stack, which
is what `--no-start` produces, and `wtm start` brings it up later without replaying
the seed.

**Adopting the worktree you are already in.** `wtm adopt` with no argument takes the
worktree of the current directory and gives it what a created one gets: a stable
index, remapped ports, the provisioned `.env` files and compose overrides, the
restored dump and its stack. It stays where it is, which is the point: something is
usually working in that directory, an agent included, and moving it to satisfy a
naming convention would pull the ground from under it. `--as <branch>` renames the
branch on the way in, which is worth it for a `claude --worktree` name nobody chose:
that name is the handle of every later command, and adopting is the only moment the
rename is free, since the branch is part of the compose project name. Adopting asks
before writing into a directory wtm did not create; `-y` answers for a script or an
agent, and without a terminal the command refuses rather than writing unasked. A
worktree on a detached HEAD cannot be adopted: wtm keys a worktree by its branch.

**One worktree, one branch.** wtm keys a worktree by the branch git reports for it,
so switching branches inside one (a `gh pr checkout`, a `git switch`) breaks the pair.
An adopted worktree disappears outright: `wtm list` stops showing it, its recorded
index becomes one `doctor` reports as standing behind nothing, and its stack keeps
running under the old compose project name. A worktree wtm created stays listed but
under the new branch with no index, and `wtm stop <original-branch>` answers `no
worktree for branch`. Reviewing several branches means one worktree each,
`wtm create <branch>` per branch, never a switch inside one.

## The hooks this plugin installs

Three lifecycle hooks ship with the skill, so what follows does not rest on anyone
remembering it.

- `SessionStart` speaks up when the session opens in a worktree wtm does not know:
  no recorded index, no isolated ports, no stack of its own. Tell the user and offer
  `wtm adopt`, which is free until something is built on it.
- `WorktreeRemove` and `SessionEnd` both run `wtm clean -y`. It releases the indices
  no worktree stands behind and drops the volumes and images their stacks left, which
  is what a worktree removed by another tool keeps holding. Needs **wtm >= 0.11.0**
  and a docker that answers; without either it exits without a word, as it does when
  there is nothing to clean.

Neither hook can reach a live worktree: everything they touch is keyed on a branch
git no longer has a checkout for. They are not a replacement for `wtm remove` at the
end of your task, only the net under the worktrees that leave another way.

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

`wtm create --run` and `--exec` reach those same two destinations from the create
itself: `--exec` plays a shell line in the application container, after the project's
`post_create` and whether or not `--no-post-create` skipped it, `--run` plays one on
the host with the same compose environment `wtm run` sets, last of all, once the
addresses have been printed. Both may be given at once. They take a shell line and
not an argv after `--`, so the quoting is yours to get right (a value that is really
a flag is refused up front), and a failure is a warning naming the line that replays
it rather than a failed creation. `--exec` is refused with `--no-start`, having no
stack to enter.

**Both block the `create` until the command exits**, so neither is a way to leave a
dev server running: the stack's own services are already up, and anything else
belongs in a background task. Use them for work that ends (installing dependencies,
loading a fixture, warming a cache). And neither is remembered from one create to
the next: they never reach `config.json`, so for a command every worktree of the
project needs, `post_create` is the place. Weigh what you hand `--run`, though: it
runs on the host with the user's rights, in a checkout of a branch that may not be
theirs, so playing that branch's own scripts in the same line as the create is
exactly as trusting as it sounds. `--exec` is bounded by the container.

Always reach the containers through `wtm exec`. The compose project name is derived
from the repository, the worktree index and the branch: internal knowledge, do not
reconstruct it by hand and do not guess container names.

**A fresh worktree needs its own seed.** The dump restores the database as `migrate`
left it (schema, migration table, whatever the migrations create) but never the seed
data, because seeds change often and replay fast. A project with a `post_create`
seeds itself; without one, a brand-new stack prints the reminder once, with the
command to run. Run it before concluding the app is broken. `--no-post-create` skips
that seed for one worktree, for a branch opened to read rather than to work in, and
prints the `wtm exec` line that plays it later.

`post_create` does not run as soon as docker says the containers started: wtm waits
for the database, then for the application service to report itself healthy through
its `healthcheck:`, or through its first published port read inside the container
when it declares none. A stack installing its dependencies from its `command:`
answers minutes later, which is what that wait is for, and a wait that holds says so
every thirty seconds. A timeout is not a failed creation: the worktree stands and the
warning names the `wtm exec` line that replays the command. A service with neither a
healthcheck nor a published port leaves nothing to wait for, and the warning saying
so points at `project edit --app-service`, the setting that decides where the command
runs.

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
mounts. On an adopted worktree `wtm remove` takes them back out itself, the port block
in `.env` included, so the checkout is left as it was found. On an older wtm they show
up as untracked, so stage explicit paths rather than everything.

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
  worktree you did not create. Adopting is the one thing you may do to a worktree you
  did not cut, and only the one you are working in: it adds a stack and takes nothing
  away, and its `remove` leaves the checkout to whatever created it.
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
  project's stride, offset and engine, the ports two projects would both publish, the
  ports two worktrees of one project would both publish, the recorded indices no
  worktree stands behind, the anonymous volumes nothing mounts, and what removed
  worktrees left behind: their volumes and the images their stacks built.
  Those volumes matter beyond disk: the index allocator steps over any index docker
  still holds volumes for, so a new worktree lands further out with higher ports.
  `doctor` prints the `docker volume rm` and `docker rmi` lines that drop them, which
  are the user's to run. Before 0.5.0 nothing dropped those images on `remove`, so a
  long-lived machine can have a hundred of them; the build cache is only ever
  reported, since buildkit attributes none of it to a project.
- A port clash between two projects is not something wtm can fix for you: offsets are
  handed out once, at registration. Either the two stacks do not run together, or
  `port_offset` changes in `config.json` and that project's worktrees are recreated.
  Between two worktrees of one project it is handled: since 0.10.0 the allocator skips
  an index whose ports a recorded worktree already publishes and says so (`index 2
  skipped: db would publish 26434, which feat/a already publishes for db_test`), which
  happens whenever two services sit closer together than the stride, `db` on 5432 and
  `db_test` on 5433 being the common shape. Worktrees recorded before that can still
  overlap, and `doctor` names them with the `portStride` remedy.
- An index recorded for a branch with no worktree pushes every new worktree one
  further out, and makes a foreign worktree on that branch read as adopted. They come
  from removals made outside `wtm remove`; `doctor` lists them with the `wtm remove
  <project> <branch>` that releases each, which also takes down whatever stack was
  left at that index.
- A stale dump is never a blocker: `create` says how far behind it is, and the app
  migrates on top of it. `wtm backup refresh <project>` saves the replay. A dump
  reported as up to date forever means `migrations_path` does not match the project's
  layout, not that nothing moved.
- A worktree missing one of the files its stack mounts fails deep inside docker on a
  raw mount error. Every `start` lays the links, the `*.env` copies and the compose
  overrides back down, so that is the repair; what the worktree already holds is left
  alone, an env file tweaked for the task being its own state rather than a stale
  copy.
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
  runs `pg_dump` against something else entirely. A project on SQLite has no database
  service to read at all, so it is chosen by hand with `--db-engine sqlite`, and its
  snapshot is collected through the application service's bind mount: that service
  has to mount the project directory, otherwise there is nothing to collect from.
- **`container_name:`.** wtm rebases ports, volumes and the compose project name, but
  a pinned container name is none of those, so the main stack and a worktree stack
  cannot both run. Registration warns about it; the fix belongs to the project's
  compose file, and it is worth telling the user before they discover it at the first
  parallel start.

### 3. Interview (AskUserQuestion, only what discovery cannot answer)

- **Base branch** — `main`, `develop`, something else? → `--base`, but only when the
  project really branches off something else: an empty answer records nothing and
  follows `default_base_branch` from `config.json`, then `develop`
- **Pre-migrated dump** — worth it when replaying the migration history is slow.
  → `--dump`, plus `--db-service` / `--db-user` if they differ from `db` / `postgres`
- **Migration path** — the service and the commands that must run before the dump is
  taken → `--app-service`, `--deps`, `--migrate`
- **Where the migration files live** — only asked because the default pathspec
  matches Django, Prisma and MikroORM and nothing else: a Rails (`db/migrate/*`) or
  Flyway layout needs `--migrations-path`, or no commit ever touches the pathspec and
  the dump reads as up to date forever
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
  once the database answers and that service reports itself healthy → `--post-create`.
  Ask for the seed steps only: a script that resets the database undoes the restore
- **How slowly the stack boots** — only for a project whose services install their
  dependencies at startup and outlast the built-in bounds (a minute for the database,
  ten for the application) → `--ready-timeout`, `--ready-interval`

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
something unsettled. `--no-input` is the opposite end: a missing value becomes an
error instead of a question, which is what keeps a scripted registration from
hanging on a prompt nobody reads. Both are theirs to run: the walk waits on their
answers, so never start it yourself.

Explain what it writes, then wait. Once the user has run it, the follow-up is
`wtm backup refresh my-app` (starts the database if it is down, and puts it back
where it found it afterwards) and `wtm doctor` to confirm the stride and offset. Both
are theirs to launch too, `refresh` being long and stack-mutating.

Only pass the flags the interview actually justified. A project without a dump needs
none of the backup flags.
