# Security practices relevant to `docs/FUTURE.md` item 8 (`Security Review Agent`)

## Executive Summary

`docs/FUTURE.md` item 8 is asking for a **CronAgents-native control plane guardrail**, not a generic “security scan.” It specifically proposes an internal agent that reviews **recent diffs to agent definitions, skills, config, feedback, and outputs** before those changes are allowed to influence the next scheduled run.[^1] That is a strong idea because CronAgents already has unusually rich security inputs: versioned agent repos, feedback-result changelogs, pre-edit backups, run transcripts, and a scheduler that can pause agents and surface status centrally.[^2][^3][^4]

After reviewing OpenClaw, NanoClaw, Claude Cowork security writeups, and broader agent-security guidance, the clearest pattern is this: the most effective controls are **layered**. OpenClaw emphasizes ingress restrictions, security auditing, and deployment hardening inside a “personal assistant” trust model rather than hostile multi-tenancy.[^5][^6] NanoClaw goes further on **OS/container isolation, mount allowlists, session isolation, IPC authorization, and secret injection outside the model context**.[^7][^8][^9][^10] Claude Cowork coverage focuses less on strong local containment and more on **enterprise governance gaps**: prompt injection, browser/file/system reach, scheduled unattended actions, plugin/MCP expansion, and incomplete audit coverage, which in turn drives demand for external gateways, SIEM telemetry, and stricter approval postures.[^11][^12]

For CronAgents, the highest-value controls are **not** “build a whole NanoClaw.” The most relevant investments are: **diff-aware policy checks, capability drift detection, approval gates for high-risk changes, stronger provenance for skills/tools, taint-aware review of feedback and run outputs, exfiltration heuristics, and quarantine/rollback flows**.[^1][^2][^3][^13][^14] In other words: treat item 8 as a **security policy engine over scheduled agent evolution**.

My main recommendation is to implement item 8 as a **two-stage guardrail**:

1. a **deterministic policy layer** that hashes, diffs, classifies, and blocks known-dangerous changes; and
2. an **LLM reviewer layer** that reasons over the structured evidence package and produces severity-ranked findings.

That split matches the broader landscape: put crisp, machine-checkable rules in front; use the model for judgment and synthesis; and require human approval when the blast radius is high.[^15][^16][^17]

---

## What item 8 is actually asking for

The future item is narrowly scoped: a “scaffold-internal agent” should review **recent diffs** to agent definitions, skills, config, and feedback; run **after the feedback-commit hook but before the next scheduled agents execute**; watch for prompt injection, unexpected tool additions or `--deny-tool` removals, manipulative feedback, and anomalous output suggesting exfiltration; then **auto-pause the affected agent** and notify via dashboard/TUI.[^1]

That matters because CronAgents already stores exactly the evidence such a reviewer needs. Each run creates `output.md`, `summary.md`, `meta.json`, `session.md`, `feedback.md`, `feedback-result.md`, and `scheduler.log`, and the evaluator’s changes can be auto-committed to git with a clean history of agent evolution.[^2][^3] The branching model also cleanly separates shared infra from each user’s personal repo, which reduces blast radius and gives the security reviewer a clear scope: it mostly needs to police the **personal repo mutation path** and its interaction with shared scheduler policy.[^4]

So the underlying question is not “what security features exist in agent frameworks?” It is:

> **What guardrails can a scheduled-agent infrastructure add around agent definition changes, tool surface changes, and scheduled execution, using the artifacts it already has?**

That distinction is important. Much of the landscape is about runtime containment, browser isolation, and user-access governance. Some of that is relevant, but the closest analogue for CronAgents item 8 is **change control + drift detection + approval workflow for autonomous agents that modify themselves over time**.[^1][^14][^17]

---

## Threat model for CronAgents item 8

### Primary threats

1. **Prompt or instruction poisoning in agent definitions / skills**
   A malicious or careless edit changes an agent’s system prompt, tool guidance, or skill file so it begins performing broader, riskier, or data-leaking work than intended.[^1][^15]

2. **Capability drift**
   A feedback loop or manual edit expands the tool surface: e.g. adds filesystem/network/browser/MCP reach, removes deny rules, changes profiles, or broadens path access.[^1][^5][^13][^16]

3. **Feedback poisoning**
   `feedback.md`, `output.md`, or `session.md` smuggle instructions that manipulate the evaluator rather than merely describing desired behavior changes.[^1][^2][^15][^17]

4. **Data exfiltration via legitimate channels**
   The model uses allowed tools or outputs to leak secrets or sensitive state in a way that looks like normal work product.[^15][^16][^18]

5. **Supply-chain / skill integrity problems**
   A skill or helper prompt changes unexpectedly, is replaced, or is imported from an untrusted source without provenance or review.[^17][^19]

6. **Silent persistence**
   Dangerous edits survive because they were committed automatically and nobody reviews the delta before the next scheduled run.[^1][^3]

### Secondary threats

1. **Cross-agent contamination**
   A shared skill or config change affects multiple scheduled agents at once.[^1][^4]

2. **Operator fatigue**
   Too many warnings create the same “approve everything” failure mode seen in developer-agent and cowork tooling.[^16][^20]

3. **Insufficient auditability**
   Findings are ephemeral or unstructured, making later review, triage, and incident response hard.[^11][^18]

---

## The landscape: what OpenClaw, NanoClaw, and Claude Cowork teach

## Comparison at a glance

| System | Core security idea | What it is best at | Main limitation for CronAgents relevance |
|---|---|---|---|
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | Hardening within a trusted-operator “personal assistant” model: pairing, allowlists, audit CLI, deployment guidance, sandbox recommendations | Ingress control, security audits, policy footgun detection, explicit trust-model documentation | Less focused on self-modifying scheduled definitions; assumes one trust boundary, not evaluator-driven repo evolution[^5][^6][^13] |
| [qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw) | True isolation: per-agent containers, external mount allowlists, session isolation, IPC auth, secret injection via Agent Vault | Strong runtime containment and secret hygiene; sharply reduced blast radius | More runtime-heavy than CronAgents’ current architecture; some controls would be expensive to port directly[^7][^8][^9][^10] |
| [ComposioHQ/open-claude-cowork](https://github.com/ComposioHQ/open-claude-cowork) plus Cowork security commentary | Desktop agent with Electron + backend + MCP/Composio integration; security discussion centers on enterprise governance | Highlights plugin/MCP risk, unattended scheduled task risk, and audit/monitoring needs | Open-source implementation is relatively thin on hardening beyond Electron basics; strongest lessons come from external governance analysis[^11][^12][^21] |

### 1. OpenClaw: explicit trust model + audit-first hardening

OpenClaw’s official security guidance is unusually explicit that it is designed around a **personal-assistant trust model**, not hostile multi-tenancy: one trusted operator boundary per gateway, and separate gateways/OS users/hosts when adversarial-user isolation is needed.[^5] That is useful for CronAgents because it shows the value of **documenting the exact security model** rather than implying more isolation than the product really provides.[^5]

OpenClaw’s other strong pattern is the `openclaw security audit` workflow. The CLI docs show an audit that checks DM sharing, ingress exposure, sandbox drift, dangerous command allowlists, plugin/tool reachability, network exposure, browser-control exposure, permission hygiene, and risky auth settings, with optional safe fixes and JSON output for CI/policy enforcement.[^13] This is exactly the sort of **deterministic preflight layer** that item 8 should inherit.

The official gateway security page also emphasizes minimizing who can talk to the bot, where it can act, and what it can touch, while recommending pairing/allowlists, loopback binding, token auth, per-peer DM scoping, workspace-only FS access, and “deny” exec posture as a hardened baseline.[^6] It further warns that if several people can message one tool-enabled agent, each can steer that same permission set, which is a clean articulation of **delegated authority risk**.[^6]

### What matters for CronAgents from OpenClaw

- **Trust-model explicitness**: CronAgents should define what is and is not protected. Example: “item 8 protects against drift and poisoned edits inside a personal repo; it does not turn one shared agent into hostile multi-user isolation.”[^5][^13]
- **Security audit as product surface**: OpenClaw treats security checks as a first-class CLI command, not a side note.[^13]
- **Footgun detection**: many useful findings are not “attacks” but dangerous combinations of settings.[^13]
- **Machine-readable output**: JSON audit output is a major enabler for automation and gating.[^13]

### 2. NanoClaw: hard runtime boundaries and secret non-exposure

NanoClaw’s security model is the cleanest runtime design in this landscape. Official docs describe **container isolation as the primary boundary**, with only explicitly mounted directories visible, non-root execution, and fresh ephemeral containers per invocation.[^7][^8] Its `mount-security.ts` implementation stores mount policy outside the project root, blocks sensitive path patterns by default, resolves symlinks before validation, rejects dangerous container paths, and can force read-only mounts for non-main groups.[^8] The container runner reinforces that by mounting the project root read-only for the main group, shadowing `.env`, isolating per-group `.claude` session state, and validating additional mounts against the external allowlist before they are passed into the container.[^9]

NanoClaw also implements **authorization on internal control channels**. Its IPC watcher treats the IPC directory as identity, verifies that non-main groups can only message or schedule for themselves, and blocks unauthorized attempts with logging.[^10] That is a strong example of a non-LLM, policy-first control on internal automation flows.

Its documentation adds another crucial pattern: **real credentials never enter containers**. Instead, OneCLI Agent Vault proxies outbound requests and injects credentials at request time; containers only get placeholders and proxy routes, not the real secrets.[^7] That design is aligned with current broader guidance from NVIDIA and OWASP, both of which recommend secret injection / externalized secret handling so the model never receives long-lived credentials in context or environment.[^16][^17]

The Docker Sandbox guide extends this further by layering **micro-VM isolation outside the per-agent containers**, effectively giving NanoClaw two isolation layers: VM + container.[^22]

### What matters for CronAgents from NanoClaw

- **Guardrails should protect the guardrail config itself**. NanoClaw stores mount allowlists outside the mounted project and never exposes them to the container.[^7][^8] CronAgents should similarly keep security policy outside editable agent scopes.
- **Secrets should not transit the model**. If CronAgents agents ever gain broader network or credentialed tooling, secret injection/proxying is more important than prompt instructions saying “don’t reveal secrets.”[^7][^16]
- **Structured internal authorization is cheap and powerful**. NanoClaw’s IPC checks show that internal automation boundaries should be validated by code, not by prompt text.[^10]
- **Containment beats intent** for high-risk runtime actions. This is the strongest lesson, even if CronAgents does not immediately adopt containerization.[^7][^9][^16]

### 3. Claude Cowork: governance and observability matter more than prompts

The open-source `open-claude-cowork` codebase itself shows some basic Electron hygiene: `nodeIntegration: false`, `contextIsolation: true`, a preload bridge instead of raw renderer access, and external-link handling that prevents arbitrary in-app navigation.[^21] That is good baseline desktop hygiene, but the more important Cowork lessons come from broader security analysis, not from the demo codebase.

Harmonic’s guide frames Cowork as a qualitatively different threat surface because it can read/write local files, browse with session cookies, and run scheduled tasks, while warning that OpenTelemetry is useful but imperfect and that Cowork activity is excluded from Anthropic audit logs / compliance exports during the research-preview period.[^11] Mint’s guide makes similar points: Cowork is an agentic local runtime with filesystem, command execution, browser automation, scheduled tasks, and MCP connections, and it argues that deployments need centralized monitoring, organization-level posture choices, deny rules for risky file/command access, and explicit restrictions for regulated workloads.[^12]

Both guides repeatedly return to three ideas:

1. **Prompt injection remains the top risk**.[^11][^12]
2. **Scheduled unattended work is especially risky** because the user may not be watching.[^11][^12]
3. **Enterprise safety depends on governance and telemetry**, not only model/provider safeguards.[^11][^12][^18]

### What matters for CronAgents from Cowork

- **Scheduled unattended actions deserve a higher bar** than interactive ones.[^11][^12]
- **Admin posture should be explicit**: lockdown / controlled / open is a better framing than a vague “secure/insecure” split.[^11]
- **Telemetry gaps become governance gaps**. If operators cannot reconstruct what changed, what tools were available, and what data moved, they cannot review incidents effectively.[^11][^12]

---

## Cross-cutting themes from broader agent-security guidance

The broader guidance from OWASP, NVIDIA, Microsoft, and the MCP cheat sheets converges on a few recurring controls.

### 1. Treat external content and tool outputs as untrusted

OWASP’s AI Agent and MCP cheat sheets both treat prompt injection, tool poisoning, memory poisoning, goal hijacking, and exfiltration as first-order risks, and they explicitly recommend separating instructions from data, validating/sanitizing both tool inputs and outputs, and treating tool responses as untrusted input before they are put back into model context.[^15][^17]

Microsoft’s enterprise playbook is especially strong on **indirect prompt injection**: poisoned documents, emails, tickets, and pages can look like business content to humans but act like instructions to the model, so “do not trust tool outputs; verify intent before execution” becomes an architectural rule, not a UX suggestion.[^18]

For item 8, that means `feedback.md`, `output.md`, and `session.md` should be treated as **tainted evidence**, not authoritative instructions.

### 2. Prefer OS/policy enforcement over application-only prompts

NVIDIA’s red-team guidance is blunt: application-level controls are insufficient once a subprocess runs; mandatory controls include blocking network egress to arbitrary sites, blocking writes outside the workspace, and blocking writes to agent configuration files regardless of location, all preferably at the OS/sandbox level.[^16] The MCP cheat sheet makes the same case for sandboxing local servers, constraining filesystem access, and pinning tool definitions.[^17]

CronAgents is not there yet, but the conceptual lesson is still relevant: **do not rely on evaluator prompt text to protect scheduler files or policy files.** Enforce that with path-level checks and post-edit validation.

### 3. Human approval should be risk-based, not constant

OWASP recommends explicit approval for high-impact or irreversible actions with previews and risk classification.[^15] NVIDIA warns that broad manual-approval schemes create habituation and that “allow once / run many” is not adequate for certain sensitive actions.[^16] That is relevant because item 8 could easily become noisy if it flags every benign prompt tweak.

So CronAgents should gate **specific classes of drift**, not every edit.

### 4. Auditability and replayable evidence matter

OWASP MCP guidance recommends logging tool invocations with full parameters, user context, timestamps, and anomaly detection, while Microsoft stresses ASR-style measurement and continuous red teaming rather than one-time checks.[^17][^18] CronAgents already stores much of the evidence required to do this cheaply: session transcripts, outputs, feedback, change logs, git history, and run metadata.[^2][^3]

### 5. Tool / skill integrity should be pinned and monitored

The MCP cheat sheet highlights rug pulls, tool-schema poisoning, and supply-chain attacks, recommending cryptographic pinning or at least change alerts for tool definitions and server packages.[^17] This maps directly to CronAgents skills and agent definition files.

---

## Which practices are most relevant for CronAgents specifically

## High relevance: CronAgents can help directly

### A. Capability drift detection

CronAgents can inspect agent diffs and detect:

- tool additions;
- denylist removals;
- broader filesystem patterns;
- new MCP/browser/network/runtime reach;
- agent/profile changes that move from “read/report” to “act/modify/send.”[^1][^13]

This is the single most relevant lesson from OpenClaw and OWASP MCP: **watch the capability surface, not only the text surface**.[^13][^17]

### B. Taint-aware review of feedback and outputs

The reviewer should explicitly treat `feedback.md`, `output.md`, `summary.md`, and `session.md` as potential injection sources. These should be summarized into a structured evidence object, with instruction-like text separated from desired edits, before the LLM reviewer sees them.[^2][^15][^18]

### C. Post-edit path and scope validation

The evaluator is already documented as being unable to edit scheduler scripts and schemas by policy, but item 4 in `FUTURE.md` notes that today this is largely enforced by prompt instructions and suggests a config-level `editScope` allowlist with after-the-fact validation.[^23] Item 8 should incorporate that idea immediately: validate actual changed paths against agent-specific edit scopes before accepting changes.[^1][^23]

### D. Quarantine / auto-pause / rollback

Item 8 already proposes auto-pausing affected agents.[^1] CronAgents is well-positioned to add:

- `status = quarantined`;
- a dashboard/TUI finding summary;
- a pointer to the offending diff;
- a “restore from pre-edit snapshot” or “revert commit” action using the existing backups/history.[^2][^3]

### E. Structured security findings as artifacts

OpenClaw’s JSON audit pattern is worth copying.[^13] CronAgents should emit a machine-readable `security-review-result.json` plus a human-readable markdown summary. This makes it easy to fail closed in scheduler flow and easy to review later.

### F. Risk scoring and approval gates

Not every warning should block. Use severity tiers:

- **Info**: suspicious wording, but no capability drift.
- **Warn**: new risky instructions, but same tool surface.
- **High**: denylist removed, tool added, scope widened, or exfil heuristics triggered.
- **Critical**: protected path changed, scheduler policy changed, or multiple suspicious dimensions at once.

Only High/Critical should auto-pause by default.

## Medium relevance: useful if CronAgents grows

### A. Secret isolation / proxy injection

If CronAgents agents begin using authenticated APIs or richer MCP tooling, NanoClaw’s “real secrets never enter the container” pattern becomes highly relevant.[^7] Right now, for many CronAgents workflows, secret exposure may be narrower, but this should be on the roadmap.

### B. Stronger runtime isolation per run

If CronAgents grows toward browser automation, local shells, or multi-user/shared deployment, per-run container or separate-OS-user isolation becomes more valuable.[^7][^16][^22] Today, that is probably a later-phase investment.

### C. Enterprise observability / SIEM hooks

If this project expands to team use, the Cowork lesson is that lack of central telemetry becomes the governance bottleneck fast.[^11][^12]

## Low relevance right now

- Browser-category blocklists
- Remote device pairing
- Chrome tab automation restrictions
- Full tenant-restriction / IdP posture controls

Those are real controls, but they are not the main unlock for item 8.

---

## Recommended design for CronAgents item 8

## Architecture

```text
Git diff / snapshots / feedback artifacts / session transcript / config manifest
                  │
                  ▼
     Deterministic collector + classifier
     - changed paths
     - tool/profile delta
     - denylist delta
     - scope delta
     - suspicious strings / exfil markers
     - protected-file violations
                  │
                  ├── if critical deterministic violation → block immediately
                  │
                  ▼
          LLM security reviewer
          - review structured evidence
          - classify severity
          - explain why
          - recommend allow / pause / require approval
                  │
                  ▼
        Enforcement + artifacts
        - pause/quarantine agent
        - write markdown + JSON report
        - surface in dashboard/TUI
        - optionally request human approval
```

### Why this split is important

The deterministic layer should catch the things that are easy and dangerous:

- changed file path outside scope;
- tool added;
- deny rule removed;
- workspace/path glob widened;
- scheduler/config/schema touched;
- new outbound URL or MCP host introduced;
- suspicious “send to”, “exfiltrate”, “ignore previous”, “disable safeguard”, or encoded instruction patterns.[^1][^15][^17]

The LLM layer should do the nuanced parts:

- “does this feedback look like a legitimate request or like a manipulative instruction chain?”
- “is this tool change actually harmless in context or obviously privilege-expanding?”
- “does the output pattern look like exfiltration or a normal report?”

This avoids a common failure mode where the model is asked to be both parser and judge. The literature and product patterns point toward **deterministic gates first, model reasoning second**.[^13][^16][^17]

## Input bundle

CronAgents should build a normalized evidence bundle with:

- `agentId`
- changed files list
- before/after hashes
- unified diffs
- changed tool/capability manifest
- changed path/edit-scope manifest
- recent `feedback.md`
- `feedback-result.md`
- selected `session.md` / `output.md` excerpts
- last good baseline revision
- model/tool metadata from the affected agent registration
- prior findings / prior approvals for the same agent

This should be stored as JSON so the security reviewer is reviewing **structured facts**, not scraping raw files ad hoc.

## Recommended rule families

### 1. Protected paths

Always block changes to:

- `scheduler\**`
- `cronagents.ps1`
- schema files
- the security-reviewer’s own policy bundle
- any path outside the agent’s `editScope`.[^23]

### 2. Capability manifest drift

Generate a manifest per revision:

- tools/profile
- allowed/denied tools
- referenced skills
- referenced MCP servers/endpoints
- referenced paths/globs
- any execution/network/browser toggles

Then diff manifests, not just text. This is the clearest way to detect “same prompt, bigger blast radius.”

### 3. Feedback taint rules

Before sending artifacts to the evaluator or security reviewer:

- strip or mark code fences and quoted logs;
- label source fields (`feedback`, `session`, `output`, `summary`);
- detect imperative/instruction-like sequences;
- flag encoded/high-entropy blobs;
- never let raw tool outputs be treated as system instructions.[^15][^17][^18]

### 4. Exfiltration heuristics

Flag:

- sudden addition of email/webhook/upload/browser/post/send tools;
- instructions to summarize secrets or credentials;
- new references to `.env`, SSH keys, token files, auth exports;
- large outbound-looking payloads or base64-ish blobs in outputs;
- “report externally,” “send to,” “upload archive,” or “mirror session” patterns.[^15][^16][^18]

### 5. Supply-chain / provenance rules

Require explicit provenance or approval when:

- a new skill is imported/copied from outside a trusted directory;
- an existing skill hash changes without a corresponding reviewed change note;
- a new external tool/integration endpoint appears.[^17][^19]

### 6. Unattended execution rules

Raise severity if the affected agent:

- runs frequently;
- runs without user interaction;
- has write/send capabilities;
- touches sensitive repos or directories.

This is the Cowork lesson: scheduled unattended work has different risk than interactive work.[^11][^12]

---

## Concrete backlog for CronAgents

## Phase 1: highest-value, lowest-regret

1. **Security manifest generation**
   Produce a normalized manifest for every agent revision and every evaluator-produced diff.

2. **Deterministic diff policy engine**
   Implement blocks/warnings for:
   - out-of-scope file changes,
   - tool additions,
   - denylist removals,
   - path widening,
   - protected-file edits,
   - risky string patterns.

3. **Security review artifacts**
   Write `security-review.md` and `security-review.json` into the run directory, and surface them in dashboard/TUI.

4. **Quarantine / pause**
   Add a first-class paused/quarantined status and skip execution until cleared.

5. **Human approval for high-risk findings**
   Don’t auto-resume from a critical finding.

## Phase 2: stronger trust on content and provenance

1. **Feedback taint pipeline**
   Normalize and annotate evidence before the evaluator and reviewer see it.

2. **Skill integrity**
   Hash skill files and alert on unexpected changes; optionally maintain a small allowlisted skill registry.

3. **Signed or pinned policy bundle**
   Protect the reviewer’s own detection rules from silent tampering.

4. **Cross-run anomaly baselines**
   “This agent has never requested browser/network before” is stronger than a raw keyword hit.

## Phase 3: if the project gets more powerful / shared

1. **Per-run OS-user / container isolation**
2. **Secret proxy / external credential injection**
3. **SIEM/webhook export of findings**
4. **Central team policy packs**

---

## What I would borrow directly from each ecosystem

### Borrow from OpenClaw

- A first-class `security audit` command with JSON output.[^13]
- Very explicit trust-model documentation so users know what is and isn’t being secured.[^5][^6]
- “Hardened baseline” examples for minimal-safe defaults.[^6]

### Borrow from NanoClaw

- Keep security policy outside the agent-editable area.[^8]
- Separate evidence/control channels by identity and authorize them in code.[^10]
- Treat secret non-exposure as stronger than “the prompt says not to use secrets.”[^7][^9]

### Borrow from Cowork security practice

- Different deployment postures (lockdown / controlled / open) for scheduled agents with different blast radii.[^11]
- Stronger controls for unattended/scheduled actions than for interactive runs.[^11][^12]
- Better monitoring and operator visibility as a first-class requirement, not an afterthought.[^11][^12]

### Borrow from OWASP / NVIDIA / Microsoft / MCP guidance

- Treat tool outputs and retrieved content as untrusted.[^15][^17][^18]
- Pin definitions / detect rug pulls / watch supply chain.[^17]
- Use deterministic policy for protected paths and dangerous actions.[^15][^16]
- Keep approval workflows narrow and risk-based to avoid fatigue.[^15][^16]

---

## Specific recommendation: how to build item 8 in a way that fits CronAgents

If I were translating this research into implementation guidance for the separate build agent, I would recommend the following shape:

### 1. Do **not** make the security-reviewer a pure prompt-only agent

Make it a **scheduler-integrated subsystem** with:

- a deterministic preprocessor,
- a policy file / manifest generator,
- a reviewer agent,
- and an enforcement stage.

If the policy system is only “ask a model whether this diff feels bad,” it will be too fuzzy and too easy to bypass.

### 2. Make policy decisions over **structured manifests**

Examples:

- `toolsAdded: ["web_fetch"]`
- `denyToolsRemoved: ["powershell"]`
- `editScopeExpanded: [".github/skills/**"]`
- `protectedPathChanged: ["cronagents.schema.json"]`
- `evidenceSources: ["feedback.md", "session.md"]`
- `imperativePhrasesDetected: [...]`

This makes the reviewer more reliable and makes the results explainable.

### 3. Fail closed on a short list of deterministic violations

Immediate block + quarantine for:

- protected path edits,
- out-of-scope edits,
- denylist removals for high-risk tools,
- newly introduced network/send/upload abilities on unattended agents,
- suspicious changes to security policy or reviewer assets.

### 4. Require approval only for high-blast-radius drift

Approval candidates:

- adding execution/network/browser/MCP tools,
- widening filesystem scope,
- changing evaluator edit scope,
- moving from analysis-only to side-effectful behavior,
- repeated suspicious findings on the same agent.

### 5. Preserve the evidence trail

For every finding, persist:

- revision before/after,
- changed files,
- manifest diff,
- reason,
- reviewer explanation,
- disposition (`allow`, `warn`, `pause`, `require-approval`),
- who cleared it.

This is the minimum needed for later debugging or incident review.

---

## What seems less worth copying

Not everything in the landscape should be ported.

- CronAgents probably does **not** need a full desktop/Electron governance model today.
- It probably does **not** need immediate browser-category filtering.
- It probably does **not** need full VM/container orchestration before it has first-party evidence that runtime blast radius is the bottleneck.

The best immediate leverage is around **reviewing mutations and scheduled execution**, because that is exactly where CronAgents is novel and where item 8 already points.[^1]

---

## Bottom line

The security landscape says item 8 is directionally correct, but it should be sharpened:

- **OpenClaw** says: define your trust model and audit for dangerous config combinations.[^5][^13]
- **NanoClaw** says: protect policy outside the agent’s reach, isolate aggressively, and never hand the model real secrets if you can avoid it.[^7][^8][^9]
- **Claude Cowork** says: unattended agent actions, plugin/MCP expansion, and weak observability are where operator risk shows up fastest.[^11][^12]
- **OWASP/NVIDIA/Microsoft** say: external content is untrusted, prompt injection is architectural, policy must sit below the model when possible, and approval should be risk-based.[^15][^16][^17][^18]

So the most relevant build target for CronAgents is:

> **A deterministic-plus-LLM security review pipeline that watches agent-definition drift, capability drift, feedback poisoning, and exfiltration signals, then blocks or quarantines high-risk changes before the next scheduled run.**

That is exactly the slice of the problem where CronAgents has strong native leverage, because it already has the diffs, artifacts, scheduler control point, and dashboard surface needed to make the control effective.[^1][^2][^3]

---

## Confidence Assessment

### High confidence

- The interpretation of `docs/FUTURE.md` item 8 as a **change-governance / security-review control** is directly supported by the text of the item itself.[^1]
- CronAgents already has the artifact pipeline needed to feed such a control: run directories, feedback files, changelogs, git commits, and pre-edit backups.[^2][^3]
- OpenClaw officially emphasizes explicit trust boundaries and a security audit surface; NanoClaw officially emphasizes containment, mount policy, session isolation, IPC authorization, and secret non-exposure; broader guidance strongly supports layered deterministic policy plus model review.[^5][^7][^13][^15][^16][^17]

### Medium confidence

- The open-source `open-claude-cowork` repo is a useful implementation reference for baseline Electron and MCP integration, but the strongest Cowork security lessons come from external governance analysis rather than the repo’s own hardening story.[^11][^12][^21]
- The exact product specifics of Anthropic’s Cowork admin/audit posture may evolve quickly, so those external writeups are better treated as “current landscape snapshot” than timeless architecture truth.[^11][^12]

### Lower confidence / caveats

- Some outside ecosystem commentary on OpenClaw/NanoClaw is clearly more interpretive than primary. I weighted official docs, source code, OWASP, NVIDIA, Microsoft, The Register, Harmonic, and Mint more heavily than lower-signal comparison blogs.
- I did **not** find evidence that CronAgents presently has built-in runtime isolation comparable to NanoClaw’s containers, so recommendations in that area are roadmap-level, not “should be easy to add.”

---

## Footnotes

[^1]: `C:\src\DevCronAgents\docs\FUTURE.md:39-43`
[^2]: `C:\src\DevCronAgents\guide\feedback-system.md:11-16`
[^3]: `C:\src\DevCronAgents\guide\feedback-system.md:20-32`; `C:\src\DevCronAgents\guide\feedback-system.md:154-205`
[^4]: `C:\src\DevCronAgents\guide\branching-and-sync.md:15-25`; `C:\src\DevCronAgents\guide\branching-and-sync.md:88-103`
[^5]: https://docs.openclaw.ai/gateway/security
[^6]: https://docs.openclaw.ai/gateway/security
[^7]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-SECURITY.md:14-45`; https://docs.nanoclaw.dev/concepts/security
[^8]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-mount-security.ts:1-114`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-mount-security.ts:194-260`
[^9]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-container-runner.ts:61-90`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-container-runner.ts:118-178`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-container-runner.ts:213-259`
[^10]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-ipc.ts:30-155`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\nanoclaw-ipc.ts:183-220`
[^11]: https://www.harmonic.security/resources/securing-claude-cowork-a-security-practitioners-guide
[^12]: https://www.mintmcp.com/blog/claude-cowork-security
[^13]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\openclaw-cli-security.md:17-80`
[^14]: `C:\src\DevCronAgents\docs\FUTURE.md:39-41`
[^15]: https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html
[^16]: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/
[^17]: https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html
[^18]: https://techcommunity.microsoft.com/blog/marketplace-blog/securing-ai-agents-the-enterprise-security-playbook-for-the-agentic-era/4503627
[^19]: https://prompt.security/clawsec; https://github.com/prompt-security/clawsec/
[^20]: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/
[^21]: `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\open-cowork-main.js:22-56`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\open-cowork-preload.js:8-118`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\open-cowork-server.js:18-24`; `C:\Users\evanAdmin_1\.copilot\session-state\cb5363f8-7c5f-42d6-bb0d-0d2eea2cf2d3\files\research-refs\open-cowork-server.js:60-174`
[^22]: https://github.com/qwibitai/nanoclaw/blob/main/docs/docker-sandboxes.md
[^23]: `C:\src\DevCronAgents\docs\FUTURE.md:23-26`
