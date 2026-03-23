# UX Requirements — CronAgents Interactive Dashboard

Future-phase requirements for an interactive UI layer on top of the CronAgents scheduler. Not part of the initial implementation — the Phase 1 management surface is the `cronagents.ps1` CLI wrapper plus the read-only `dashboard.md`.

---

## Goals

- Provide a browser-accessible management surface for users who prefer clicking over typing
- Expose the same actions as `cronagents.ps1` in a visual interface
- Zero build step, zero npm, zero binary check-in — interpreted languages only
- Runs alongside the scheduler process, not as a separate service

---

## Approach: PowerShell micro HTTP server

The scheduler already runs as a persistent polling process (`Start-CronAgents.ps1`). Adding a `System.Net.HttpListener` on `localhost:9077` is straightforward — `HttpListener` ships with .NET, which PowerShell already requires.

- **Server**: ~50 lines of PowerShell added to `Start-CronAgents.ps1` (or a separate `Start-DashboardServer.ps1` module)
- **Frontend**: single `dashboard.html` with vanilla JS/CSS, served by the listener. Polls a JSON API endpoint for live state.
- **Total additional code**: ~50 lines PowerShell + ~300 lines HTML/JS/CSS
- **No dependencies beyond PowerShell/.NET**

---

## Management actions to expose

| Action | HTTP endpoint | Maps to |
|--------|--------------|---------|
| View agent status / next runs | `GET /api/status` | `cronagents.ps1 status` |
| List agents with schedules | `GET /api/agents` | `cronagents.ps1 list` |
| Trigger one-off run | `POST /api/run/:agent` | `cronagents.ps1 run <agent>` |
| Pause an agent | `POST /api/pause/:agent` | `cronagents.ps1 pause <agent>` |
| Resume an agent | `POST /api/resume/:agent` | `cronagents.ps1 resume <agent>` |
| View run history | `GET /api/runs[?agent=X]` | reading `.cronstate/runs/` |
| View run detail | `GET /api/runs/:id` | reading specific run directory |
| Submit feedback | `POST /api/feedback/:runId` | writing to `feedback.md` in run directory |
| Trigger feedback evaluator | `POST /api/evaluate` | `cronagents.ps1 evaluate` |
| View pending feedback count | `GET /api/feedback/pending` | scanning `meta.json` files |

---

## UI layout (rough)

```
┌──────────────────────────────────────────────────────┐
│  CronAgents Dashboard                     [Settings] │
├──────────────────────────────────────────────────────┤
│                                                      │
│  Agents                                              │
│  ┌────────────┬──────────┬──────────┬───────┬──────┐ │
│  │ Agent      │ Schedule │ Last Run │ Status│ Ctrl │ │
│  ├────────────┼──────────┼──────────┼───────┼──────┤ │
│  │ daily-rev  │ daily 9a │ 2h ago   │ ✓     │ ⏸ ▶  │ │
│  │ deps-check │ weekly   │ 3d ago   │ ✓     │ ⏸ ▶  │ │
│  └────────────┴──────────┴──────────┴───────┴──────┘ │
│                                                      │
│  Recent Runs                         [Run Now ▼]     │
│  ┌────────────┬──────────┬──────────┬───────────────┐│
│  │ Agent      │ Time     │ Status   │ Feedback      ││
│  ├────────────┼──────────┼──────────┼───────────────┤│
│  │ daily-rev  │ 09:00    │ done     │ [Write] [View]││
│  │ daily-rev  │ y'day    │ done     │ ✓ processed   ││
│  └────────────┴──────────┴──────────┴───────────────┘│
│                                                      │
│  Feedback                                            │
│  ┌──────────────────────────────────────────────────┐│
│  │ [textarea for inline feedback on selected run]   ││
│  │                                                  ││
│  │                                   [Submit]       ││
│  └──────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────┘
```

---

## Design constraints

- **No build tooling**: single HTML file, no bundler, no transpiler. Vanilla JS with modern browser APIs (`fetch`, `async/await`, template literals).
- **No frameworks**: CSS Grid/Flexbox for layout. No React, Vue, etc.
- **Progressive enhancement**: falls back gracefully if the server isn't running — the markdown dashboard still works independently.
- **Security**: listener binds to `localhost` only. No auth required for local-only use. If network exposure is ever needed, that's a separate design discussion.
- **Auto-refresh**: poll `/api/status` every 5-10 seconds. No WebSockets needed for the polling model.

---

## Alternatives considered

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Static HTML** (generated per run) | Zero runtime, simple | No live updates, no interactivity | Could be a stepping stone |
| **PowerShell HttpListener** | Zero deps, natural fit | Slightly more code | **Recommended** |
| **Python Textual TUI** | Beautiful terminal UI | Adds Python dependency | Only if Python already required |
| **VS Code Webview Extension** | Deep IDE integration | Requires TypeScript build + packaging | Future phase at best |

---

## When to implement

After the CLI wrapper (`cronagents.ps1`) has been used enough to validate the command set. The HTTP API should exactly mirror the CLI commands — design the CLI first, then wrap it in HTTP, not the other way around.
