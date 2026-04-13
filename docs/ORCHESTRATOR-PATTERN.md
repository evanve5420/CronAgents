# Orchestrator Pattern — Fleet-Style Parallel Agents

Copilot CLI's `/fleet` command decomposes work into parallel subagents, but it only
works in interactive sessions. There is no `--fleet` flag for non-interactive (`-p`)
mode, which is what CronAgents uses.

This document describes how to achieve the same effect using the `task` tool — the
subagent delegation mechanism that **does** work in non-interactive mode.

## How it works

1. The agent's `.agent.md` includes `agent` in its `tools` list
   (this enables the `task` tool — an alias — that the LLM calls at runtime to spawn subagents).
2. The system prompt instructs the agent to decompose work and delegate subtasks
   to subagents via the `task` tool.
3. Each `task` call spawns an independent subagent with its own context window.
4. Multiple `task` calls in a single LLM response execute **in parallel**.
5. The orchestrator synthesizes results from all subagents.

## When to use this

- **Broad tasks** — scanning many files, reviewing many modules, generating many artifacts.
- **Expensive tasks** — where parallelism meaningfully reduces wall-clock time.
- **Specialized decomposition** — different subtasks benefit from different expertise or
  custom agents (via `@agent-name` in the subagent prompt).

Not useful for inherently sequential work or simple single-focus tasks.

## Agent profile pattern

```markdown
---
name: my-orchestrator
description: "Decomposes work into parallel subagents"
tools:
  - read
  - search
  - agent
---

# Orchestrator — <describe the domain>

You are an orchestrator agent. Break the request into independent subtasks and
delegate each to a subagent using the `task` tool.

## Process

1. **Analyze** the request. Identify independent subtasks.
2. **Delegate** each subtask to a subagent via the `task` tool.
   - Launch ALL independent subtasks simultaneously (multiple tool calls in one response).
   - Give each subagent complete, self-contained context — they have no shared state.
   - Use `agent_type: "general-purpose"` for complex work, `agent_type: "task"` for
     simple/mechanical work.
   - Reference custom agents with `@agent-name` in the subagent prompt when specialized
     expertise exists.
3. **Synthesize** results into a unified response.

## Rules

- Prefer parallel delegation over sequential self-execution.
- Each subagent is stateless — provide full file paths, context, and instructions.
- If a subtask depends on another's output, run the dependency first, then delegate
  the dependent task in a follow-up turn.
```

## Registration

The registration is a normal `.agent-registration.json`. The `agent` tool requires no
special infrastructure support — `--allow-all-tools` (always set by CronAgents)
already permits it.

```jsonc
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "My Orchestrator",
  "agent": "my-orchestrator",
  "prompt": "Scan all modules for X and generate a report.",
  "schedule": { "type": "daily", "time": "09:00" },
  "timeout": "30m"
}
```

### Timeout considerations

Orchestrator agents typically need a longer `timeout` than single-task agents because
they wait for multiple subagents to complete. A timeout of `20m`–`30m` is a reasonable
starting point. Each subagent runs within the parent's timeout window.

### Cost considerations

Each subagent makes its own LLM calls, so an orchestrator agent consumes more premium
requests than a single-agent run. Subagents default to a low-cost model unless the
orchestrator's prompt or a referenced custom agent specifies otherwise.

## Example: multi-module code scanner

```markdown
---
name: module-scanner
description: "Scans all modules in parallel for code quality issues"
tools:
  - read
  - search
  - agent
---

You are a code quality orchestrator. When asked to scan a project:

1. Use `search` to discover all top-level modules/packages.
2. For each module, launch a `task` subagent to analyze it independently.
3. Collect all subagent results and produce a unified report sorted by severity.

Give each subagent the module path and tell it exactly what to check.
Launch all module scans simultaneously.
```

## Verified behavior

This pattern was tested with Copilot CLI in non-interactive `-p` mode. The JSON
event stream confirms:

- Multiple `task` tool calls in a single assistant turn
- `subagent.started` events for each task (launched in parallel)
- `subagent.completed` events as each finishes
- The orchestrator agent synthesizes all results after completion

No scheduler or schema changes are required — the existing `--allow-all-tools` flag
and `agent` tool work out of the box.

## Subagent manifest for feedback targeting

When an orchestrator spawns subagents, it can write a `subagents.json` file into the
run directory to declare which subagents it used. This enables the feedback evaluator
to resolve targeted feedback to the correct agent definition files.

### Manifest format

```json
[
  {
    "name": "worker",
    "agent": "worker",
    "profile": ".github/agents/worker.agent.md",
    "skills": [".github/skills/worker/SKILL.md"]
  },
  {
    "name": "reviewer",
    "agent": "code-reviewer",
    "profile": ".github/agents/code-reviewer.agent.md",
    "skills": []
  }
]
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Short name used in feedback targeting (`agent: worker`) |
| `agent` | Yes | Agent identifier (matches the `--agent` flag or `.agent.md` stem) |
| `profile` | No | Path to the agent's `.agent.md` definition file |
| `skills` | No | Array of paths to the agent's `SKILL.md` files |

### How to emit the manifest

Add instructions to your orchestrator's system prompt to write `subagents.json` after
all subagents complete. The orchestrator knows which subagents it spawned, so it can
build the manifest from its own task definitions.

Example instruction to add to the orchestrator's `.agent.md`:

```markdown
After all subagents complete, write a `subagents.json` file to the current
working directory listing each subagent you spawned. Format:

\`\`\`json
[
  { "name": "<short-name>", "agent": "<agent-id>", "profile": "<path-to-agent.md>", "skills": ["<path-to-SKILL.md>"] }
]
\`\`\`
```

### How feedback targeting uses the manifest

When a human writes feedback with `## Target` and `agent: worker`, the feedback
evaluator resolves `worker` against the manifest to find the agent's profile and
skill files. This eliminates guesswork and ensures feedback edits the correct files.

See [Feedback System — Targeting](../guide/feedback-system.md#targeting-feedback-for-orchestrator-subagents) for the
full targeting workflow.
