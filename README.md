# claude-skills

Mes skills [Claude Code](https://docs.claude.com/en/docs/claude-code) personnels, packagés en plugin installable.

## Skills inclus

| Skill | Description |
|---|---|
| `review-pr` | Review structurée et actionnable d'une pull request GitHub |
| `wtm` | Usage de [worktree-manager](https://github.com/Hy0sh/worktree-manager) : worktree git avec sa stack Docker isolée, plus les disciplines d'isolation et de preuve runtime |
| `dailysum` | Portion personnelle du daily sum collaboratif (commits du jour, enrichissement PR/Jira) à coller dans Slack |

Le plugin installe aussi trois hooks : un rappel d'adoption à l'ouverture d'une
session dans un worktree que `wtm` ne connaît pas, un garde-fou qui demande l'accord
avant une commande Docker qui viserait la stack du checkout principal depuis un
worktree, et un `wtm clean -y` détaché en fin de session, après que Claude Code a
supprimé son worktree. Ils sortent sans rien faire hors worktree, ou si `wtm` ou
docker manquent.

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
├── hooks/
│   ├── hooks.json         # PreToolUse, SessionStart et SessionEnd
│   ├── wtm-adopt-hint     # signale un worktree que wtm ne connaît pas
│   ├── wtm-guard          # demande l'accord sur un docker qui viserait la mauvaise stack
│   └── wtm-sweep          # `wtm clean -y` quand un worktree disparaît
└── skills/
    ├── review-pr/
    │   └── SKILL.md
    ├── wtm/
    │   └── SKILL.md
    └── dailysum/
        └── SKILL.md
```
