# Workspace Instructions — CronAgents

## Core principles

1. **Generic, not personal.** This project is meant to be shared with coworkers and potentially open-sourced. Hardcode nothing specific to any user, machine, path, or environment. All user-specific values must come from config (`cronagents.json`), environment variables, or runtime detection (e.g., `$env:USERNAME`, `git config user.name`). File paths must be relative to the repo root or resolved dynamically.

2. **No duplicated logic.** Make use of the shared PowerShell module (`scheduler/lib/CronAgents.psd1`) and its nested modules. If a function is needed in more than one script, it belongs in `lib/`. The CLI wrapper, scheduler, health check, and tests must all call the same functions — never reimplement.

3. **Cross-platform safe.** CI runs on Linux (Ubuntu) via PowerShell Core. Avoid Windows-only APIs (`Get-CimInstance Win32_*`, `[wmi]`, `Get-WmiObject`, Windows Registry, etc.) in any code path exercised by tests. When platform-specific logic is unavoidable, branch on `$IsWindows` (remembering it doesn't exist in Windows PowerShell 5.1 — guard with `Test-Path variable:IsWindows`) and provide a Linux fallback (e.g., `/proc/<pid>/cmdline`). Tag tests that genuinely require Windows with `'WindowsOnly'` so CI can exclude them.

## Keep in sync

When changing the config schema (`cronagents.json`, `cronagents.schema.json`, `cronagents-agent.schema.json`) or `.agent.md` structure, update `.github/skills/creating-agents/SKILL.md` to match. That skill is how users create new agents — if it falls out of date, they'll get bad scaffolding.

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

## Before creating a PR

Invoke the **custom** `code-reviewer` agent (defined in `.github/agents/code-reviewer.agent.md`) as a subagent to review all changes before opening a pull request. **Do NOT use the built-in `code-review` agent type** — it lacks the project-specific sub-agent orchestration (security, privacy, a11y, maintainability, docs reviewers). The correct Task tool call is `agent_type: "code-reviewer"`, not `agent_type: "code-review"`. Skip this step for changes that are exclusively documentation or confined to `.github/`. For sufficiently simple or trivial changes, ask the user whether a review is needed before invoking.
