# Future Considerations

Items beyond day-0 scope. Each is tracked here so PLAN.md stays focused on the build.

Items are grouped by expected timeframe: **near-term** (natural next steps once day 0 is solid), **medium-term** (worth doing if the project gains traction), and **far-future** (only if things really take off).

---

## Near-Term

### 1. HTML Dashboard

Requirements captured in [UX-REQUIREMENTS.md](UX-REQUIREMENTS.md). Only worth doing after the CLI wrapper proves the command set.

### 2. Conditional Execution

Baseline `runIf` support now exists with `"git-dirty"`, `"file-changed:<path>"`, and `{ "script": "relative/path.ps1" }`. Future expansion here would mean adding richer predicates (for example branch-aware checks, multiple files, or compound conditions) without giving up the current lightweight state model.

### 3. Agent Tags / Groups

`"tags": ["review", "maintenance"]` per agent, then `cronagents.ps1 pause --tag=review`. As agent count grows, managing them individually gets tedious. The tag filtering is just a `Where-Object` on the config array — minimal code.

### 4. Feedback Evaluator Edit Scope

A config-level `editScope` per agent restricting which paths the evaluator can modify when processing feedback for that agent. Currently enforced only by the evaluator's prompt instructions ("cannot edit scheduler scripts"). A config allowlist (e.g., `"editScope": [".cronagents/agents/daily-review*"]`) lets the scheduler validate the evaluator's edits after the fact and reject out-of-scope changes before committing.

### 5. Windows Notifications

Per-agent `"notifyOnFailure": true` that triggers a Windows toast notification (`New-BurntToastNotification` or native `[Windows.UI.Notifications]`) when an agent errors. Users may not check the dashboard for hours. Opt-in and gracefully degrade if the notification module isn't installed.

### 6. GitHub Remote for Personal Repo

Auto-create a private GitHub repo (`cronagents-personal`) during `cronagents.ps1 install` for backup and cross-machine sync of the personal agents repo. Configurable — users who don't want a remote can delete it. Requires `gh` CLI authentication.

### 7. Script Mode Execution

Allow agent entries to specify a `script` path instead of `agent`+`prompt`, so the scheduler runs a user-provided script (which may invoke Copilot CLI internally, or not at all). Covers token-efficient pre-work patterns, existing workflow automation, and general-purpose scheduling. Same timeout/retry/pause/logging benefits as prompt mode. Full design in [SCRIPT-MODE.md](SCRIPT-MODE.md).

### 8. Security Review Agent

A scaffold-internal agent that reviews recent diffs to agent definitions, skills, config, and feedback for harmful patterns. Runs after the feedback-commit hook but before the next scheduled agents execute, so poisoned edits are caught before they take effect. Would watch for: prompt injection in agent definitions, unexpected tool additions/`--deny-tool` removals, feedback content attempting to manipulate the evaluator, and anomalous output patterns suggesting data exfiltration. Flagged issues auto-pause the affected agent and notify via dashboard/TUI. The infrastructure for this already exists: git branch diffs from agent versioning, pre-edit snapshots, and feedback-result.md changelogs provide structured input. Attack pattern knowledge would accumulate in a dedicated skill file (`scheduler/skills/security-reviewer/SKILL.md`) that can be community-contributed.

Bonus 1:  set up capability for certain agents to be able to request actions or ask questions of the user. For instance, an inbox tidying agent which asks the user, "Is it okay if I move these seven items to this directory?" The user should have a whole new space to be able to respond to that. On the next turn, the next cron job, that agent should be able to pick that up and apply it. 

---

## Medium-Term

### 9. Parallel Execution & Agent Dependencies

Currently agents run sequentially in discovery order. A future version could add parallel execution for independent agents plus a `dependsOn: ["other-agent-id"]` config to express ordering constraints, with the scheduler building a dependency graph and running independent branches concurrently. Parallelism would make 30-minute schedules more attractive, but it adds complexity: Copilot CLI rate limits, concurrent `.cronstate/state.json` access (already designed with file-level locking), output interleaving, and topological sort. Not worth it until someone has enough agents to feel the sequential bottleneck. Run directory naming already includes a random nonce to prevent collisions.

### 10. Cloud Reporting

Local markdown now, but `Update-Dashboard.ps1` is designed to be extensible to webhooks/Slack/Teams.

### 11. Cross-Platform

PowerShell Core runs on macOS/Linux, but initial target is Windows only. macOS would need `launchd` instead of Task Scheduler. Linux would need systemd user services or cron.

### 12. PR Gate Enforcement

A GitHub Actions workflow (`.github/workflows/tests.yml`) runs the cross-platform test suite on `ubuntu-latest` as a required status check on PRs to `master`. Tests tagged `WindowsOnly` (Health Check, CLI doctor) are excluded from this workflow since they depend on Windows Task Scheduler APIs. A future improvement would add a separate `windows-latest` job to cover those tests — acceptable cost once the project gains contributors, but not worth the 2× Actions billing multiplier today.

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
