---
mode: agent
description: "Trigger feedback processing for recent CronAgents runs"
---

Find all recent agent run directories under `.cronstate/runs/` that have:
1. A non-empty `feedback.md` file (user has written feedback)
2. A `meta.json` with `feedbackProcessed: false`

For each such run, invoke the feedback evaluator to process the feedback and improve agent definitions.

Report which runs had feedback processed and what changes were made.
