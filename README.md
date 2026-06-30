# claude-skills

Mes skills [Claude Code](https://docs.claude.com/en/docs/claude-code) personnels, packagés en plugin installable.

## Skills inclus

| Skill | Description |
|---|---|
| `review-pr` | Review structurée et actionnable d'une pull request GitHub |
| `worktree-env` | Stack Docker Compose isolée par worktree git (conteneurs, volumes et ports séparés) |

## Installation

```bash
# Dans Claude Code
/plugin marketplace add francois-bouyer/claude-skills
/plugin install fb-skills
```

> Remplace `francois-bouyer/claude-skills` par le chemin réel `owner/repo` une fois le repo poussé sur GitHub.

## Installation manuelle (sans plugin)

Copie les dossiers voulus dans `~/.claude/skills/` :

```bash
cp -R skills/review-pr ~/.claude/skills/
cp -R skills/worktree-env ~/.claude/skills/
```

## Structure

```
claude-skills/
├── .claude-plugin/
│   ├── marketplace.json   # déclare le marketplace + le plugin fb-skills
│   └── plugin.json        # métadonnées du plugin
└── skills/
    ├── review-pr/
    │   └── SKILL.md
    └── worktree-env/
        ├── SKILL.md
        ├── worktree-env.sh
        ├── worktree-env.conf.example.sh
        └── tests.sh
```
