# Rapport Ultra-Complet : oh-my-openagent

> **Projet** : `code-yeongyu/oh-my-openagent` (OmO)
> **Date du rapport** : 30 juin 2026
> **Sources** : Repo GitHub + 4 agents d'analyse en parallèle
> **Stars** : 64,370+ | **Forks** : 5,253+ | **Commits** : 9,898+ (branche `dev`)

---

## Table des matières

1. [Identité du projet](#1-identité-du-projet)
2. [Philosophie fondamentale](#2-philosophie-fondamentale)
3. [Architecture technique](#3-architecture-technique)
4. [Les 11 agents — Documentation exhaustive](#4-les-11-agents--documentation-exhaustive)
5. [Méthodologie complète](#5-méthodologie-complète)
6. [Système de hooks (100+ hooks)](#6-système-de-hooks-100-hooks)
7. [Les 17 outils](#7-les-17-outils)
8. [Les 25+ skills partagés](#8-les-25-skills-partagés)
9. [Catégories de délégation](#9-catégories-de-délégation)
10. [Techniques de prompt engineering](#10-techniques-de-prompt-engineering)
11. [Roadmap multi-harness](#11-roadmap-multi-harness)
12. [Statistiques finales](#12-statistiques-finales)

---

# 1. Identité du projet

| Champ | Valeur |
|-------|--------|
| **Nom npm** | `oh-my-opencode` (aussi publié comme `oh-my-openagent`) |
| **Version** | 4.14.1 |
| **Auteur** | YeonGyu-Kim (code-yeongyu) |
| **Licence** | SUL-1.0 |
| **Langage** | TypeScript (101,946 LOC) |
| **Runtime** | Bun (1.3.12) + Node.js fallback |
| **Type** | Monorepo ESM, 37 packages |
| **Site web** | [omo.dev](https://omo.dev) |

**Description officielle :**

> "The Best AI Agent Harness — Batteries-Included OpenCode Plugin with Multi-Model Orchestration, Parallel Background Agents, and Crafted LSP/AST Tools"

---

# 2. Philosophie fondamentale

## 2.1 Le Manifeste

> "L'intervention humaine pendant le travail agentique est fondamentalement un mauvais signal. Si le système est conçu correctement, l'agent devrait compléter le travail sans avoir besoin que vous le surveilliez."

## 2.2 Les 3 piliers

1. **Multi-modèle sans verrouillage** — Orchestration sur Claude, GPT, Gemini, Kimi, GLM, MiniMax, Z.ai. Le bon cerveau pour la bonne tâche.
2. **Harness complet** — Pas juste un prompt, mais un écosystème : tools, hooks, skills, agents, modes.
3. **Autonomie totale** — L'humain dit ce qu'il veut, puis part. L'agent pense, décide, exécute.

## 2.3 Deux éditions

| Édition | Cible | Portée |
|---------|-------|--------|
| **Ultimate** | OpenCode | 10 agents, 100+ hooks, 17 outils, Team Mode, ultrawork |
| **Light** | Codex CLI | 11 composants portables via `lazycodex-ai` |

---

# 3. Architecture technique

## 3.1 Structure du monorepo (37 packages)

```
oh-my-openagent/
├── packages/
│   ├── omo-opencode/              # Édition Ultimate (plugin OpenCode)
│   │   └── src/
│   │       ├── agents/            # 10 agents intégrés
│   │       ├── cli/               # CLI : install, doctor, run
│   │       ├── config/            # Schémas et loaders
│   │       ├── features/          # Modules de fonctionnalités
│   │       ├── hooks/             # 100+ hooks cycle de vie
│   │       ├── mcp/               # Serveurs MCP intégrés
│   │       ├── plugin/            # Interface plugin OpenCode
│   │       ├── plugin-handlers/   # Handlers cycle de vie
│   │       ├── tools/             # 17 familles d'outils
│   │       └── types/             # Définitions TypeScript
│   │
│   ├── omo-codex/                 # Édition Light (plugin Codex)
│   │   └── plugin/components/     # 11 composants portables
│   │
│   └── 18 packages core :
│       ├── utils/                 # 50+ utilitaires partagés
│       ├── model-core/            # Capacités modèles, alias, garde-fous
│       ├── prompts-core/          # Templates prompts agents
│       ├── rules-engine/          # Moteur injection règles conditionnelles
│       ├── delegate-core/         # Logique délégation sous-agents
│       ├── hashline-core/         # Moteur édition LINE#ID
│       ├── lsp-core/              # Intégration LSP
│       ├── mcp-client-core/       # Gestion connexions MCP
│       ├── mcp-stdio-core/        # Transport stdio MCP
│       ├── git-bash-mcp/          # Serveur MCP Git Bash (Windows)
│       ├── tmux-core/             # Gestion sessions tmux
│       ├── team-core/             # Mode équipe : mailbox, tasklist, worktree
│       ├── telemetry-core/        # Télémétrie anonyme PostHog
│       ├── boulder-state/         # État de tâche pour start-work
│       ├── comment-checker-core/  # Détection commentaires AI slop
│       ├── claude-code-compat-core/ # Compatibilité Claude Code
│       ├── skills-loader-core/    # Découverte et chargement skills
│       ├── agents-md-core/        # Génération fichiers AGENTS.md
│       ├── openclaw-core/         # Intégration framework OpenClaw
│       └── shared-skills/         # 25+ skills partagés
│
└── 12 packages binaires plateforme (darwin/linux/windows × arm64/x64)
```

## 3.2 Dépendances clés

| Package | Version | Usage |
|---------|---------|-------|
| `@opencode-ai/plugin` + `sdk` | 1.15.13 | API plugin OpenCode |
| `@modelcontextprotocol/sdk` | 1.29.0 | Protocole MCP |
| `commander` | 14.0.3 | CLI |
| `zod` | 4.4.3 | Validation schémas (36 fichiers) |
| `@code-yeongyu/comment-checker` | 0.8.0 | Détection AI slop |
| `@opentui/core/solid` | 0.2.16 | Rendu TUI |
| `posthog-node` | 5.34.3 | Télémétrie anonyme |
| `jsonc-parser` | 3.3.1 | Parsing JSONC |
| `picomatch` | 4.0.4 | Glob matching |
| `vscode-jsonrpc` | 8.2.1 | JSON-RPC pour LSP |

**Note importante** : OmO n'utilise PAS LangChain, CrewAI ou AutoGen. Framework d'orchestration propriétaire construit from scratch.

## 3.3 Flux de bootstrap

```
1. Utilisateur : bunx oh-my-openagent install
2. CLI détecte la plateforme, fait l'interview d'abonnement
3. Écrit opencode.json (enregistrement plugin)
4. Configure matrice agent↔modèle
5. Au démarrage OpenCode, plugin chargé via @opencode-ai/plugin
6. createPluginModule() câble : tools, hooks, agents, managers
7. 54+ hooks s'activent sur les événements cycle de vie
8. 10 agents deviennent disponibles pour délégation
```

---

# 4. Les 11 agents — Documentation exhaustive

## 4.1 Vue d'ensemble

| # | Agent | Modèle par défaut | Coût | Catégorie | Mode |
|---|-------|-------------------|------|-----------|------|
| 1 | **Sisyphus** | Claude Opus 4.7 / Kimi K2.6 / GLM 5.1 | EXPENSIVE | Primary | primary |
| 2 | **Hephaestus** | GPT-5.3/5.4/5.5 uniquement | EXPENSIVE | Specialist | primary |
| 3 | **Oracle** | Chaîne de fallback (Opus préféré) | EXPENSIVE | Advisor | subagent |
| 4 | **Librarian** | Chaîne de fallback | CHEAP | Exploration | subagent |
| 5 | **Explore** | Chaîne de fallback | FREE | Exploration | subagent |
| 6 | **Multimodal-Looker** | Chaîne de fallback | CHEAP | Utility | subagent |
| 7 | **Metis** | Chaîne de fallback (Kimi K2.7 spécial) | EXPENSIVE | Advisor | subagent |
| 8 | **Momus** | Chaîne de fallback | EXPENSIVE | Advisor | subagent |
| 9 | **Atlas** | Dynamique (respecte UI) | EXPENSIVE | Advisor (orchestrator) | primary |
| 10 | **Sisyphus-Junior** | `anthropic/claude-sonnet-4-6` | MEDIUM | Utility | subagent |
| 11 | **Prometheus** | Dynamique | — | Planner | subagent |

## 4.2 SISYPHUS — L'Orchestrateur Principal

**Rôle** : Agent principal par défaut. Tout commence ici.

**Identité** : "SF Bay Area engineer. Work, delegate, verify, ship. No AI slop."

**Pourquoi "Sisyphus" ?** : "Humans roll their boulder every day. So do you. We're not so different."

**9 variantes de prompt par modèle** :
- `default.ts` (Claude, 545 lignes) — Base complète
- `claude-opus-4-7.ts` — Tuning instructions littérales
- `claude-opus-4-8.ts` — Silence default + autonomie
- `claude-fable-5.ts` — Top tier
- `gemini.ts` — Overlays correctifs
- `gpt-5-4.ts` — Architecture 8 blocs
- `gpt-5-5.ts` — Sections style Codex
- `glm-5-2.ts` — Calibration GLM
- `kimi-k2-6.ts` — Calibration Kimi

**Structure du prompt par phases** :

```
Phase 0 — Intent Gate (CHAQUE message)
  Étape 0 : Verbaliser l'intent
  Étape 1 : Classifier (Trivial/Explicit/Exploratory/Open-ended/Ambiguous)
  Étape 2 : Vérifier ambiguïté
  Étape 3 : Valider AVANT d'agir (Délégation Check OBLIGATOIRE)

Phase 1 — Évaluation Codebase
  Disciplined/Transitional/Legacy/Greenfield

Phase 2A — Exploration & Recherche
  Tool selection table, parallel execution (2-5 agents simultanés)

Phase 2B — Implémentation
  Todos, délégation par catégorie, structure 6 sections

Phase 2C — Récupération sur échec
  Après 3 échecs consécutifs : STOP, REVERT, DOCUMENT, ORACLE, USER

Phase 3 — Complétion
  Todos ✓, diagnostics clean, build ✓, demande originale adressée
```

**Structure de délégation 6 sections (obligatoire)** :
1. **TASK** — Objectif atomique et spécifique
2. **EXPECTED OUTCOME** — Livrables concrets + critères de succès
3. **REQUIRED TOOLS** — Liste blanche explicite
4. **MUST DO** — Exigences exhaustives
5. **MUST NOT DO** — Actions interdites
6. **CONTEXT** — Chemins fichiers, patterns, contraintes

**Continuité de session** : Usage obligatoire des IDs de continuation `ses_...`

## 4.3 HEPHAESTUS — L'Ouvrier Autonome Profond

**Rôle** : GPT-spécifique, travaux profonds autonomes sans arrêt prématuré.

**Identité** : "Senior Staff Engineer. You do not guess. You verify. You do not stop early. You complete."

**Mantra** : "KEEP GOING. SOLVE PROBLEMS. ASK ONLY WHEN TRULY IMPOSSIBLE."

**Interdictions** :
- "Should I proceed with X?" → JUST DO IT
- "Do you want me to run tests?" → RUN THEM
- Arrêt après implémentation partielle → 100% OR NOTHING

**Mantras CORRECTS** :
- Continuer jusqu'à COMPLET
- Vérification (lint, tests, build) SANS demander
- Décider. Corriger seulement sur échec CONCRET

**Permissions** :
```typescript
permission: {
  question: "allow",
  call_omo_agent: "deny",   // Ne peut PAS spawn d'autres agents
}
```

**Variantes** : `gpt.ts`, `gpt-5-4.ts`, `gpt-5-5.ts` (337 lignes — la plus raffinée)

## 4.4 ORACLE — Le Conseiller Stratégique Read-Only

**Rôle** : Raisonnement haut QI, debugging difficile, design architecture.

**Prompt complet (Claude, 153 lignes)** :

```
You are a strategic technical advisor with deep reasoning capabilities...

EXPERTISE :
- Dissection codebases pour comprendre patterns structurels
- Recommandations techniques concrètes et implémentables
- Architecture de solutions et roadmaps de refactoring
- Résolution de questions techniques complexes via raisonnement systématique
- Détection problèmes cachés et mesures préventives

FRAMEWORK DÉCISIONNEL :
- Bias toward simplicity : la bonne solution est typiquement la moins complexe
- Leverage what exists : favorisez modifications du code actuel
- Prioritize developer experience : optimisez lisibilité et maintenabilité
- One clear path : présentez UNE recommandation principale
- Match depth to complexity
- Signal the investment : Quick(<1h), Short(1-4h), Medium(1-2d), Large(3d+)
- Know when to stop : "Working well" > "theoretically optimal"
```

**Triggers** :
- Décisions architecture
- Auto-revue après implémentation significative
- Debugging dur après 2+ échecs

**Restrictions** : BLOQUÉ — `write`, `edit`, `apply_patch`, `task` (read-only strict)

## 4.5 LIBRARIAN — Le Spécialiste Recherche Externe

**Rôle** : Recherche dans codebases open-source, docs officielles, exemples.

**Mission** : "Answer questions about open-source libraries by finding EVIDENCE with GitHub permalinks"

**Vérification temporelle OBLIGATOIRE** : "NEVER search for ${year-1} — It is NOT ${year-1} anymore"

**Phase 0 — Classification (PREMIÈRE ÉTAPE OBLIGATOIRE)** :
- **TYPE A: CONCEPTUAL** — "How do I use X?" → Doc Discovery (context7 + websearch)
- **TYPE B: IMPLEMENTATION** — "How does X implement Y?" → gh clone + read + blame
- **TYPE C: CONTEXT** — "Why was this changed?" → gh issues/prs + git log/blame
- **TYPE D: COMPREHENSIVE** → TOUS les outils

**Phase 0.5 — Découverte Documentation** :
1. Trouver docs officielles via websearch
2. Vérification version
3. Découverte sitemap.xml
4. Investigation ciblée

**Synthèse** : Chaque affirmation DOIT inclure un permalink GitHub :
`https://github.com/<owner>/<repo>/blob/<commit-sha>/#L<start>-L<end>`

**Outils utilisés** : context7, websearch_web_search_exa, webfetch, grep_app_searchGitHub, gh repo clone, gh search issues/prs, git log/blame

## 4.6 EXPLORE — Le Spécialiste Recherche Codebase

**Rôle** : Grep contextuel pour codebases. "Where is X?", "Which file has Y?", "Find the code that does Z"

**Mission** : Trouver fichiers et code, retourner résultats actionnables.

**Livrables obligatoires** :

```
1. Intent Analysis (Required)
<analysis>
**Literal Request**: [Ce qui est demandé littéralement]
**Actual Need**: [Ce qu'on essaie vraiment d'accomplir]
**Success Looks Like**: [Quel résultat permettrait d'avancer immédiatement]
</analysis>

2. Parallel Execution (Required)
3+ outils simultanément dans la PREMIÈRE action.

3. Structured Results (Required)
<results>
<files>
- /absolute/path/to/file1.ts - [pourquoi ce fichier]
</files>
<answer>[Réponse directe au besoin réel]</answer>
<next_steps>[Que faire avec cette information]</next_steps>
</results>
```

**Stratégie outils** :
- **Recherche sémantique** : LSP tools
- **Patterns structurels** : ast-grep
- **Patterns textuels** : grep
- **Patterns fichiers** : glob
- **Historique/évolution** : git commands

**Restrictions** : BLOQUÉ `write`/`edit`/`apply_patch`/`task`/`call_omo_agent`. LSP désactivé (symbols, goto_definition, find_references, diagnostics).

## 4.7 MULTIMODAL-LOOKER — L'Analyste Visuel

**Rôle** : Interprétation fichiers médias (PDFs, images, diagrammes).

**Règle d'or** : "The file or image is already attached to the message. Analyze the attachment directly. Never call tools, never spawn other agents."

**Cas d'usage** :
- Médias nécessitant interprétation visuelle ou documentaire
- Extraction d'informations spécifiques depuis documents
- Description de contenu visuel (UI, diagrammes, charts)

**Cas de NON-utilisation** :
- Code source ou texte plain
- Fichiers nécessitant édition après
- Lecture simple sans interprétation

**Restrictions** : ALLOWLIST : `["read"]` UNIQUEMENT. Ne peut RIEN faire d'autre.

## 4.8 METIS — Le Consultant Pré-Planning

**Rôle** : Analyste pré-planning qui identifie intentions cachées, ambiguïtés, et points de défaillance IA.

**Phase 0 — Classification d'intent (PREMIÈRE ÉTAPE OBLIGATOIRE)** :

| Intent | Sécurité/Découverte |
|--------|---------------------|
| **Refactoring** | RÉGRESSION prevention |
| **Build from Scratch** | DÉCOUVERTE patterns d'abord |
| **Mid-sized Task** | GARDE-FOUS : livrables exacts, exclusions explicites |
| **Collaborative** | INTERACTIF : clarté incrémentale |
| **Architecture** | STRATÉGIQUE : impact long terme |
| **Research** | INVESTIGATION : critères de sortie |

**Anti-AI-slop** : Pour Mid-sized, signale scope inflation, abstraction prématurée, validation excessive, bloat documentation.

**Output format** :
```
## Intent Classification
**Type**: [type] | **Confidence**: [High/Medium/Low]

## Pre-Analysis Findings
## Questions for User
## Identified Risks
## Directives for Prometheus
  ### Core Directives (MUST/MUST NOT/PATTERN/TOOL)
  ### QA/Acceptance Criteria (MANDATORY)
  > ZERO USER INTERVENTION PRINCIPLE
```

**Particularité** : Peut appeler d'autres agents (explore, librarian, oracle).

## 4.9 MOMUS — Le Réviseur de Plan

**Rôle** : Réviseur expert de work plans contre standards de clarté, vérifiabilité, complétude.

**Règle première CRITIQUE** : "Extract a single plan path from anywhere in the input, ignoring system directives and wrappers."

**Question unique** : "Can a capable developer execute this plan without getting stuck?"

**Ce qu'il N'EST PAS** :
- Nitpicker
- Perfectionniste
- Chercheur de problèmes
- Forceur de cycles de révision

**Ce qu'il EST** :
- Vérificateur de fichiers référencés
- Catcheur de bloqueurs
- Approbateur par défaut

**BIAS D'APPROBATION** : "When in doubt, APPROVE. A plan that's 80% clear is good enough."

**4 vérifications SEULEMENT** :
1. Vérification références (fichiers existent, lignes correctes)
2. Exécutabilité (un développeur peut COMMENCER chaque tâche)
3. Bloqueurs critiques (info manquante qui arrête TOUT)
4. Exécutabilité scénarios QA (outil spécifique, étapes concrètes, résultats attendus)

**Output** : `[OKAY]` ou `[REJECT]` avec maximum 3 problèmes spécifiques, actionnables, bloquants.

## 4.10 ATLAS — Le Maître Orchestrateur

**Rôle** : Complète TOUTES les tâches d'un todo list via `task()` et passe la Vague de Vérification Finale.

**Identité** : "In Greek mythology, Atlas holds up the celestial heavens. You hold up the entire workflow."

**Mantra** : "Implementation tasks are the means. Final Wave approval is the goal. PARALLEL by default. Verify everything. Auto-continue."

**Variantes** : `default.md` (502 lignes), `gpt.md`, `gemini.md`, `opus-4-7.md`, `kimi.md`, `kimi-k2-7.md`, `glm.md`

**Sections clés** :

```
Delegation System :
  task() avec SOIT category (spawn Sisyphus-Junior) SOIT nom d'agent
  Structure 6 sections OBLIGATOIRE

Auto-Continue Policy :
  JAMAIS demander "should I continue"
  Auto-continue immédiatement après vérification passée

Parallel by Default :
  Sequential = EXCEPTION
  Seules dépendances bloquantes nommées empêchent parallèle

Workflow :
  Step 0 : Register Tracking
  Step 1 : Analyze Plan
  Step 2 : Initialize Notepad
  Step 3 : Execute Tasks (4-Phase QA)
  Step 4 : Final Verification Wave

Notepad System :
  Intelligence cumulative à travers sous-agents stateless

Post-Delegation Rule :
  DOIT éditer checkbox plan après chaque complétion vérifiée
```

## 4.11 SISYPHUS-JUNIOR — L'Exécuteur Focalisé

**Rôle** : Exécuteur focalisé. "Same discipline, no delegation."

**Règles strictes** :

```
TODO OBSESSION (NON-NEGOTIABLE) :
  - 2+ steps → todowrite FIRST, atomic breakdown
  - Mark in_progress avant de commencer (UN à la fois)
  - Mark completed IMMÉDIATEMENT après chaque étape
  - JAMAIS batcher les complétions

Vérification :
  Tâche NON complète sans :
  - lsp_diagnostics clean sur fichiers modifiés
  - Build passe (si applicable)
  - Tous todos marqués completed

Termination :
  STOP après première vérification réussie. NE PAS re-vérifier.
  Maximum checks : 2. Puis stop quoi qu'il arrive.

Style :
  Start immediately. No acknowledgments.
  Match user's communication style.
  Dense > verbose.
```

**Restrictions** : BLOQUÉ `task` (ne peut pas déléguer plus loin). Peut appeler explore/librarian via `call_omo_agent`.

## 4.12 PROMETHEUS — Le Planificateur

**Rôle** : Consultant en planification. Crée plans, n'implémente JAMAIS.

**Prompt (5 lignes — minimaliste, délègue tout au skill `ulw-plan`)** :

```
You are Prometheus, a planning consultant. Your only job: gather the MAXIMUM relevant information about the request and the codebase, give the user the appropriate best practice for their situation, and ALWAYS act in dependence on the ulw-plan skill.

You are a PLANNER. You read, search, and write only plan artifacts under .omo/; you never edit product code and never implement.

Your FIRST action in every planning session is to LOAD the shared ulw-plan skill.
```

## 4.13 Flux d'interaction entre agents

```
User → Sisyphus (primary)
  ├── explore (background research)
  ├── librarian (background research)
  ├── oracle (consultation after failures)
  ├── metis → (pre-planning) → Prometheus → momus (plan review)
  ├── atlas (when plan file provided)
  │     ├── sisyphus-junior (via category)
  │     ├── explore (background)
  │     └── librarian (background)
  ├── hephaestus (autonomous deep work, GPT-only)
  │     ├── explore (background)
  │     ├── librarian (background)
  │     └── oracle (last resort)
  ├── multimodal-looker (media)
  └── sisyphus-junior (via category)
        ├── explore (background)
        └── librarian (background)
```

## 4.14 Patterns architecturaux clés

1. **Assemblage dynamique de prompts** — Sisyphus, Hephaestus, Atlas, Sisyphus-Junior construisent leurs prompts depuis des builders modulaires.

2. **Variantes par modèle** — Chaque agent majeur a des variantes Claude, GPT-5.4, GPT-5.5, Gemini, GLM, Kimi calibrées sur les tendances comportementales de chaque famille.

3. **Primary vs Subagent** — Primary (Sisyphus, Hephaestus, Atlas) respectent le modèle UI. Subagents utilisent leur propre chaîne de fallback.

4. **Règle Anti-Duplication** — Tous les agents qui peuvent fire explore/librarian partagent une section commune empêchant la re-recherche après délégation.

5. **Philosophie de vérification** — Atlas et Sisyphus appliquent "Subagents lie" — chaque travail délégué doit être vérifié par lecture de chaque fichier modifié, exécution diagnostics, et QA hands-on.

---

# 5. Méthodologie complète

## 5.1 Le Ralph Loop / ulw-loop / ultrawork

### Concept fondamental

Boucle auto-continuante qui persiste à travers les fenêtres de contexte. Implémentée comme système de hooks dans `packages/omo-opencode/src/hooks/ralph-loop/`.

### État central

```typescript
interface RalphLoopState {
  active: boolean
  iteration: number
  max_iterations?: number
  completion_promise: string          // "DONE" normal, "VERIFIED" ultrawork
  started_at: string
  prompt: string                      // prompt utilisateur original
  session_id?: string
  ultrawork?: boolean
  strategy?: "reset" | "continue"     // reset=nouvelle session, continue=même session
}
```

Stocké dans `.omo/ralph-loop.local.md`

### Limites d'itération

- Mode normal : `DEFAULT_MAX_ITERATIONS = 100`
- Mode ultrawork : `ULTRAWORK_MAX_ITERATIONS = 500`

### Comment ça démarre

Le détecteur de mots-clés identifie "ultrawork" ou "ulw" dans le message utilisateur, ou les commandes `/ralph-loop`/`/ulw-loop` sont utilisées.

### Comment ça continue

Sur chaque événement `session.idle` :

1. Attend stabilisation (idle settle window, 150ms par défaut)
2. Vérifie si le tour assistant n'a fait aucun progrès (zéro tokens, pas de contenu)
3. Cherche completion en scannant `<promise>DONE</promise>` (normal) ou `<promise>VERIFIED</promise>` (ultrawork)
4. Si pas de completion détectée, appelle `continueIteration()` qui :
   - Construit un prompt : `[SYSTEM REMINDER - RALPH LOOP {ITERATION}/{MAX}]\nContinue. Output <promise>{PROMISE}</promise> when done.\n{ORIGINAL_PROMPT}`
   - Si `strategy="reset"` : crée NOUVELLE session, injecte le prompt, lie l'état à la nouvelle session
   - Si `strategy="continue"` : injecte le prompt dans la MÊME session

### Comment ça s'arrête

1. **Promise de completion détectée** — L'agent émet `<promise>DONE</promise>` ou `<promise>VERIFIED</promise>`
2. **Max itérations atteint** — `iteration > max_iterations`
3. **Détection no-progress** — Tour assistant zéro tokens sans contenu (stuck)
4. **Abort utilisateur** — `session.error` avec erreur d'abort
5. **Stop manuel** — Commande `/stop-continuation`
6. **Session supprimée**

### Détection de mots-clés

```typescript
KEYWORD_DETECTORS = [
  { type: "ultrawork", pattern: /\b(ultrawork|ulw)\b/i },
  { type: "team", pattern: TEAM_PATTERN },
  { type: "hyperplan", pattern: HYPERPLAN_PATTERN },
  { type: "hyperplan-ultrawork", pattern: /\b(?:hpp|hyperplan)\s+(?:ulw|ultrawork)\b|.../ },
]
```

### 6 variantes de prompt ultrawork par modèle

| Variante | Lignes | Particularités |
|----------|--------|----------------|
| **default** (Claude) | 331 | La plus complète. ABSOLUTE CERTAINTY PROTOCOL, TDD workflow (RED→GREEN→SURFACE→REFACTOR→REGRESSION), Durable Notepad |
| **GPT** | 180 | Léger, output verbosity spec, scope constraints, decision framework |
| **Gemini** | 317 | GEMINI_INTENT_GATE obligatoire, TOOL_CALL_MANDATE, ANTI_OPTIMISM_CHECKPOINT |
| **GLM** | 218 | GLM 5.2 CALIBRATION, FABLE_COUNTERS (pas sur-planifier, pas narrer options) |
| **Codex** | 373 | La plus détaillée. Tier triage LIGHT/HEAVY, bootstrap 0-3, exécution PIN→RED→GREEN→SURFACE→CLEAN |
| **Planner** | 24 | Concis. Routes vers skill `ulw-plan` |

### Hooks de continuation

**Todo Continuation Enforcer** :
- Surveille événements `session.idle`
- Récupère todo list via `ctx.client.session.todo()`
- Si todos incomplets ET pas de background tasks ET agent a permission write :
  - Injecte : `[SYSTEM REMINDER - TODO CONTINUATION]\nYou have incomplete todos. Continue working on the next task.`
- Détection de stagnation, garde compaction, respect `/stop-continuation`

**Stop Continuation Guard** :
- `Set<string>` de sessions stoppées
- État persiste entre messages utilisateurs (intentionnellement NON cleared)
- Seulement cleared par : `/start-work`, `/ulw-loop`, `/ralph-loop`, `session.deleted`

### Boulder-State (Atlas continuation)

**Boulder Continuation Injector** :
- Injecte prompts de continuation dans sessions Atlas quand tâches restent
- Format : `[Status: {completed}/{total} completed, {remaining} remaining]`

**Boulder Session Lineage** :
- Traverse chaîne parent des sessions pour déterminer lignée du boulder

## 5.2 Le Workflow Prometheus + Metis + Momus

### Étape 1 : Metis (pré-planning)

Analyse AVANT planification pour prévenir les échecs IA :
- Classification d'intent
- Pour Build/Research : fire explore/librarian AVANT de poser questions
- Output : Intent Classification, Pre-Analysis Findings, Questions for User, Identified Risks, Directives for Prometheus

### Étape 2 : Prometheus (planning)

Délègue tout au skill `ulw-plan`. Logique d'interview :

**Intent Routing** :
1. Parse modificateurs de revue ("high accuracy", "고정밀", etc.)
2. Classifie intent :
   - **CLEAR** : User connaît outcome ; demande forks survivants AVEC POURQUOI
   - **UNCLEAR** : Outcome flou ; recherche maximale, adopte best-practice defaults, NE demande PAS questions supplémentaires
   - **ON THE FENCE** : Traite comme CLEAR, pose UNE question
3. **Override** : Si user demande explicitement d'être questionné ("ask me", "interview me"), route CLEAR et désactive adopt-default filter

**Mécanique d'interview** :
- Deux filtres sur chaque question candidate :
  1. Est-ce que les preuves collectées peuvent répondre ? → explore à la place
  2. Est-ce que intent stated + default défendable peuvent répondre ? → adopte default, ne demande pas
- Owner-decisions (irréversibles/destructives/safety-critical) survivent TOUJOURS comme questions

**Structure du plan** :
```
.omo/drafts/<slug>.md     # point de reprise durable
.omo/plans/<slug>.md      # le plan actuel
```

Le plan contient :
- Block `## TL;DR (For humans)`
- Dependency matrix
- Task batches avec references + acceptance + QA + commit
- Agent-executed QA par todo (happy + failure, outil exact + invocation, chemin d'évidence)

### Étape 3 : Momus (revue)

Vérifie exécutabilité et références. Output : `[OKAY]` ou `[REJECT]` avec max 3 problèmes bloquants.

### Étape 4 : Approval gate

Quand exploration épuisée, enregistre `status: awaiting-approval` dans draft. Présente brief court une fois, puis attend approbation explicite.

### Étape 5 : /start-work

L'exécution commence. Atlas prend le relais.

## 5.3 Le Team Mode

### Architecture

Mode multi-agents avec communication par mailbox, coordination de tâches, visualisation tmux.

### Types

```typescript
Message {
  version: string
  messageId: UUID
  from: string
  to: string
  kind: "message" | "shutdown_request" | "shutdown_approved" | "shutdown_rejected" | "announcement"
  body: string  // max 32KB
  summary?: string
  references?: Reference[]
  timestamp: string
  correlationId?: string
  color?: string
}

Task {
  version: string
  id: string
  subject: string
  description: string
  activeForm?: string
  status: "pending" | "claimed" | "in_progress" | "completed" | "deleted"
  owner?: string
  blocks?: string[]
  blockedBy?: string[]
  metadata?: object
  createdAt: string
  updatedAt: string
  claimedAt?: string
}

Member {
  name: string  // lowercase+hyphens
  cwd?: string
  worktreePath?: string
  subscriptions?: string[]
  backendType: "in-process" | "tmux"
  color?: string
  isActive: boolean
  kind: "category" | "subagent_type"
  category?: string
  subagent_type?: string
  prompt?: string
}
```

### Mécanisme Mailbox

**Stockage** : File-based. Chaque membre a un répertoire inbox :
```
{baseDir}/{teamRunId}/inbox/{memberName}/
```

**Format message** : Chaque message est un fichier JSON nommé `{messageId}.json`

**Send Flow** :
1. Valide team accepte messages (pas en état "deleting"/"deleted")
2. Vérifie permission broadcast (seul lead peut broadcaster à `*`)
3. Pour chaque destinataire :
   a. Crée répertoire inbox si besoin
   b. Acquiert lock (`{inboxDir}.lock`)
   c. Vérifie taille non-lus vs `recipient_unread_max_bytes` (backpressure)
   d. Vérifie duplicata messageId
   e. Écrit message à `{inboxDir}/{messageId}.json` (ou `.delivering-{messageId}.json`)
   f. Retourne liste delivered-to

**Poll/Injection Flow** :
1. Liste messages non-lus du répertoire inbox
2. Acquiert lock d'état runtime
3. Vérifie si déjà injecté ce tour (via `lastInjectedTurnMarker`)
4. Filtre messages pending-ack
5. Construit enveloppes XML :
   `<peer_message from="..." timestamp="..." messageId="..." kind="...">{body}</peer_message>`
6. Met à jour état runtime avec `pendingInjectedMessageIds`

**Types d'erreurs** :
- `BroadcastNotPermittedError` — Non-lead tente broadcast
- `PayloadTooLargeError` — Body > 32KB
- `RecipientBackpressureError` — Inbox plein
- `DuplicateMessageIdError` — Même messageId existe déjà
- `InvalidRecipientError` — Membre inconnu ou inactif
- `TeamDeletingError` — Team en cours de suppression

### Coordination de tâches

**Stockage** : Fichiers à `{baseDir}/{teamRunId}/tasks/{id}.json`

**Claim Flow** :
1. Vérifie statut "pending"
2. Vérifie dépendances (`canClaim` — tous `blockedBy` doivent être "completed")
3. Gère locks stale (300s stale-after)
4. Acquiert claim lock
5. Double-check statut et dépendances (pattern double-check)
6. Met à jour task à "claimed" avec owner et timestamp

### Visualisation Tmux

**Layout** :
```
+------------------+------------------+
|                  |                  |
|   Lead Pane      |   Member 1      |
|   (30% width)    |   (opencode     |
|                  |    attach)      |
|                  |                  |
+------------------+------------------+
|                  |                  |
|                  |   Member 2      |
|                  |                  |
+------------------+------------------+
```

**Implémentation** :
1. Résout session tmux et pane du caller
2. Pour chaque membre :
   a. Split window (horizontal pour premier membre, alterné ensuite)
   b. Set pane title à `omo-team-{memberName}`
   c. Stocke server URL et session ID comme options tmux
   d. Lance `opencode attach {serverUrl} --session {sessionId} --dir {workdir}` dans le pane
3. Applique layout `main-vertical`
4. Resize lead pane à 30% width

**Éligibilité Team Mode** :
- **ÉLIGIBLES** : `sisyphus`, `atlas`, `sisyphus-junior`, `hephaestus` (avec D-36)
- **HARD-REJECTED** : `oracle`, `librarian`, `explore`, `multimodal-looker`, `metis`, `momus`, `prometheus` (tous read-only)

## 5.4 Hashline — L'Outil d'Édition Chirurgicale

### Le problème résolu

De l'article de Can Bölük sur le "Harness Problem" :
> "None of these tools give the model a stable, verifiable identifier for the lines it wants to change... They all rely on the model reproducing content it already saw."

### L'algorithme

**xxHash32** (hash non-cryptographique rapide) :
- Utilise `hash.xxHash32()` natif de Bun quand disponible
- Fallback sur implémentation JavaScript pure
- 5 constantes premières PRIME32_1 à PRIME32_5

### Dictionnaire de hash

```typescript
NIBBLE_STR = "ZPMQVRWSNKTXJBYH"  // 16 caractères
HASHLINE_DICT = Array.from({ length: 256 }, (_, i) => {
  const high = i >>> 4
  const low = i & 0x0f
  return `${NIBBLE_STR[high]}${NIBBLE_STR[low]}`
})
```

Table de lookup 256 entrées mappant chaque byte à une chaîne 2-caractères depuis l'alphabet 16. Le hash fait toujours 2 caractères (16 bits d'entropie).

### Format LINE#ID

`{lineNumber}#{hashId}`

Exemples :
- `42#ZP` — ligne 42 avec hash ZP
- `1#QR` — ligne 1 avec hash QR

Format output : `{lineNumber}#{hashId}|{content}`

### Patterns regex

```typescript
HASHLINE_REF_PATTERN = /^([0-9]+)#([ZPMQVRWSNKTXJBYH]{2})$/
HASHLINE_OUTPUT_PATTERN = /^([0-9]+)#([ZPMQVRWSNKTXJBYH]{2})\|(.*)$/
```

### Calcul du hash

```typescript
function computeLineHash(lineNumber: number, content: string): string {
  const stripped = content.replace(/\r/g, "").trimEnd()
  const seed = RE_SIGNIFICANT.test(stripped) ? 0 : lineNumber
  const hash = hashXxh32(stripped, seed)
  const index = hash % 256
  return HASHLINE_DICT[index]
}
```

**Détail clé** : La seed VARIE. Si la ligne a contenu alphanumérique, seed=0. Si blank/whitespace-only, seed=lineNumber. Cela garantit que les lignes blank à différentes positions ont des hashs différents.

### Types d'édition

```typescript
type HashlineEdit = ReplaceEdit | AppendEdit | PrependEdit

ReplaceEdit { op: "replace", pos: string, end?: string, lines: string | string[] }
AppendEdit  { op: "append", pos?: string, lines: string | string[] }
PrependEdit { op: "prepend", pos?: string, lines: string | string[] }
```

### Flux d'édition

1. Déduplique éditions
2. Trie par numéro de ligne (descendant) avec précédence : `replace > append > prepend`
3. Valide références de ligne vs contenu fichier actuel
4. Détecte plages qui se chevauchent
5. Applique éditions en ordre inverse (préserve numéros de ligne)
6. Track éditions noop

### Validation

Quand éditions référencent lignes via `{lineNumber}#{hashId}` :

1. Parse la référence : extrait numéro ligne et hash 2-char
2. Calcule le hash actuel pour cette ligne
3. Compare avec hash de référence (supporte algorithmes actuel et legacy)
4. Si mismatch : throw `HashlineMismatchError` avec :
   - Lignes de contexte (2 au-dessus et en-dessous de chaque mismatch)
   - Marqueurs `>>>` pour lignes changées
   - Références hash corrigées pour chaque ligne en mismatch
   - Map `remaps` pour correction programmatique

### Récupération d'erreur

```
2 lines have changed since last read. Use updated {line_number}#{hash_id} references below (>>> marks changed lines).

    40#QR|  // existing line
    41#BM|  // existing line
>>> 42#XK|  const x = changedContent;  // line changed
    43#TW|  // existing line
```

**Smart Hints** : Quand un line ref ne parse pas, le système cherche un hash correspondant dans le fichier et suggère : `Did you mean "42#ZP"?`

### Impact mesuré

Seul, le hashline a fait passer Grok Code Fast 1 de **6.7% à 68.3%** de taux de succès.

---

# 6. Système de hooks (100+ hooks)

## 6.1 Hooks Core

| Hook | Rôle |
|------|------|
| `rules-injector` | Injection règles conditionnelles depuis AGENTS.md, .omo/rules/, .claude/rules/, .cursor/rules/, .github/instructions/ |
| `comment-checker` | Détection AI slop patterns (em dashes, en dashes, "simply", "obviously", "clearly") |
| `claude-code-hooks` | Compatibilité Claude Code |
| `codegraph-bootstrap` | Initialisation serveur codegraph |
| `auto-update-checker` | Vérification mises à jour |
| `keyword-detector` | Détection ultrawork/team/hyperplan |
| `runtime-fallback` | Fallback runtime |

## 6.2 Hooks Agent

| Hook | Rôle |
|------|------|
| `atlas` | Boulder-state et continuation Atlas |
| `ralph-loop` | Boucle auto-continuante |
| `todo-continuation-enforcer` | Force continuation si todos incomplets |
| `hephaestus-agents-md-injector` | Injection AGENTS.md pour Hephaestus |
| `sisyphus-junior-notepad` | Notepad pour Sisyphus-Junior |
| `unstable-agent-babysitter` | Baby-sitting agents instables |

## 6.3 Hooks Édition

| Hook | Rôle |
|------|------|
| `hashline-edit-diff-enhancer` | Enhancement diff pour éditions hashline |
| `hashline-read-enhancer` | Enhancement read pour hashline |
| `edit-error-recovery` | Récupération erreurs d'édition |
| `write-existing-file-guard` | Garde fichiers existants |
| `notepad-write-guard` | Garde écritures notepad |

## 6.4 Hooks Session

| Hook | Rôle |
|------|------|
| `session-notification` | Système notification desktop complet |
| `session-todo-status` | Status todos session |
| `preemptive-compaction` (4 fichiers) | Compaction préventive avant débordement |
| `compaction-context-injector` | Préservation contexte à travers compaction |
| `compaction-todo-preserver` | Préservation todos à travers compaction |

## 6.5 Hooks Team

| Hook | Rôle |
|------|------|
| `team-mailbox-injector` | Injection mailbox |
| `team-mode-status-injector` | Status mode team |
| `team-session-events` | Événements session team |
| `team-tool-gating` | Gating outils team |

## 6.6 Hooks Sécurité

| Hook | Rôle |
|------|------|
| `bash-file-read-guard` | Garde lecture fichiers bash |
| `fsync-skip-warning` | Warning skip fsync |
| `question-label-truncator` | Troncature labels questions |
| `tool-output-truncator` | Troncature output outils |
| `tool-pair-validator` | Validation paires outils |
| `webfetch-redirect-guard` | Garde redirections webfetch |

## 6.7 Hooks Fonctionnalités

| Hook | Rôle |
|------|------|
| `auto-slash-command` | Commandes slash automatiques |
| `ast-grep-sg-provision` | Provision ast-grep |
| `background-notification` | Notifications background |
| `category-skill-injector` | Injection skills par catégorie |
| `directory-agents-injector` | Injection AGENTS.md répertoire |
| `directory-readme-injector` | Injection README répertoire |
| `interactive-bash-session` | Session bash interactive |
| `legacy-plugin-toast` | Toast plugin legacy |
| `model-fallback` | Fallback modèle |
| `plan-format-validator` | Validation format plan |
| `prometheus-md-only` | Prometheus MD uniquement |
| `start-work` | Démarrage travail |
| `stop-continuation-guard` | Garde stop continuation |
| `task-reminder` | Rappel tâches |
| `task-resume-info` | Info reprise tâche |
| `think-mode` | Mode réflexion |
| `tasks-todowrite-disabler` | Désactivation todowrite tâches |
| `read-image-resizer` | Redimensionnement images lues |

---

# 7. Les 17 outils

| Outil | Rôle |
|-------|------|
| `background-task` | Exécution parallèle fire-and-forget |
| `call-omo-agent` | Invocation directe d'agent |
| `delegate-task` | Délégation sous-agent par catégorie |
| `glob` | Pattern matching fichiers |
| `grep` | Recherche contenu |
| `hashline-edit` | Édition chirurgicale ancrée par hash |
| `interactive-bash` | Interaction terminal live (tmux) |
| `look-at` | Analyse fichiers médias (PDFs, images) |
| `monitor` | Monitoring progrès temps réel |
| `session-manager` | Liste/lecture/recherche sessions |
| `skill` | Chargement et exécution skills |
| `skill-mcp` | Gestion serveurs MCP skill-embedded |
| `slashcommand` | Routage commandes slash |
| `task` | Gestion tâches (todo, background) |
| `shared` | Utilitaires outils partagés |

---

# 8. Les 25+ skills partagés

| Skill | Rôle |
|-------|------|
| `ast-grep` | Recherche/réécriture patterns sur 25 langages |
| `coding-agent-sessions` | Découverte et analyse sessions cross-agents |
| `debugging` | Méthodologie debug systématique (8 étapes) |
| `frontend` | Développement UI design-first + audit Lighthouse |
| `git-master` | Commits atomiques, rebase surgery, gestion branches |
| `init-deep` | Auto-génération fichiers AGENTS.md hiérarchiques |
| `lsp-setup` | Installation LSP pour 20+ langages |
| `programming` | Références codage par langage (Go, Python, Rust, TypeScript) |
| `refactor` | Refactoring intelligent avec LSP + AST-grep |
| `remove-ai-slops` | Nettoyage AI code smells |
| `review-work` | Revue code post-implémentation |
| `start-work` | Planning Prometheus avant exécution |
| `ultimate-browsing` | Fetching web avancé avec détection WAF, Chrome stealth |
| `ultraresearch` | Recherche profonde avec escalade |
| `ulw-plan` | Workflow planification ultrawork |
| `ulw-research` | Workflow recherche ultrawork |
| `visual-qa` | QA visuelle pour UIs |

---

# 9. Catégories de délégation

| Catégorie | Usage | Modèle auto-routé |
|-----------|-------|-------------------|
| `visual-engineering` | Frontend, UI/UX, design | Gemini 3.1 Pro |
| `deep` | Recherche + exécution autonome | GPT-5.5 |
| `quick` | Changements single-file, typos | GPT-5.4 Mini |
| `ultrabrain` | Logique dure, décisions architecture | GPT-5.5 xhigh |
| `artistry` | Design visuel, esthétique | Gemini |
| `writing` | Documentation, prose | Modèles optimisés prose |
| `unspecified-low` | Général basse complexité | Modèles rapides cheap |
| `unspecified-high` | Général haute complexité | Claude Opus |

---

# 10. Techniques de prompt engineering

## 10.1 IntentGate (Keyword Detection)

Analyse du vrai intent utilisateur AVANT classification ou action. Détecte mots-clés comme `ultrawork`/`ulw`, `search`, `analyze`, `team` et injecte prompts spécifiques au mode.

## 10.2 Construction Dynamique de Prompts

Chaque agent a un **dynamic prompt builder** qui assemble prompts depuis sections :

```
sisyphus-dynamic-prompt-builder.ts → combine :
  - sisyphus-dynamic-prompt-role.ts       (identité)
  - sisyphus-dynamic-prompt-execution.ts  (comment travailler)
  - sisyphus-dynamic-prompt-exploration.ts (découverte codebase)
  - sisyphus-dynamic-prompt-style.ts      (style communication)
  - sisyphus-dynamic-prompt-sections.ts   (sections contexte)
```

## 10.3 Injection de Règles

Le hook `rules-injector` auto-charge règles projet depuis :
- Fichiers `AGENTS.md` (hiérarchiques, générés par `/init-deep`)
- `.omo/rules/*.md`
- `.claude/rules/`
- `.cursor/rules/`
- `.github/instructions/`
- `.github/copilot-instructions.md`
- Fichiers `.mdc`

## 10.4 Hash-Anchored Edit Tool

Déjà couvert en 5.4. Résultat mesuré : Grok Code Fast 1 passe de **6.7% à 68.3%** de succès.

## 10.5 Comment Checker

`@code-yeongyu/comment-checker` bloque patterns AI slop dans commentaires. Patterns bannis : em dashes, en dashes, mots filler AI ("simply", "obviously", "clearly", "moreover", "furthermore").

## 10.6 Rules Engine (système MCP 3-tier)

| Tier | Source | Mécanisme |
|------|--------|-----------|
| 1. Built-in | `packages/omo-opencode/src/mcp/` | 3 HTTP remote + 2 stdio local |
| 2. Claude Code | `.mcp.json` (projet + user) | Expansion env `${VAR}` |
| 3. Skill-embedded | YAML frontmatter SKILL.md | stdio + HTTP, OAuth 2.0 + PKCE |

## 10.7 Context Injection & Compaction

- **Compaction context injector** préserve contexte à travers compaction
- **Todo preserver** maintient état tâches à travers limites fenêtre contexte
- **Preemptive compaction** se déclenche avant débordement contexte
- **First-prompt watchdog** détecte sessions sous-agents sans progrès en 90s

## 10.8 Discipline Agents (nommage mythologie grecque)

Sisyphus "roule le boulder chaque jour. Jamais ne s'arrête. Jamais n'abandonne." Les agents sont calibrés sur les forces spécifiques de leur modèle. Pas de jonglage manuel de modèle.

## 10.9 QA as Evidence Gate

**Chaque changement requiert une évidence QA.** Pas de fichier évidence → pas de commit → pas de push. Enforcé au niveau outil avec :
- Skill `opencode-qa` pour changements OpenCode
- Skill `codex-qa` pour changements Codex
- Évidence écrite à `.omo/evidence/<YYYYMMDD>-<short-slug>/`

## 10.10 Ralph Loop / ulw-loop

Boucle **auto-référentielle** qui ne s'arrête pas tant que 100% n'est pas fait. Le système continue à travailler en autonomie, accumulant les apprentissages à travers les tâches. Les conventions découvertes en tâche 1 sont passées à tâche 5.

## 10.11 Skill-Embedded MCPs

Les serveurs MCP démarrent à la demande, scopés à la tâche, et disparaissent quand terminés. Cela garde la fenêtre de contexte propre — pas de bloat contexte depuis outils inutilisés.

## 10.12 Accumulated Wisdom

Les sous-agents apprennent des résultats précédents. Le système accumule connaissance à travers les tâches, devenant plus intelligent au fil du travail.

---

# 11. Roadmap multi-harness

L'objectif est de supporter plusieurs harnesses d'agents (OpenCode, Codex, Pi, Claude Code). Le refactor de layering packages sépare :

- **Core** — Logique TypeScript pure (pas de dépendances harness)
- **MCP** — Serveurs outils externes (frontière processus stdio)
- **Skills** — Fichiers déclaratifs statiques (SKILL.md)
- **Adapters** — Glue spécifique au harness
- **Platform** — Binaires compilés

---

# 12. Statistiques finales

| Métrique | Valeur |
|----------|--------|
| Commits (branche `dev`) | 9,898+ |
| Packages monorepo | 37 |
| Hooks cycle de vie | 54-60 (base / avec team mode) |
| Agents intégrés | 11 |
| Outils (config-gated) | 20-39 |
| Système MCP | 3-tier |
| Packages core réutilisables cross-harness | 18 |
| Binaires plateforme | 12 |

---

## Notes méthodologiques

Ce rapport a été produit en utilisant l'orchestration Chef d'orchestre avec 4 pupitres en parallèle :

| Pupitre | Mission | Durée |
|---------|---------|-------|
| Explore #1 | Cloner + cartographier l'architecture complète | 2m28s |
| Librarian | Recherche docs officielles + techniques | 1m16s |
| Explore #2 | Deep-dive méthodologie (ralph loop, prometheus, team mode, hashline) | 2m56s |
| Explore #3 | Documentation exhaustive des 10 agents | 2m19s |

**Sources primaires** :
- Repository : https://github.com/code-yeongyu/oh-my-openagent
- Clone local : `/tmp/oh-my-openagent`
- 101,946 lignes de TypeScript analysées
- 37 packages du monorepo cartographiés

---

*Fin du rapport.*