---
name: non-agent-branching
description: "Describe and apply the branch workflow for non-agent development in this repository"
---

# Non-Agent Branching

Use this skill when the work is about shared infrastructure development in this repository.

Examples:
- scheduler or CLI changes
- tests
- docs
- schemas
- templates
- shared skills under `scheduler/skills/`

## Read First

1. [guide/branching-and-sync.md](../../../guide/branching-and-sync.md)

## Core Rule

All shared development (scheduler, CLI, tests, docs, schemas, templates) belongs on `master` or on a short-lived feature branch created from `master`, then merged back to `master`.

Personal agent work happens in the **separate personal repo** (`~/.cronagents/`) — never in the infra repo. There are no personal branches in this repository.

## Workflow

### 1. Make changes on master or a feature branch

```powershell
git checkout master
git pull --ff-only origin master
# optional feature branch
git checkout -b feat/<short-topic>
```

### 2. Validate

```powershell
./tests/Invoke-Tests.ps1
```

Prefer the existing shared module and helpers instead of duplicating logic.

### 3. Merge to master

If you used a feature branch:

1. Commit there.
2. Merge or fast-forward it into `master`.
3. Push `master`.

The goal is that shared development ends up on `master`.

## Guardrails

- Do not commit generated runtime artifacts such as `.cronstate/`
- Do not put personal agent definitions in the infra repo — they belong in `~/.cronagents/`
- When in doubt, ask: "Is this shared infrastructure or personal agent work?"
