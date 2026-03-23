---
name: feedback-evaluator
description: "Evaluation procedures for processing human feedback on agent runs"
---

# Feedback Evaluator Skill

## Purpose

This skill provides the feedback evaluator agent with procedures and reference material for processing human feedback and making appropriate edits to agent definitions.

## Evaluation Procedures

### 1. Read and Understand Feedback

- Read `feedback.md` from the run directory
- Read `output.md` and `meta.json` to understand what the agent did
- Identify the specific improvements the human is requesting

### 2. Assess Scope

Determine which files need changes:
- **Agent definition** (`.agent.md`) — system prompt, tool scoping, model selection
- **Skill files** (`SKILL.md`) — domain knowledge, procedures, reference material
- **Instruction files** — workspace or global instructions

### 3. Make Targeted Edits

- Change only what the feedback specifically asks for
- Preserve existing structure, frontmatter format, and conventions
- Keep changes minimal — don't rewrite entire files
- If the feedback is about output quality, adjust the system prompt
- If the feedback is about tool usage, adjust the `tools` frontmatter or deny rules
- If the feedback is about domain knowledge, update the relevant `SKILL.md`

### 4. Document Changes

Write `feedback-result.md` in the run directory with:
- List of files changed with before/after descriptions
- Rationale for each change
- One-line summary suitable for a git commit message

### 5. Boundaries

**Can edit:** `.agent.md` files, `SKILL.md` files, instruction files, memory files
**Cannot edit:** Scheduler scripts, config schemas, `feedback-evaluator.agent.md` itself, `cronagents.ps1`
**Cannot delete:** Any files

## Common Feedback Patterns

| Feedback | Typical Edit |
|----------|-------------|
| "Too verbose" | Tighten system prompt, add conciseness instruction |
| "Missing context" | Add relevant search patterns or file references to prompt |
| "Wrong tools" | Adjust `tools` frontmatter in `.agent.md` |
| "Too aggressive edits" | Add caution instructions, reduce edit scope |
| "Not finding the right files" | Add search patterns or explicit paths to skill |
| "Unclear or contradictory" | Note in feedback-result.md, make no edits |
