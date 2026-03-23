# Copilot CLI Reference (verified March 2026)

The old `gh copilot` extension was retired October 2025. The replacement is the standalone **GitHub Copilot CLI** (`github/copilot-cli`), installed via `winget install GitHub.Copilot` on Windows.

## Programmatic invocation (how the scheduler calls agents)

```
copilot --agent=<name> -p "<prompt>" --allow-all-tools --silent --share=<path>
```

Key flags used by CronAgents:

| Flag | Purpose |
|------|---------|
| `-p` / `--prompt` | Run one prompt then exit |
| `--agent=NAME` | Use a specific custom agent (`.agent.md` file) |
| `--allow-all-tools` | Auto-approve all tool use for unattended runs |
| `--deny-tool=TOOL` | Block specific tools (e.g. `shell(rm)`) |
| `-s` / `--silent` | Output only agent response, no stats |
| `--share=PATH` | Save full session transcript to file |
| `--output-format=json` | JSONL output for machine parsing |
| `--add-dir=PATH` | Add trusted directory for file access |
| `--model=MODEL` | Override model for the session (e.g., `gpt-4o`, `claude-sonnet-4`) |
| `--no-ask-user` | Prevent agent from prompting for input |

## Custom agent file format

Agent profiles are `.agent.md` files with YAML frontmatter. Key fields: `name`, `description`, `tools` (list), `model`, `infer` (bool). Markdown body contains the agent prompt.

## File locations (Copilot CLI native resolution)

| What | Project-level | User-level |
|------|--------------|------------|
| Agents | `.github/agents/` | `~/.copilot/agents/` |
| Skills | `.github/skills/` | `~/.copilot/skills/` |
| Instructions | `.github/copilot-instructions.md` | `~/.copilot/copilot-instructions.md` |
| Config | `.github/copilot/settings.json` | `~/.copilot/config.json` |

Project-level overrides user-level on name collisions. `COPILOT_HOME` env var overrides the user config directory. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` adds extra instruction search paths.

Full CLI command reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference
