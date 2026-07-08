# Mode "lane partagée + file d'attente" pour worktree-env

Date : 2026-07-08
Statut : validé, prêt pour plan d'implémentation

## Contexte et objectif

Le mode par défaut de `worktree-env` isole chaque worktree avec son propre
jeu complet de containers, volumes et ports (allocation par bloc). Sur des
projets à stack Docker Compose lourde (ex. gallia-utopia : ~9 services dont
plusieurs images buildées séparément), lancer plusieurs worktrees en
parallèle sature rapidement le CPU/RAM de la machine — le parallélisme
recherché est déjà quasi impossible en pratique dès 2-3 worktrees actifs.

Objectif : un **nouveau mode**, à côté du mode isolé existant (non
remplacé), où un unique jeu de containers applicatifs ("lane") est partagé
entre tous les worktrees d'un même repo, arbitré par une file d'attente à
une place. Les données restent isolées par worktree (DB logique, bucket),
et les services d'infra lourds (DB, stockage objet, mailcatcher...) restent
up en continu au lieu d'être dupliqués.

Contrainte dure : rien de spécifique à un projet ne doit être committé dans
le repo de ce projet (ex. gallia-utopia). Le mécanisme générique vit dans ce
repo (`claude-skills`) ; la configuration propre à un projet vit dans le
fichier de config déjà gitignoré du projet
(`<repo>/.claude/worktree-env.conf.sh`).

## Non-objectifs

- Ne remplace pas le mode isolé actuel : les deux coexistent, le projet
  choisit lequel utiliser (ou les deux, selon la situation).
- Pas de vrai parallélisme : une seule lane active à la fois (décision
  volontaire — le parallélisme est déjà quasi nul en pratique aujourd'hui ;
  une file simple et fiable vaut mieux qu'un pool de lanes à dimensionner).
- Pas de garantie de service sur le daemon de file : c'est un outil dev
  local, pas un système distribué à tolérance de panne.

## Architecture

```
                    ┌─────────────────────────────┐
                    │   Infra partagée (up en      │
                    │   continu, jamais swap)       │
                    │   db, rustfs, mailhog, ...    │
                    └───────────────┬───────────────┘
                                    │ réseau compose partagé
                    ┌───────────────▼───────────────┐
                    │   Lane applicative             │
                    │   backend, celery_worker,      │
                    │   celery_beat, frontend         │
                    │   (bind-mount = worktree        │
                    │    détenteur courant)           │
                    └───────────────▲───────────────┘
                                    │ up/down piloté par
                    ┌───────────────┴───────────────┐
                    │   worktree-env.sh (CLI)        │
                    │   claim / release / status      │
                    └───────────────▲───────────────┘
                                    │ HTTP local (claim/heartbeat/release)
                    ┌───────────────┴───────────────┐
                    │   Daemon de file (queue_daemon) │
                    │   état: détenteur + file FIFO    │
                    │   par repo, persisté sur disque   │
                    └─────────────────────────────────┘
```

### Composants

**Daemon de file (`queue_daemon`)**
Petit process (Python asyncio ou Node), un par machine, avec son propre
`compose.queue.yaml` — tous deux dans `claude-skills/skills/worktree-env/`,
jamais dans un repo projet. Ne touche jamais Docker. État en mémoire +
persistance disque (fichier JSON) : pour chaque repo (clé = nom du repo
principal), le détenteur courant (worktree, mode, horodatage dernier
heartbeat) et la file d'attente FIFO des demandeurs bloqués.

API HTTP locale (`127.0.0.1:<port fixe>`, non exposée) :
- `POST /claim {repo, worktree, mode}` — bloque (long-poll) jusqu'à
  attribution ; répond `{granted: true}` une fois la lane obtenue.
- `POST /heartbeat {repo, worktree}` — rafraîchit l'horodatage d'activité
  (mode `interactive` uniquement).
- `POST /release {repo, worktree}` — libère explicitement.
- `GET /status?repo=...` — détenteur courant + file d'attente, pour
  diagnostic humain.

Démarré/arrêté via `worktree-env.sh queue up` / `queue down` (une fois par
machine, indépendant de tout worktree particulier).

**Moteur (`worktree-env.sh`, nouvelles sous-commandes)**
- `claim [--mode test|interactive]` — appelle `/claim`, bloque jusqu'à
  obtenir la lane, puis : s'assure que la DB logique et le bucket du
  worktree existent (les crée sinon), régénère `compose.override.yaml`
  pour que les services de `WT_SHARED_LANE_SERVICES` bind-montent le
  worktree courant, lance `docker compose up -d` sur ces services. Pas de
  calcul de bloc de ports (une seule lane active à la fois) : les ports
  fixes du compose de base suffisent.
- `release` — `docker compose down` sur la lane, puis `POST /release`.
- `status` (étendu) — inclut l'état de la file si le projet est configuré
  en mode partagé.
- En mode `interactive`, un heartbeat périodique (défaut 60 s) tourne en
  tâche de fond tant que le processus `claim` vit ; en mode `test`, aucun
  heartbeat, la CLI enchaîne directement l'exécution de la commande de test
  fournie puis relâche.

**Conf projet (`<repo>/.claude/worktree-env.conf.sh`, gitignorée — inchangée
dans son mécanisme, deux nouvelles variables optionnelles)**
- `WT_SHARED_INFRA_SERVICES=(db rustfs mailhog pgadmin kubectl)` — démarrés
  une fois pour la machine (`worktree-env.sh up` sans `claim`), jamais
  arrêtés/swap tant qu'on travaille sur le repo.
- `WT_SHARED_LANE_SERVICES=(backend celery_worker celery_beat frontend)` —
  bind-montés dynamiquement sur le worktree détenteur par `claim`.
- Convention de nommage DB/bucket par défaut, générique :
  `${WT_PROJECT_PREFIX}_<worktree-slug>` (ex. `gallia-wt_jazzy-dazzling-dragon`
  pour la DB, même schéma pour le bucket) ; overridable via un hook
  `wt_project_shared_resource_name <kind> <slug>` si un projet a une
  convention différente.

## Flux

**Mode interactif**
1. `worktree-env.sh claim --mode interactive` (depuis le worktree) → bloque
   jusqu'à obtention de la lane.
2. Accordée → DB/bucket du worktree créés si absents, `compose.override.yaml`
   régénéré, `docker compose up -d` sur `WT_SHARED_LANE_SERVICES`.
3. Heartbeat toutes les 60 s tant que le process vit.
4. `worktree-env.sh release` (explicite) ou timeout d'inactivité (défaut
   45 min sans heartbeat, configurable via `WT_SHARED_IDLE_TIMEOUT`) →
   `docker compose down` sur la lane, `POST /release`, attribution au
   suivant en file.

**Mode test**
1. `worktree-env.sh claim --mode test -- <commande de test>` → même
   acquisition.
2. Accordée → mêmes étapes de préparation, `up -d`, puis exécution directe
   de `<commande de test>` (ex. `docker compose exec backend python
   manage.py test ...`), capture logs + code de sortie.
3. `docker compose down` + libération automatique, pas de heartbeat.

## Isolation et persistance des données

- DB logique et bucket nommés par slug de worktree, créés à la première
  demande, **conservés** entre créneaux (comportement identique au mode
  isolé actuel — juste porté sur une instance Postgres/rustfs partagée au
  lieu d'une instance dédiée).
- Nettoyage accroché à `worktree-env.sh clean`/suppression du worktree :
  DROP de la DB logique, suppression du bucket, et libération de la lane
  si ce worktree la détenait au moment du nettoyage.
- Mailhog reste une boîte partagée non namespacée par worktree — compromis
  accepté, pas d'isolation nécessaire pour de l'email de test.

## Gestion des erreurs

- `docker compose up` en échec (build cassé, migration en échec) : le
  moteur affiche l'erreur et relâche quand même la lane immédiatement —
  jamais de lane bloquée par un stack cassé.
- Crash du daemon : seul `détenteur courant + horodatage` est persisté sur
  disque. Les `claim` en attente perdent leur connexion HTTP et doivent
  relancer la commande — acceptable pour un outil dev interne sans SLA.
- Deux demandes simultanées : sérialisées par un verrou mémoire unique dans
  le process du daemon (un seul thread d'event-loop asyncio traite les
  requêtes `/claim` dans l'ordre de réception) — pas de race possible sur
  l'état de la file.

## Validation

Scénario manuel de recette avant adoption sur gallia-utopia :
1. Deux worktrees réclament la lane à quelques secondes d'écart → vérifier
   l'ordre FIFO d'attribution via `GET /status`.
2. Écrire une donnée distincte dans chaque worktree pendant son créneau →
   vérifier qu'elle est bien isolée (DB logique + bucket propres) à la
   reprise du créneau suivant.
3. Laisser une session `interactive` inactive au-delà du timeout → vérifier
   la libération automatique et l'attribution au suivant sans action
   manuelle.
4. `worktree-env.sh clean` sur un worktree qui détenait la lane → vérifier
   que la lane est libérée et la DB/bucket supprimés.
5. Tuer le daemon en cours de créneau puis le relancer (`queue up`) →
   vérifier qu'il retrouve le détenteur courant depuis l'état persisté.

## Points laissés à l'implémentation (couverts par le plan, pas ce spec)

- Choix technique du langage du daemon (Python vs Node) — trancher selon ce
  qui minimise les dépendances à installer sur la machine hôte.
- Format exact de `compose.queue.yaml` et packaging du daemon (image
  buildée une fois vs script lancé nu).
- Détail du script de génération des bind-mounts dynamiques dans
  `compose.override.yaml` pour la lane (réutilisation vs duplication de la
  logique de génération existante du mode isolé).
