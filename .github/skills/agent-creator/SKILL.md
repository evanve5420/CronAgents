---
name: agent-creator
description: "Use when asked to create a new CronAgents agent or prompt-only scheduled invocation. Helps create the required agent profile and registration in the personal repo."
argument-hint: "Describe what the agent should do (e.g., 'review PRs every morning')"
---

# Agent Creator

Create a CronAgents scheduled entry: either a custom agent (`.agent.md` + `.agent-registration.json`) or a prompt-only invocation (`.agent-registration.json` only).

## Personal Repo Setup — Do This Before Creating Anything

Agent definitions and registrations live in the user's **personal repo** (`~/.cronagents/`), not in the infra repo.

1. Load the shared module and check the personal repo:
   ```powershell
   Import-Module scheduler/lib/CronAgents.psd1 -Force
   Import-CronAgentsConfig
   $repoPath = Get-PersonalRepoPath
   $valid = Test-PersonalRepoValid
   ```
2. If the personal repo doesn't exist or isn't valid, initialize it:
   ```powershell
   Initialize-PersonalRepo
   ```
3. Agent files go in:
   - **Agent profiles:** `~/.cronagents/.github/agents/<agent-name>.agent.md`
   - **Registrations:** `~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json`
4. No branch switching is needed — the personal repo is a standalone git repository.

## Interview the User

Skip anything already clear from context:

1. **What should it do?**
2. **Schedule** — daily at 9am, every 4h, weekly Monday, etc.
3. **Agent or prompt-only?** — Prompt-only is simpler when no custom system instructions or tool scoping is needed. Agent mode when the task needs custom behavior, tool restrictions, or a system prompt.
4. **What tools does it need?** — Scope to the **minimum required**. Start restrictive; the user can expand later. See [AGENT-PROFILE.md](references/AGENT-PROFILE.md) for common tool sets.
5. **Model preference?**
6. **Execution policies?** — timeout, skip on battery, retry on failure, `runIf` (see [RUNIF.md](references/RUNIF.md)), notify on failure (`notifyOnFailure`)
7. **Agent profile placement (agent mode only)** — personal repo `.github/agents/` (default) or user-global `~/.copilot/agents/`
8. **Working directory?** — which project directory the agent should run in (null = allow all via `--allow-all`)

## Create

For field details, see [REGISTRATION-FIELDS.md](references/REGISTRATION-FIELDS.md).

### Agent mode

Custom agent profile — see [AGENT-PROFILE.md](references/AGENT-PROFILE.md) for format and tool scoping:

```markdown
# ~/.cronagents/.github/agents/<agent-name>.agent.md
---
name: <agent-name>
description: "<one-line description>"
tools:
  - <minimum tools needed>
---

<System prompt>
```

CronAgents registration file — **filename stem = stable agent ID**:

```jsonc
// ~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "agent": "<agent-name>",
  "prompt": "<run prompt>",
  "schedule": { "type": "daily", "time": "09:00" }
}
```

### Prompt-only mode

No `.agent.md`. Omit `agent` field — scheduler invokes `copilot -p` with `--allow-all-tools`. Use `denyTools` to restrict.

```jsonc
// ~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json
{
  "$schema": "../../cronagents-agent.schema.json",
  "name": "<Display Name>",
  "prompt": "<full prompt>",
  "schedule": { "type": "daily", "time": "09:00" },
  "denyTools": ["shell(rm)", "shell(git push)"]
}
```

### Companion SKILL.md (optional, agent mode only)

Create in `~/.cronagents/.github/skills/<agent-name>/SKILL.md` if the agent needs domain knowledge.

## Validate

- Agent mode: `.agent.md` lives in `~/.cronagents/.github/agents/` or `~/.copilot/agents/`, has explicit `tools` list (least-privilege), and `agent` in the registration matches the `.agent.md` name
- Prompt-only: registration has `prompt` + `schedule`, no `agent` field, `denyTools` considered
- Both: registration file is named `~/.cronagents/.cronagents/agents/<agent-id>.agent-registration.json`
- Both: schedule type is `interval`/`daily`/`weekly`, test with `cronagents.ps1 run <agent-id>`

## Agent Questions (Deferred Decisions)

Agents can write a `questions.json` file into their run output directory to ask the user operational questions. This is useful when an agent encounters gray-area decisions that need human input (e.g., "Should I move these 7 items to Clients/Acme?").

**How it works:**
1. Agent writes `questions.json` to its run output directory during the run
2. After the run completes, the scheduler reads `questions.json` from the run directory and persists it to `.cronstate/pending-questions/<agent-id>.json`
3. The agent's next scheduled run is **blocked** until all questions are answered
4. User answers via `cronagents.ps1 questions` or the TUI menu
5. Answers are injected into the next run via `--share=answers.json`
6. Unanswered questions auto-expire after `questionExpirationDays` (default 7, configurable in `cronagents.json`, 0 = never)

**Question format** (what the agent writes):
```json
[
  {
    "id": "unique-question-id",
    "question": "Should I move these items to Clients/Acme?",
    "choices": ["Yes, move them", "No, leave them", "Archive instead"],
    "recommended": "Yes, move them",
    "context": "Found 7 emails from acme.com dated Jan 10-15"
  }
]
```
- `id`: stable identifier (agent reuses same id to update the question on re-runs)
- `choices`: optional array of suggested answers (user can always provide a freeform response)
- `recommended`: optional — which choice the agent recommends
- `context`: optional — additional context to help the user decide
