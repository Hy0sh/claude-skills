---
name: wtm-setup
description: Use when a project has to be registered in the `wtm` (worktree-manager) registry, or a registered project's settings changed — the base branch, the pre-migrated dump, the migration command, the database wiring, the seed of a fresh worktree. Discovers the compose file, asks only what discovery cannot answer, and hands over the `wtm project create` or `wtm project edit` command for the user to run.
---

When communicating with the user (questions, status, summaries), write in their language.
Keep commands, paths and technical identifiers unchanged.

`wtm project create`, `wtm project edit` and `wtm project remove` write to the user's global registry: show the full command and get an explicit "go ahead" first, never run them yourself. The same goes for installing or upgrading `wtm`, Go or Docker.

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
  → `--dump`, plus `--db-service` if it is not `db`, and `--db-user` for postgres only
  when it is not `postgres` (mysql, mariadb and mongodb connect as root, never read it)
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
- **What the migration command needs besides the database** — only for a
  `migrate_command` that also seeds, and whose seeding talks to object storage, a
  cache or a search index: the refresh runs its throwaway container with `--no-deps`,
  which is right for a plain migration and kills a seeding one (`Object storage is
  unreachable, cannot seed file-backed data`) → `--start-dependencies` (**0.15.0**),
  which brings up what the application service declares in `depends_on` for the time
  of the refresh and takes it back down with it. Off by default
- **A second database the seed writes to** — only when the same Postgres server holds
  another database the app depends on, an identity provider's whose account ids the
  app stores: only `{{database}}` is dumped otherwise, and a restored worktree gets
  ids that point at nothing, so nobody logs in → `--extra-database <name>`,
  repeatable (**1.3.0**, postgres only). Its name is fixed in the compose file, so it
  is dumped as the refresh leaves it on the project's real server: the seed must find
  its accounts already there without failing, and an init script of the project's
  own that creates that database must skip it when it exists, since it runs after
  the restore. Every wtm writing the registry must be 1.3.0 or later: an older one
  drops the field when it saves
- **How slowly the stack boots** — only for a project whose services install their
  dependencies at startup and outlast the built-in bounds (a minute for the database,
  ten for the application) → `--ready-timeout`, `--ready-interval`
- **Local files git leaves out** — what each developer keeps untracked and a worktree
  cannot run without, besides the `*.env` files that follow anyway (`.env.local`, an
  IDE's local settings, a local JSON config) → `--copy <pattern>`, repeatable
  (**0.21.0**). `git status --ignored --short` in the main checkout lists candidates

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
would ask the same things one question at a time, which is the way out when the
interview left something unsettled: since **0.18.0** it offers what the project
already says (database service by its image, `POSTGRES_USER`, the one service with a
`build:`, the framework's migration command, the database variables of the compose
environment), flags a pathspec matching no tracked file, and writes nothing until a
closing summary is confirmed. `--no-input` is the opposite end: a missing value becomes an
error instead of a question, which is what keeps a scripted registration from
hanging on a prompt nobody reads. Both are theirs to run: the walk waits on their
answers, so never start it yourself.

Explain what it writes, then wait. Once the user has run it, the follow-up is
`wtm backup refresh my-app` (starts the database if it is down, and puts it back
where it found it afterwards) and `wtm doctor` to confirm the stride and offset. Both
are theirs to launch too, `refresh` being long and stack-mutating.

Only pass the flags the interview actually justified. A project without a dump needs
none of the backup flags.
