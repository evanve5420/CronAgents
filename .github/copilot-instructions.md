# Workspace Instructions — CronAgents

## Core principles

1. **Generic, not personal.** This project is meant to be shared with coworkers and potentially open-sourced. Hardcode nothing specific to any user, machine, path, or environment. All user-specific values must come from config (`cronagents.json`), environment variables, or runtime detection (e.g., `$env:USERNAME`, `git config user.name`). File paths must be relative to the repo root or resolved dynamically.

2. **No duplicated logic.** Make use of the shared PowerShell module (`scheduler/lib/CronAgents.psd1`) and its nested modules. If a function is needed in more than one script, it belongs in `lib/`. The CLI wrapper, scheduler, health check, and tests must all call the same functions — never reimplement.

## Keep in sync

When changing the config schema (`cronagents.json`, `cronagents.schema.json`, `cronagents-agent.schema.json`) or `.agent.md` structure, update `.github/skills/creating-agents/SKILL.md` to match. That skill is how users create new agents — if it falls out of date, they'll get bad scaffolding.

## Before creating a PR

Invoke the `code-reviewer` agent as a subagent to review all changes before opening a pull request.

## Before committing

Run all non-E2E tests and verify they pass:

```powershell
./tests/Invoke-Tests.ps1
```

No need to run tests for doc only changes.

> **Note:** `Invoke-Pester ./tests/ -ExcludeTag 'E2E'` hangs when all 15 test
> containers import `CronAgents.psd1` in a single process. `Invoke-Tests.ps1`
> runs each file in its own `pwsh` subprocess with a default maximum of 8
> concurrent workers for reliable, isolated execution.
