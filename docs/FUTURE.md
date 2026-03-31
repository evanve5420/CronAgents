# Future Considerations

Items beyond day-0 scope. Each is tracked here so PLAN.md stays focused on the build.

Items are grouped by expected timeframe: **near-term** (natural next steps once day 0 is solid), **medium-term** (worth doing if the project gains traction), and **far-future** (only if things really take off).

---

## Near-Term

### 1. HTML Dashboard ✅

> **Implemented.** See `scheduler/Start-DashboardServer.ps1`, `scheduler/dashboard.html`, and `cronagents.ps1 dashboard`.

Requirements originally captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md). The dashboard is a PowerShell `System.Net.HttpListener` micro-server on `localhost:9077` serving a single-file vanilla HTML/JS/CSS frontend. It exposes a JSON API mirroring the CLI commands (status, agents, runs, pause/resume, trigger runs, feedback, questions) and auto-refreshes every 5 seconds. Launch via `cronagents.ps1 dashboard` or TUI menu option 8.

### 2. Agent Tags / Groups

`"tags": ["review", "maintenance"]` per agent, then `cronagents.ps1 pause --tag=review`. As agent count grows, managing them individually gets tedious. The tag filtering is just a `Where-Object` on the config array — minimal code.

### 3. Feedback Evaluator Edit Scope

A config-level `editScope` per agent restricting which paths the evaluator can modify when processing feedback for that agent. Currently enforced only by the evaluator's prompt instructions ("cannot edit scheduler scripts"). A config allowlist (e.g., `"editScope": [".cronagents/agents/daily-review*"]`) lets the scheduler validate the evaluator's edits after the fact and reject out-of-scope changes before committing.

### 4. Success Toasts

Per-agent `"notifyOnSuccess": true` for success toasts (e.g. confirming a critical daily agent completed). Not implemented yet — current design only notifies on failure.

### 5. GitHub Remote for Personal Repo

Auto-create a private GitHub repo (`cronagents-personal`) during `cronagents.ps1 install` for backup and cross-machine sync of the personal agents repo. Configurable — users who don't want a remote can delete it. Requires `gh` CLI authentication.

### 6. Script Mode Execution

Allow agent entries to specify a `script` path instead of `agent`+`prompt`, so the scheduler runs a user-provided script (which may invoke Copilot CLI internally, or not at all). Covers token-efficient pre-work patterns, existing workflow automation, and general-purpose scheduling. Same timeout/retry/pause/logging benefits as prompt mode. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).

### 7. Security Review Agent

A scaffold-internal agent that reviews recent diffs to agent definitions, skills, config, and feedback for harmful patterns. Runs after the feedback-commit hook but before the next scheduled agents execute, so poisoned edits are caught before they take effect. Would watch for: prompt injection in agent definitions, unexpected tool additions/`--deny-tool` removals, feedback content attempting to manipulate the evaluator, and anomalous output patterns suggesting data exfiltration. Flagged issues auto-pause the affected agent and notify via dashboard/TUI. The infrastructure for this already exists: git branch diffs from agent versioning, pre-edit snapshots, and feedback-result.md changelogs provide structured input. Attack pattern knowledge would accumulate in a dedicated skill file (`scheduler/skills/security-reviewer/SKILL.md`) that can be community-contributed. See [security-review-agent-landscape.md](security-review-agent-landscape.md) for detailed landscape research and implementation guidance.

### 8. User Questions / Deferred Decisions ✅

> **Implemented.** See `scheduler/lib/QuestionsManager.ps1`, `cronagents.ps1 questions`, and the TUI "Pending questions" menu option.

Agents can write a `questions.json` file into their run directory with operational questions for the user. After the run completes, the scheduler (`Invoke-ScheduledAgent.ps1`) discovers this file and persists/merges it into `.cronstate/pending-questions/<agent-id>.json`. It then blocks the agent's next scheduled run until all questions are answered and injects the answers via `--share=answers.json` on the next run. Questions auto-expire after `questionExpirationDays` (default 7, 0 = never). The dashboard summary table shows a Questions column linking to a generated `questions.md` file.

---

## Medium-Term

### 9. Parallel Execution & Agent Dependencies

Currently agents run sequentially in discovery order. A future version could add parallel execution for independent agents plus a `dependsOn: ["other-agent-id"]` config to express ordering constraints, with the scheduler building a dependency graph and running independent branches concurrently. Parallelism would make 30-minute schedules more attractive, but it adds complexity: Copilot CLI rate limits, concurrent `.cronstate/state.json` access (already designed with file-level locking), output interleaving, and topological sort. Not worth it until someone has enough agents to feel the sequential bottleneck. Run directory naming already includes a random nonce to prevent collisions.

### 10. Cloud Reporting

Local markdown now, but `Update-Dashboard.ps1` is designed to be extensible to webhooks/Slack/Teams.

### 11. Cross-Platform

PowerShell Core runs on macOS/Linux, but initial target is Windows only. macOS would need `launchd` instead of Task Scheduler. Linux would need systemd user services or cron.

### 12. Expand PR Coverage to Windows

Pull request test gating already exists: `.github/workflows/tests.yml` runs the non-Windows test suite on `ubuntu-latest` for pull requests to `master`. The remaining future work is adding a separate `windows-latest` job so tests tagged `WindowsOnly` (Health Check, CLI doctor) are covered in CI too — acceptable once the project has enough churn to justify the extra Actions cost.

### 13. Agent Pipelines

`"dependsOn": ["data-gather"]` with output passing: the output of one agent becomes context for the next. This is the compositional version of agent dependencies — chaining data through a sequence rather than just ordering execution.

### 14. Rate Limiting

Global cap on Copilot CLI invocations per hour. Prevents a misconfigured schedule from hammering the API. `"rateLimits": { "maxRunsPerHour": 10 }`.

### 15. SQLite State Backend

Replace `StateManager.ps1`'s JSON file backend with SQLite. The `StateManager` module boundary already abstracts all state access — swapping the backing store is an internal change. Worth considering when token budget tracking, rate limiting, run history queries, or parallel execution make flat JSON painful. Day 0 JSON files are the right starting point.

---

## Far-Future

### 16. Token / Cost Budgets

`"tokenBudget": { "daily": 50000, "monthly": 500000 }` per agent or globally. Track cumulative token usage from `--output-format=json` metadata across runs. Auto-pause agents that exceed their budget. Becomes important with many agents running frequently and predictable costs are needed.

### 17. Config Profiles / Inheritance

A base `cronagents.json` with environment overlays: `cronagents.work.json` for work hours, `cronagents.home.json` for personal projects. `cronagents.ps1 --profile=work`. Useful when one machine serves multiple contexts.

### 18. Webhook Triggers

An HTTP endpoint (from the future dashboard server) that can trigger agent runs. `POST /api/trigger/daily-review` from a GitHub webhook fires on push. Blurs the line between scheduled and event-driven, but the infrastructure is already there in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md).

### 19. Remote Config

Pull config from a URL or git ref so teams can centrally manage agent definitions. `"configSource": "https://..."` or `"configRef": "origin/main:cronagents.json"`. Relevant when you have many coworkers and want consistent agent behavior.
