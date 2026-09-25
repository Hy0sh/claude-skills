# claude-skills

Mes skills [Claude Code](https://docs.claude.com/en/docs/claude-code) personnels, packagés en plugin installable.

## Skills inclus

| Skill | Description |
|---|---|
| `review-pr` | Review structurée et actionnable d'une pull request GitHub |
| `wtm` | Usage de [worktree-manager](https://github.com/Hy0sh/worktree-manager) : worktree git avec sa stack Docker isolée, plus les disciplines d'isolation et de preuve runtime |
| `dailysum` | Portion personnelle du daily sum collaboratif (commits du jour, enrichissement PR/Jira) à coller dans Slack |
| `veille-pr` | État de mes PR ouvertes en une passe (conflits, CI, fils de review non résolus, piles), puis liste d'actions ordonnée. Lecture seule |
| `pr-review-slack` | Annonce d'une PR sur le canal Slack du projet pour demander une review. La table repo → canal vit dans `~/.config/hy0sh-skills/slack-channels.json` |

Le plugin installe aussi trois hooks : le chargement de la skill `wtm` à l'ouverture
d'une session dans un projet enregistré, doublé d'un rappel d'adoption quand le
worktree est un que `wtm` ne connaît pas ; un garde-fou qui refuse un `wtm create`
depuis une session isolée par Claude Code, dont les éditions n'atteindraient jamais le
worktree créé, et demande l'accord avant une commande Docker qui viserait la stack du
checkout principal depuis un worktree ; et un `wtm clean -y` détaché en fin de session,
après que Claude Code a supprimé son worktree. Ils sortent sans rien faire hors projet
`wtm`, ou si `wtm`, `jq` ou docker manquent.

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
cp -R skills/veille-pr ~/.claude/skills/
cp -R skills/pr-review-slack ~/.claude/skills/
```

## Structure

```
claude-skills/
├── .claude-plugin/
│   ├── marketplace.json   # déclare le marketplace + le plugin hy0sh-skills
│   └── plugin.json        # métadonnées du plugin
├── hooks/
│   ├── hooks.json         # PreToolUse, SessionStart et SessionEnd
│   ├── wtm-context        # charge la skill wtm, et signale un worktree non adopté
│   ├── wtm-guard          # refuse un `wtm create` depuis une session isolée par Claude
│   │                      # Code, demande l'accord sur un docker qui viserait la mauvaise stack
│   └── wtm-sweep          # `wtm clean -y` quand un worktree disparaît
└── skills/
    ├── review-pr/
    │   └── SKILL.md
    ├── wtm/
    │   └── SKILL.md
    ├── dailysum/
    │   └── SKILL.md
    ├── veille-pr/
    │   └── SKILL.md
    └── pr-review-slack/
        └── SKILL.md
```
