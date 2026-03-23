# Future Considerations

Items beyond day-0 scope. Each is tracked here so PLAN.md stays focused on the build.

Items are grouped by expected timeframe: **near-term** (natural next steps once day 0 is solid), **medium-term** (worth doing if the project gains traction), and **far-future** (only if things really take off).

---

## Near-Term

### 1. HTML Dashboard

Requirements captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md). Only worth doing after the CLI wrapper proves the command set.

### 2. Conditional Execution

A `runIf` predicate per agent: only run when a condition is met. Day-0 candidates: `"runIf": "git-dirty"` (new commits since last run), `"runIf": "file-changed:package.json"`. Avoids burning tokens on no-op runs where nothing in the repo changed. The scheduler already tracks state — adding a "last seen commit hash" or file mtime check is lightweight.

### 3. Agent Tags / Groups

`"tags": ["review", "maintenance"]` per agent, then `chronagents.ps1 pause --tag=review`. As agent count grows, managing them individually gets tedious. The tag filtering is just a `Where-Object` on the config array — minimal code.

### 4. Feedback Evaluator Edit Scope

A config-level `editScope` per agent restricting which paths the evaluator can modify when processing feedback for that agent. Currently enforced only by the evaluator's prompt instructions ("cannot edit scheduler scripts"). A config allowlist (e.g., `"editScope": [".chronagents/agents/daily-review*"]`) lets the scheduler validate the evaluator's edits after the fact and reject out-of-scope changes before committing.

### 5. Windows Notifications

Per-agent `"notifyOnFailure": true` that triggers a Windows toast notification (`New-BurntToastNotification` or native `[Windows.UI.Notifications]`) when an agent errors. Users may not check the dashboard for hours. Opt-in and gracefully degrade if the notification module isn't installed.

### 6. Script Mode Execution

Allow agent entries to specify a `script` path instead of `agent`+`prompt`, so the scheduler runs a user-provided script (which may invoke Copilot CLI internally, or not at all). Covers token-efficient pre-work patterns, existing workflow automation, and general-purpose scheduling. Same timeout/retry/pause/logging benefits as prompt mode. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).

### 7. Security Review Agent

A scaffold-internal agent that reviews recent diffs to agent definitions, skills, config, and feedback for harmful patterns. Runs after the feedback-commit hook but before the next scheduled agents execute, so poisoned edits are caught before they take effect. Would watch for: prompt injection in agent definitions, unexpected tool additions/`--deny-tool` removals, feedback content attempting to manipulate the evaluator, and anomalous output patterns suggesting data exfiltration. Flagged issues auto-pause the affected agent and notify via dashboard/TUI. The infrastructure for this already exists: git branch diffs from agent versioning, pre-edit snapshots, and feedback-result.md changelogs provide structured input. Attack pattern knowledge would accumulate in a dedicated skill file (`scheduler/skills/security-reviewer/SKILL.md`) that can be community-contributed.

---

## Medium-Term

### 8. Parallel Execution & Agent Dependencies

Currently agents run sequentially in discovery order. A future version could add parallel execution for independent agents plus a `dependsOn: ["other-agent-id"]` config to express ordering constraints, with the scheduler building a dependency graph and running independent branches concurrently. Parallelism would make 30-minute schedules more attractive, but it adds complexity: Copilot CLI rate limits, concurrent `.chronstate/state.json` access (already designed with file-level locking), output interleaving, and topological sort. Not worth it until someone has enough agents to feel the sequential bottleneck. Run directory naming already includes a random nonce to prevent collisions.

### 9. Cloud Reporting

Local markdown now, but `Update-Dashboard.ps1` is designed to be extensible to webhooks/Slack/Teams.

### 10. Cross-Platform

PowerShell Core runs on macOS/Linux, but initial target is Windows only. macOS would need `launchd` instead of Task Scheduler. Linux would need systemd user services or cron.

### 11. PR Gate Enforcement

The test suite is already structured for CI (`Invoke-Pester ./tests/ -ExcludeTag 'E2E'`). A future GitHub Actions workflow can run this as a required status check on PRs. Currently enforced via `copilot-instructions.md` only.

### 12. Agent Pipelines

`"dependsOn": ["data-gather"]` with output passing: the output of one agent becomes context for the next. This is the compositional version of agent dependencies — chaining data through a sequence rather than just ordering execution.

### 13. Rate Limiting

Global cap on Copilot CLI invocations per hour. Prevents a misconfigured schedule from hammering the API. `"rateLimits": { "maxRunsPerHour": 10 }`.

### 14. SQLite State Backend

Replace `StateManager.ps1`'s JSON file backend with SQLite. The `StateManager` module boundary already abstracts all state access behind `Get-AgentState` / `Set-AgentState` — swapping the backing store would be an internal change with no impact on callers. SQLite is single-file, zero-server, and handles concurrent writers natively with WAL mode.

**Trigger points** (when the JSON file approach starts to hurt):
- **Token budget tracking** (#15) — cumulative counters with atomic increment-and-check across many agents
- **Rate limiting** (#13) — sliding window queries ("how many runs in the last hour?") are painful in flat JSON
- **Run history queries** — the HTTP dashboard needs filtered/sorted/paginated run data; scanning `meta.json` files in `.chronstate/runs/` directories doesn't scale
- **Parallel execution** (#8) — SQLite's built-in concurrency is more robust than file-level locks

Day 0 JSON files are the right starting point — zero dependencies, human-readable, trivially debuggable. SQLite becomes worth it when any of the above trigger points arrive.

---

## Far-Future

### 15. Token / Cost Budgets

`"tokenBudget": { "daily": 50000, "monthly": 500000 }` per agent or globally. Track cumulative token usage from `--output-format=json` metadata across runs. Auto-pause agents that exceed their budget. Becomes important with many agents running frequently and predictable costs are needed.

### 16. Config Profiles / Inheritance

A base `chronagents.json` with environment overlays: `chronagents.work.json` for work hours, `chronagents.home.json` for personal projects. `chronagents.ps1 --profile=work`. Useful when one machine serves multiple contexts.

### 17. Webhook Triggers

An HTTP endpoint (from the future dashboard server) that can trigger agent runs. `POST /api/trigger/daily-review` from a GitHub webhook fires on push. Blurs the line between scheduled and event-driven, but the infrastructure is already there in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md).

### 18. Remote Config

Pull config from a URL or git ref so teams can centrally manage agent definitions. `"configSource": "https://..."` or `"configRef": "origin/main:chronagents.json"`. Relevant when you have many coworkers and want consistent agent behavior.
