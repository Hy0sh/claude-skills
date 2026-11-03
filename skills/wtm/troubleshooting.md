# wtm troubleshooting

Read when a `wtm` command fails or a stack behaves oddly. The `wtm` skill points here.

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
- A restored worktree whose app data is there but whose accounts are not (logins
  fail, ids point at nothing) keeps them in a second database the dump never held.
  `extra_databases` (see the `wtm-setup` skill) brings it along; the database logs then show one
  `wtm: restoring` line per database, then `restore done`.
- A worktree missing one of the files its stack mounts fails deep inside docker on a
  raw mount error. Every `start` lays the links, the `*.env` copies and the compose
  overrides back down, so that is the repair; what the worktree already holds is left
  alone, an env file tweaked for the task being its own state rather than a stale
  copy.
- Ports are rebased as `20000 + project offset + default port + worktree index *
  stride`. A project already remapping a port on purpose keeps its mapping, and a
  git-tracked `.env` is left alone, so starting a stack never dirties the worktree:
  the port variables then reach compose through the environment of wtm's own calls,
  so a bare `docker compose` misses them. Go through `wtm exec` or `wtm run`, or have
  the user load `eval "$(wtm env)"`: a URL built from `${HTTP_PORT}` otherwise comes
  up without the worktree's port, and CORS or the front's API address breaks.
- A file each developer keeps out of git (`.env.local`, an editor's local settings)
  missing from a worktree: only `*.env` files follow on their own. The project lists
  the others with `wtm project edit <project> --copy <pattern>` (**0.21.0**, repeatable,
  replaces the set); a match git tracks keeps the branch's version.
