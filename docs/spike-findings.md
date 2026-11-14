# Spike findings — Phase 0

Statut : **mesuré le 2026-11-14** dans une session maki interactive pilotée par
tmux. Les quatre probes ont tourné, le journal brut est
`~/.local/state/maki/metronome-spike/findings.log`, et chaque parseur a rendu
son verdict. Ce document garde l'observation brute puis la décision qui en
découle.

Procédure réellement utilisée :

```bash
# 1. charger le probe sans passer par require (require ne peut pas yield) :
#    un bloc loadstring dans ~/.config/maki/init.lua lit lua/spike.lua.
# 2. accorder env au plugin global (le sous-agent demandait toutes les
#    permissions parce que la liste d'outils contenait bg_status, sans
#    capacité déclarée).
# 3. lancer maki dans tmux, puis, dans l'ordre :
#    /thinking max ; spike_run probe=thinking model=ocgo/deepseek-v4-pro thinking=max
#    /thinking low ; spike_run probe=thinking model=ocgo/deepseek-v4-pro thinking=max
#    spike_run probe=cwd
#    spike_run_bg model=ocgo/deepseek-v4-pro thinking=low
#    /spike-reload   puis   /reload   pendant le run
# 4. lire le journal et les parseurs :
#    tools/spike-thinking.sh findings.log
#    tools/spike-cwd.sh findings.log
#    tools/spike-write.sh findings.log
#    tools/spike-reload.sh findings.log
```

---

## Probe 1 — modeles

Question : un subagent honore-t-il `model_spec` et `thinking` explicites, et
quel plafond le parent impose-t-il ?

Parseur : `tools/spike-thinking.sh` (verdict `honoured` / `capped` / `incomplete`).

Observation : deux runs. Parent `thinking=max`, requête
`model=ocgo/deepseek-v4-pro thinking=max` : `parent model=mistral/deepseek-v4-1-flash-1017
thinking=max shown=max`, `requested model=ocgo/deepseek-v4-pro thinking=max`,
réponse `PONG`, 15 tokens de sortie — le modèle explicite est honoré et le
thinking demandé passe. Parent `thinking=low`, même requête :
`parent model=mistral/deepseek-v4-1-flash-1017 thinking=low shown=low`,
`requested model=ocgo/deepseek-v4-pro thinking=max`, réponse `PONG`, 3 tokens
de sortie. Le parseur rend `parent_thinking=low requested_thinking=max
verdict=capped`.

Decision : le sous-agent honore bien le `model_spec` explicite, mais son
`thinking` est plafonné par celui du parent. Metronome doit donc tourner au
moins au niveau du rôle le plus exigeant (l'instrumentiste est à `max`), et
`roles.clamp_thinking` reste la garde qui rend le plafond visible au lieu de le
subir. Aucun contournement n'est nécessaire.

---

## Probe 2 — cwd

Question : quel cwd un subagent herite-t-il, et peut-il atteindre un repertoire
hors du cwd parent ?

Parseur : `tools/spike-cwd.sh` (verdict `reachable` / `unreachable`, plus
`inherits_parent_cwd`).

Observation : `parent cwd=/tmp/metronome-spike-session`,
`probe_dir=/home/anhydrite/.local/state/maki/metronome-spike/probe-worktree`,
réponse du sous-agent `PWD=/tmp/metronome-spike-session LS=ok`. Le parseur rend
`parent_cwd=/tmp/metronome-spike-session sub_pwd=/tmp/metronome-spike-session
inherits_parent_cwd=yes worktree=ok verdict=reachable`.

Decision : le sous-agent hérite du cwd parent et atteint le worktree par chemin
absolu. Le runner continue de passer des chemins absolus (`worktree`, `repo`,
`root`) et le prompt de rôle nomme le worktree ; aucun outil `workspace`
supplémentaire n'est requis.

---

## Probe 3 — permissions

Question : un subagent en arriere-plan ecrit-il dans le worktree avec les
permission rules declarees, sans qu'un prompt ne bloque ?

Parseur : `tools/spike-write.sh` (verdict `wrote` / `blocked` / `incomplete`,
juge sur le fichier, pas sur la parole du modele).

Observation : `mode=background`, `session_id=Ch3FSNjqzsVCoPjXX6YNE`,
`target=…/probe-worktree/probe-bg.txt`, `error=nil`, `reply=WRITE=<ok>`, puis
`file after run: metronome-probe-bg`. Le parseur rend `mode=background
marker=ok on_disk=yes verdict=wrote` : le fichier est réellement sur le disque.

Decision : l'écriture en arrière-plan passe avec les permissions déclarées,
donc `plugin.toml` doit garder `fs_write` et `run` ; `register_permission_rule`
sur le worktree suffit. Leçon opérationnelle : un outil sans capacité déclarée
(`bg_status`, `batch`, `code_execution`, `task`) fait payer toutes les
permissions au sous-agent ; le runner doit filtrer ces outils ou le plugin doit
les détenir explicitement.

---

## Probe 4 — reload

Question : que survit a un `/reload` pendant un run, que meurt, et que doit
reprendre le pipeline ?

Parseur : `tools/spike-reload.sh` (verdict par run `survived` / `died` /
`running`, verdict global `reload-preserves-runs` / `reload-kills-runs` /
`no-reload-observed`).

Observation : deux `BOOT` (chargement initial puis reload), un `RUN_START
id=run-1794679019 session=Ch3FSNjqzsVCoPjXX6YNE` et un `RUN_OPEN
id=run-1794679019 task=session-Ch3FboY746EZTpMtzuyv3`, puis `/reload` pendant
le run. Aucun `RUN_FINISH` ni `SESSION_END` après le reload : le run
session-scoped est toujours vivant. Le parseur rend `boots=2 runs=1
run=run-1794679019 verdict=running survived=0 died=0 running=1
verdict=reload-preserves-runs`.

Decision : un run session-scoped survit à `/reload` ; le pipeline ne doit donc
pas supposer qu'il est mort et le relancer aveuglément. `pipeline.resume()` est
une ceinture de sécurité (relecture de `state.jsonl`, reprise des tâches
actives), pas le mécanisme principal. Un run encore vivant doit être rattaché,
pas dupliqué.
