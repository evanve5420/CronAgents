---
name: copilot-cli
description: "Use when trying to understand GitHub Copilot CLI flags and invocation patterns used by CronAgents"
---

# Copilot CLI — CronAgents Quick Reference

> **Note:** The old `gh copilot` extension was retired October 2025. Install the standalone CLI via `winget install GitHub.Copilot` on Windows.

## Scheduler invocation

```
copilot --agent=<name> -p "<prompt>" --allow-all-tools --no-ask-user --silent --share=<path>
```

| Flag | Why CronAgents uses it |
|------|------------------------|
| `--agent=NAME` | Targets the specific `.agent.md` agent profile |
| `-p` / `--prompt` | Runs one prompt then exits (non-interactive) |
| `--allow-all-tools` | Auto-approves all tool use for unattended runs |
| `--deny-tool=TOOL` | Blocks dangerous tools (e.g. `shell(rm)`) |
| `--no-ask-user` | Prevents the agent from stalling on input requests |
| `--silent` | Suppresses stats; outputs only the agent response |
| `--share=PATH` | Saves full session transcript for logging |

For all other CLI flags, file locations, agent file format, and config resolution, see the **[official CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)**.
