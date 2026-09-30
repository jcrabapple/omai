# Terminology (Omai + web dashboard)

Agreed 2026-09-30. User-facing copy only; code identifiers, wire names
(`subagent_progress`, `/subagents`) and file names stay as they are.

| Term | Means | Don't say |
|---|---|---|
| **agent** | the one agent you talk to in a session | assistant, model (unless the model itself is meant), bot |
| **helper** / **helpers** | background agents the agent spawns (omp task-tool subagents) | subagent, background agent, agents (plural, for these) |
| **session** | one conversation with the agent | chat, thread, conversation |
| **turn** | one message from you plus the agent's full response to it | prompt, run, message (when the whole exchange is meant) |

The helper's omp type (`scout`, `explore`, `reviewer`, ...) is shown as a
small tag on its row. It is a type label, not a name for the concept.

## Web dashboard strings to change (for the gateway session)

- `components/PlanPanel.svelte:74` tab label `Agents` -> `Helpers`
- `components/SubagentPanel.svelte:107` `No subagents` -> `No helpers in this session.`
- `components/SubagentPanel.svelte:38,61,127` fallback name `Subagent` -> `Helper`
- `components/SubagentPanel.svelte:159` `Waiting for subagent session...` -> `Waiting for the helper to start.` (also drops the ellipsis loading copy)
- Plus any user-visible "prompt" meaning a whole turn -> "turn".
