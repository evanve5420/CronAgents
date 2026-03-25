# Feedback System

CronAgents includes a feedback loop that lets you improve agents over time by writing plain-language feedback after each run. A feedback-evaluator agent reads your notes and makes targeted edits to the agent's definition files.

## How it works

```
You run agent → Output captured → You write feedback → Evaluator edits agent → Agent improves
```

1. **Agent runs** (scheduled or ad-hoc). Output is captured in a run directory.
2. **Feedback stub created.** A `feedback.md` file is placed in the run directory with comment placeholders.
3. **You write feedback.** Open the file, describe what was good or bad in plain language.
4. **Evaluator processes.** The feedback-evaluator agent reads your feedback alongside the run output, then makes targeted edits to the agent's `.agent.md` and skill files.
5. **Results recorded.** A `feedback-result.md` changelog shows exactly what changed.
6. **Changes committed.** If `autoCommitFeedback` is enabled, edits are automatically committed to git.

---

## Run directory structure

After each agent run, the scheduler creates a timestamped directory:

```
.cronstate/runs/20240115T143022_daily-review_a1b2/
├── output.md            # Agent's raw output (captured stdout)
├── summary.md           # LLM-generated summary
├── meta.json            # Run metadata (timing, exit code, feedback status)
├── session.md           # Full session transcript
├── feedback.md          # Your feedback goes here
├── feedback-result.md   # Evaluator's changelog (after processing)
└── scheduler.log        # Per-run debug log
```

| File | Written by | Purpose |
|------|-----------|---------|
| `output.md` | Agent (captured) | What the agent produced |
| `summary.md` | Run-summarizer agent | Brief summary for dashboard |
| `meta.json` | Scheduler | Metadata: agent ID, timing, exit code, feedback status |
| `session.md` | Copilot CLI | Full session transcript |
| `feedback.md` | You | Your feedback in plain language |
| `feedback-result.md` | Feedback evaluator | Changelog of edits made |
| `scheduler.log` | Scheduler | Debug-level log for this run |

---

## Writing feedback

### Open the feedback file

Use the CLI to find and open the most recent pending feedback:

```powershell
# Open most recent pending feedback (any agent)
.\cronagents.ps1 feedback

# Open most recent pending feedback for a specific agent
.\cronagents.ps1 feedback daily-review
```

This opens `feedback.md` in your default editor. You can also navigate to the run directory directly under `.cronstate/runs/`.

### What to write

Write plain, natural language. Be specific about what you want changed. The evaluator is an LLM — it understands context.

**Good feedback examples:**

```markdown
Too verbose. Focus only on security issues, skip style nits.
```

```markdown
The grep pattern missed files in src/utils/. Add that directory to the search scope.
```

```markdown
Good output overall, but the summary section should come first before the detailed findings.
```

```markdown
Stop suggesting dependency updates that are major version bumps.
Only flag minor and patch updates.
```

**Less useful feedback:**

```markdown
Bad output.
```

```markdown
Fix it.
```

The more specific you are about what to change, the better the evaluator can target its edits.

### What the evaluator can edit

The feedback evaluator has access to `read`, `edit`, and `search` tools. It can modify:

- **`.agent.md` files** — system prompt, tool scoping, instructions
- **`SKILL.md` files** — domain knowledge, procedures, reference material
- **Instruction files** — any supporting documentation the agent references

It **cannot** edit:

- Scheduler scripts (`scheduler/`, `cronagents.ps1`)
- Config schemas (`cronagents.schema.json`, `cronagents-agent.schema.json`)
- Its own definition files
- Schedule configs (`.json` files) — you change these manually

---

## Processing feedback

### Manual processing

Run the evaluate command to process all pending feedback:

```powershell
.\cronagents.ps1 evaluate
```

This finds all run directories where:
- `feedback.md` contains non-comment content (your feedback)
- `meta.json` has `feedbackProcessed: false`

For each one, the feedback-evaluator agent is invoked with the run directory and agent definition paths.

### Auto-feedback mode

Set `autoFeedback: true` in `cronagents.json` to have the scheduler automatically check for and process feedback on each tick:

```json
{
  "autoFeedback": true
}
```

With auto-feedback enabled, the workflow is:

1. Agent runs and creates output
2. On the next scheduler tick, the scheduler checks for unprocessed feedback
3. If feedback is present, the evaluator is invoked immediately
4. Results appear in `feedback-result.md`

This means you can write feedback at any time, and it will be processed within ~60 seconds (the scheduler tick interval).

---

## Feedback results

After the evaluator runs, it writes `feedback-result.md` in the run directory:

```markdown
## Changes Made

- **File**: `.github/agents/daily-review.agent.md`
  **Change**: Tightened system prompt to focus only on security issues,
  removed verbose analysis instructions.

- **File**: `.github/agents/daily-review.agent.md`
  **Change**: Updated grep pattern to include src/utils/ folder
  in search scope.

## Summary

Focused security scanning on high-priority areas.
```

The evaluator also updates `meta.json` to set `feedbackProcessed: true`, preventing the same feedback from being processed again.

---

## Automatic git commits

When `versioning.autoCommitFeedback` is `true` (the default), the scheduler automatically commits the evaluator's changes:

```
feedback: daily-review — Focused security scanning on high-priority areas
```

The commit includes only the files the evaluator modified (typically `.agent.md` and `SKILL.md` files). This gives you a git history of how each agent evolved based on your feedback.

To disable automatic commits:

```json
{
  "versioning": {
    "autoCommitFeedback": false
  }
}
```

---

## Pre-edit backups

Before the evaluator modifies any files, a snapshot of each file is preserved in the run directory. If the evaluator makes an unwanted change, you can:

1. Check the `feedback-result.md` to see what was changed
2. Use `git diff` to see the exact edits
3. Revert with `git checkout -- .cronagents/agents/<file>` if changes were committed
4. Or restore from the pre-edit snapshot in the run's backup

---

## Feedback lifecycle

```
Run completes
  └─→ feedback.md created (stub with comments)
        └─→ User writes feedback
              └─→ Evaluate (manual or auto)
                    └─→ Evaluator reads feedback + output + agent definition
                          └─→ Edits agent files
                          └─→ Writes feedback-result.md
                          └─→ Sets feedbackProcessed: true in meta.json
                          └─→ Git commit (if autoCommitFeedback)
```

### Checking feedback status

Use the status command to see which agents have pending feedback:

```powershell
.\cronagents.ps1 status
```

The **Feedback** column shows:

| Status | Meaning |
|--------|---------|
| `📝 Pending` | Feedback written but not yet processed |
| `✅ Processed` | Feedback has been evaluated |
| `—` | No feedback written for the most recent run |

The interactive menu option **5) Submit feedback** also opens pending feedback files.

---

## Tips

- **Write feedback often.** Even brief notes like "too verbose" or "missed the config files" help the evaluator make useful edits.
- **Review the results.** Always check `feedback-result.md` to make sure the evaluator understood your intent.
- **Iterate.** If the first round of feedback didn't fully fix the issue, write more feedback on the next run. Agents improve incrementally.
- **Use auto-feedback for fast iteration.** Enable `autoFeedback`, run the agent, write feedback, wait ~60 seconds, then run again to see the improvement.
- **Retention protects feedback.** Run directories with unprocessed feedback are never deleted by retention cleanup, so you won't lose pending feedback.
