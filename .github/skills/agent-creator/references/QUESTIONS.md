# Agent Questions Reference

Agents can write a `questions.json` file into their run output directory to ask the user operational questions. This is useful when an agent encounters gray-area decisions that need human input (e.g., "Should I move these 7 items to Clients/Acme?").

## Lifecycle

1. Agent writes `questions.json` to its run output directory during the run
2. After the run completes, the scheduler reads `questions.json` from the run directory and persists it to `.cronstate/pending-questions/<agent-id>.json`
3. The agent's next scheduled run is **blocked** until all questions are answered
4. User answers via `cronagents.ps1 questions` or the TUI menu
5. Answers are injected into the next run via `--share=answers.json`
6. Unanswered questions auto-expire after `questionExpirationDays` (default 7, configurable in `cronagents.json`, 0 = never)

## Question format

What the agent writes to `questions.json`:

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

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Stable identifier. Agent reuses same id to update the question on re-runs. |
| `question` | Yes | The question text shown to the user. |
| `choices` | No | Array of suggested answers. User can always provide a freeform response instead. |
| `recommended` | No | Which choice the agent recommends (must match a `choices` entry). |
| `context` | No | Additional context to help the user decide. |

## Configuration

Set `questionExpirationDays` in `cronagents.json` (global config):

- Default: `7` — questions expire after 7 days
- Set to `0` to disable expiration (questions persist until answered)
