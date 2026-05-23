# CronAgents — Scheduled Copilot Agent Scaffolding

A lightweight, agent scheduler for GitHub Copilot agents that runs recurring workflows, writes markdown dashboards, and uses human feedback to improve agent definitions over time.

## Feature highlights

- **Scheduled agent runs** — interval, daily, or weekly execution via a single background process
- **Agent + prompt-only modes** — full `.agent.md` agents or simple prompt-only invocations
- **Live markdown dashboard** — auto-generated `dashboard.md` with run summaries, status, and links
- **HTML dashboard** — browser-based management UI at `127.0.0.1:9077` with live status, agent controls, configuration details, feedback, and questions
- **Human feedback loop** — write feedback on any run, an evaluator agent edits agent definitions accordingly
- **Separate personal repo** — agent definitions live in `~/.cronagents/`, fully isolated from shared infrastructure
- **CLI + interactive TUI** — `cronagents.ps1` with subcommands and a numbered menu
- **Health checks** — `cronagents.ps1 doctor` verifies task registration, config, state integrity
- **Copilot-native** — built on `.agent.md`, `SKILL.md`, and Copilot CLI primitives
- **Windows-first** — PowerShell + Task Scheduler, zero external dependencies

## Quick start

> For full details see [Getting Started](guide/getting-started.md).

Choose the path that matches your starting point:

- **Copilot CLI already installed + signed in** — open Copilot CLI in this repo and say:

  ```text
  Read guide/getting-started.md and set up CronAgents in this repository for me.
  ```

- **Copilot CLI not ready yet** — follow [Getting Started](guide/getting-started.md) to install or authenticate Copilot CLI first, then come back to the prompt above.

- **Prefer the manual path** — run the setup commands yourself:

  ```powershell
  # Install (registers at-logon task, initializes personal repo)
  .\cronagents.ps1 install

  # Create your first agent (interactive skill)
  # /creating-agents "review PRs every morning"

  # Or copy a template into your personal repo
  Copy-Item templates\agents\daily-review.agent.md.example ~/.cronagents/.github/agents/daily-review.agent.md
  # Then create ~/.cronagents/.cronagents/agents/daily-review.agent-registration.json
  # (see guide/writing-agents.md)

  # Test it
  .\cronagents.ps1 run daily-review

  # Check results
  .\cronagents.ps1 status
  ```

## How it works

1. A single background scheduler process starts at logon via Task Scheduler.
2. It reads agent registrations from the personal repo (`~/.cronagents/.cronagents/agents/`).
3. On each tick it evaluates schedules and runs due agents via Copilot CLI.
4. Output is captured, summaries are generated, and the dashboard is updated.
5. An optional feedback loop lets humans review runs — an evaluator agent applies that feedback to improve agent definitions over time.

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](guide/getting-started.md) | Prerequisites, install, first run |
| [Configuration](guide/configuration.md) | All config fields, defaults, examples |
| [CLI Reference](guide/cli-reference.md) | Subcommands, TUI menu, --help |
| [Writing Agents](guide/writing-agents.md) | Create and register scheduled agents |
| [Feedback System](guide/feedback-system.md) | How the feedback loop works |
| [Branching & Sync](guide/branching-and-sync.md) | Personal repo model, shared dev workflow |
| [Troubleshooting](guide/troubleshooting.md) | Common issues, health checks, logs |

## Project structure

```
CronAgents/
├── cronagents.ps1              # CLI entry point
├── cronagents.json             # Global config (repo-level defaults)
├── scheduler/                  # Background scheduler + shared library
│   ├── CronAgents-Scheduler.ps1
│   └── lib/                    # Shared PowerShell module (CronAgents.psd1)
├── templates/                  # Starter agent + config templates
│   └── agents/                 # Example .agent.md files
├── guide/                      # User-facing documentation
├── docs/                       # Design docs and architecture notes
└── tests/                      # Pester tests

~/.cronagents/                  # Personal repo (per-user, separate git repo)
├── .github/agents/             # Agent profiles (.agent.md)
├── .cronagents/agents/         # Agent registrations + schedule configs
├── .cronstate/                 # Run state, logs, dashboard output (git-ignored)
└── cronagents.json             # Personal config overrides (optional)
```

## License

MIT — see [LICENSE](LICENSE).

