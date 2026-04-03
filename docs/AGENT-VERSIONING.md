# Agent Versioning — Personal Repo Model for User Agent Customizations

**Status:** Day 0 requirement
**Scope:** How user-created agent/skill/instruction files are version-controlled, backed up, and evolved through feedback.

---

## Problem

The feedback evaluator edits agent, skill, and instruction files based on human feedback. Without version control on those files, there's no way to:

1. **Revert a bad edit** — the evaluator oversimplifies a prompt or removes a nuanced instruction
2. **Recover from poisoned feedback** — malicious or careless feedback causes the evaluator to corrupt an agent definition
3. **Trace drift** — many small edits accumulate until an agent behaves nothing like the original, with no history of how it got there

CronAgents is intended for sharing with coworkers and potentially open-sourcing. Personal agents must not land in the shared infra repo.

---

## Design: Separate Personal Repository

### The model

```
Infra repo (shared)                 ← Scheduler code, templates, schemas, docs
  └── master / feature branches

~/.cronagents/ (personal repo)      ← User's agents, registrations, runtime data
  ├── .github/agents/               ← Agent profiles (.agent.md)
  ├── .github/skills/               ← Agent skills (SKILL.md)
  ├── .cronagents/agents/           ← Agent registrations (.agent-registration.json)
  ├── .cronstate/                   ← Runtime data (gitignored)
  └── cronagents.json               ← Personal config overrides
```

- The **infra repo** contains all shared runtime code (`scheduler/`, `cronagents.ps1`, configs, templates, tests, docs) plus scaffold-internal agents (`scheduler/agents/`). No user-specific agent definitions.
- The **personal repo** (`~/.cronagents/`) is a standalone git repository containing the user's agent profiles, registrations, skills, and runtime state. It is completely independent of the infra repo.
- No branches, no sync, no merge conflicts between shared code and personal agents.

### What lives where

| Content | Location | Tracked? |
|---------|----------|----------|
| Scaffold runtime (`scheduler/`, `cronagents.ps1`, etc.) | Infra repo | Yes |
| Global config (`cronagents.json`) | Infra repo (base) + personal repo (overrides) | Yes |
| Scaffold agents (feedback-evaluator, run-summarizer) | Infra repo (`scheduler/agents/`) | Yes |
| Templates/examples | Infra repo (`templates/`) | Yes |
| Tests, docs, config schemas | Infra repo | Yes |
| User workload agents (`.github/agents/`, `.cronagents/agents/`) | Personal repo | Yes |
| User skills (`.github/skills/`) | Personal repo | Yes |
| Runtime data (`.cronstate/` — runs, state, logs) | Personal repo | Gitignored |

### Why a separate repo

- **Zero merge conflicts** — personal agents and shared infrastructure never touch the same git history
- **No branch management** — users don't need to understand branches, sync, or merge
- **Clean separation** — the infra repo stays generic and shareable; personal agents are private
- **Simple multi-machine** — copy or push the personal repo independently
- **Config layering** — team defaults from the infra repo, personal overrides in the personal repo

---

## Auto-Bootstrap

On first run (or `cronagents.ps1 install`), the installer initializes the personal repo:

```
cronagents.ps1 install
  → Does personal repo exist at configured path?
    → No:  Initialize-PersonalRepo (create dir, git init, scaffold structure)
    → Yes: Validate structure (Test-PersonalRepoValid)
  → Register Task Scheduler entry
  → Continue with normal startup
```

**Username resolution** (in priority order):
1. `personalRepo.userName` field in `cronagents.json` (explicit config)
2. `git config github.user`
3. `gh auth status` active account
4. `git config user.name` (slugified: lowercased, spaces → hyphens, non-alphanumeric stripped)
5. `$env:USERNAME` (fallback)

The bootstrap is **non-destructive**: it never deletes or overwrites existing files. If the personal repo already exists and is valid, it's left as-is.

---

## Feedback-Commit Hook

After the feedback evaluator edits files and writes `feedback-result.md`, the **scheduler** commits the changes in the personal repo with a structured message:

```powershell
git -C ~/.cronagents add .github/agents/ .cronagents/agents/ <any other edited paths>
git -C ~/.cronagents commit -m "feedback: <agent-name> — <one-line summary>"
```

The evaluator doesn't need git awareness. It edits files as it does today. The scheduler reads the changelog from `feedback-result.md` to determine which files changed and constructs the commit.

**Failure handling:**
- If `git add` or `git commit` fails, the scheduler logs the failure and surfaces it in the dashboard.
- The files are still edited on disk — only the commit failed. The user can manually commit.
- Pre-edit snapshots are written **before** the edit attempt, so they exist regardless of git state.

---

## Pre-Edit Snapshots

The feedback evaluator **always** creates pre-edit snapshots in the run directory:

```
~/.cronagents/.cronstate/runs/<timestamp>_<agent-id>_<nonce>/
├── backup/
│   ├── daily-review.agent.md    ← copy of file before evaluator edited it
│   └── review-skill/SKILL.md   ← copy of file before evaluator edited it
├── output.md
├── summary.md
├── meta.json
├── feedback.md
├── feedback-result.md
└── ...
```

**Why keep both snapshots and git history?**
- Snapshots serve immediate "undo this specific feedback edit" without knowing git
- Snapshots survive even if git operations fail
- Snapshots are paired with the feedback that caused the change
- Git history serves the long-term view: "what happened to this agent over months"
- Snapshots are subject to `retentionDays` cleanup; git history is permanent

---

## Configuration

Fields in `cronagents.json`:

```jsonc
{
  // Existing fields...

  "personalRepo": {
    "path": null,                      // Path to personal repo. null = ~/.cronagents/
    "userName": null,                  // Override for display/identification. null = auto-detect.
    "autoCommitFeedback": true,        // Commit after feedback evaluator edits. Default true.
    "defaultWorkingDirectory": null    // Default CWD for agent runs. null = personal repo root.
  }
}
```

All fields are optional with sensible defaults. A user who never touches this section gets a personal repo at `~/.cronagents/`, auto-detected username, auto-committed feedback edits, and agents running from the personal repo root with `--allow-all` plus unattended tool approval via `--allow-all-tools`.

---

## Scheduler Execution

The scheduler runs Copilot CLI with CWD set to the personal repo by default:

- Agent profiles are discovered from `~/.cronagents/.github/agents/`
- Registrations are read from `~/.cronagents/.cronagents/agents/`
- `--allow-all` is passed by default for directory scope (CWD = personal repo)
- `--allow-all-tools` is passed for unattended runs
- Per-agent `workingDirectory` config can restrict to specific project directories

---

## Testing

See [TESTING.md](TESTING.md) — `AgentVersioning.Tests.ps1`, `BackupRestore.Tests.ps1`.

---

## Migration

Users on the old branch model (`personal-agents/<username>`) can migrate with:

```powershell
.\cronagents.ps1 migrate
```

This copies agent profiles and registrations from the infra repo's `.github/agents/` and `.cronagents/agents/` into the personal repo.













