# Future Considerations

Items beyond day-0 scope. Each is tracked here so PLAN.md stays focused on the build.

---

## 1. HTML Dashboard

Requirements captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md). Only worth doing after the CLI wrapper proves the command set.

## 2. Parallel Execution & Agent Dependencies

Currently agents run sequentially in config array order (the user controls execution order by arranging the `agents` array). A future version could add parallel execution for independent agents plus a `dependsOn: ["other-agent"]` config to express ordering constraints, with the scheduler building a dependency graph and running independent branches concurrently. Parallelism would make 30-minute schedules more attractive, but it adds complexity: Copilot CLI rate limits, concurrent `state.json` access, output interleaving, and topological sort. Not worth it until someone has enough agents to feel the sequential bottleneck.

## 3. Cloud Reporting

Local markdown now, but `Update-Dashboard.ps1` is designed to be extensible to webhooks/Slack/Teams.

## 4. Cross-Platform

PowerShell Core runs on macOS/Linux, but initial target is Windows only.

## 5. PR Gate Enforcement

The test suite is already structured for CI (`Invoke-Pester ./tests/ -ExcludeTag 'E2E'`). A future GitHub Actions workflow can run this as a required status check on PRs. Currently enforced via `copilot-instructions.md` only.

## 6. Script Mode Execution

Allow agent entries to specify a `script` path instead of `agent`+`prompt`, so the scheduler runs a user-provided script (which may invoke Copilot CLI internally, or not at all). Covers token-efficient pre-work patterns, existing workflow automation, and general-purpose scheduling. Same timeout/retry/pause/logging benefits as prompt mode. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).

## 7. Security Review Agent

A scaffold-internal agent that reviews recent diffs to agent definitions, skills, config, and feedback for harmful patterns. Runs after the feedback-commit hook but before the next scheduled agents execute, so poisoned edits are caught before they take effect. Would watch for: prompt injection in agent definitions, unexpected tool additions/`--deny-tool` removals, feedback content attempting to manipulate the evaluator, and anomalous output patterns suggesting data exfiltration. Flagged issues auto-pause the affected agent and notify via dashboard/TUI. The infrastructure for this already exists: git branch diffs from agent versioning, pre-edit snapshots, and feedback-result.md changelogs provide structured input. Attack pattern knowledge would accumulate in a dedicated skill file (`scheduler/skills/security-reviewer/SKILL.md`) that can be community-contributed.
