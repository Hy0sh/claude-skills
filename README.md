# claude-skills

Mes skills [Claude Code](https://docs.claude.com/en/docs/claude-code) personnels, packagés en plugin installable.

## Skills inclus

| Skill | Description |
|---|---|
| `review-pr` | Review structurée et actionnable d'une pull request GitHub |
| `wtm` | Usage de [worktree-manager](https://github.com/Hy0sh/worktree-manager) : worktree git avec sa stack Docker isolée, plus les disciplines d'isolation et de preuve runtime |
| `dailysum` | Portion personnelle du daily sum collaboratif (commits du jour, enrichissement PR/Jira) à coller dans Slack |

## Installation

```bash
# Dans Claude Code
/plugin marketplace add Hy0sh/claude-skills
/plugin install hy0sh-skills
```

## Installation manuelle (sans plugin)

Copie les dossiers voulus dans `~/.claude/skills/` :

```bash
cp -R skills/review-pr ~/.claude/skills/
cp -R skills/wtm ~/.claude/skills/
cp -R skills/dailysum ~/.claude/skills/
```

## Structure

```
claude-skills/
├── .claude-plugin/
│   ├── marketplace.json   # déclare le marketplace + le plugin hy0sh-skills
│   └── plugin.json        # métadonnées du plugin
└── skills/
    ├── review-pr/
    │   └── SKILL.md
    ├── wtm/
    │   └── SKILL.md
    └── dailysum/
        └── SKILL.md
```
