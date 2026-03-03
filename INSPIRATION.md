# INSPIRATION.md

## 2026-03-07 Research Snapshot

### Upstream repo deltas reviewed
- **ironclaw**: v0.13.1, v0.13.0 released with auto-compact and retry on ContextLengthExceeded (`6f21cfa`) - automatic context management when hitting token limits
- **oh-my-pi**: v13.5.8, v13.5.7 released with strict mode for OpenAI providers (`6c52f8cf6`, `3a9ff9720`) - stricter JSON schema validation for improved tool call reliability
- **oh-my-pi**: v13.0+ with consolidated hashline edit operations, simplified developer role handling, in-memory todo phase management
- **openclaw**: Synology Chat channel adapter added - self-hosted NAS messaging support for home-lab environments
- **pi**: v0.55.4 with incremental highlight for streaming write tool calls - UX improvement for long outputs

### Community/trend signals
- **MCP is now official industry standard** - OpenAI adopted Model Context Protocol in March 2025; 12+ frameworks now compete on MCP-native support vs adapter layers
- **Production readiness gaps** - 45% of engineering leaders cite accurate tool calling as top challenge; agents lack context window awareness and operational awareness (OS/environment state)
- **"Agentic slop"** - Industry term emerging for poor quality AI outputs that require significant human cleanup
- **Air-gapped deployment demand** - Enterprise adoption increasingly requires offline/air-gapped operational posture; self-hosted agents need deterministic bootstrap expectations
- **MCP-native vs MCP-adopter** - Frameworks built for MCP (mcp-agent, PydanticAI, OpenAI SDK, Google ADK) work directly with protocol; adapter-based frameworks face compatibility gaps

### New ideas added
1. `IDEA-20260306-ironclaw-auto-compact-context-retry` - Automatic context compaction on limit errors
2. `IDEA-20260306-oh-my-pi-strict-mode-openai` - OpenAI strict mode for tool schemas
3. `IDEA-20260306-openclaw-synology-chat-adapter` - Synology Chat channel evaluation
4. `IDEA-20260306-community-mcp-industry-standard` - MCP ecosystem positioning
5. `IDEA-20260306-community-production-readiness-gaps` - Production readiness improvements

### Strategic confirmations
1. **MCP is table stakes** - Industry standard status means Lemon must ensure full MCP compatibility and promote it as a core feature
2. **Context window management** - Automatic compaction/retry is becoming expected behavior for production agents
3. **Production readiness** - Major enterprise differentiator opportunity; context awareness + operational awareness are gaps to fill
4. **Air-gapped/offline** - Growing enterprise requirement; aligns with Lemon's local-first BEAM architecture
5. **Strict mode** - Worth investigating for OpenAI tool call reliability improvements

## 2026-03-02 Research Snapshot

### Upstream repo deltas reviewed
- **oh-my-pi**: v13.1.1 released with local URL resolution fixes, job polling tool renamed to `await`, tool schema refactoring for consistency
- **pi**: v0.54.2 released with skill auto-discovery in `.agents` paths by default (confirmed: **Lemon already has parity**)
- **openclaw**: Full Mistral AI provider support added (commit d92ba4f8a), Synology Chat channel support, cron jobId hardening
- **ironclaw**: v0.11.1 released with FullJob routine mode + scheduler dispatch, hot-activate WASM channels, channel-first prompts

### Community/trend signals
- **Production readiness gap**: Industry analysis (VentureBeat, The New Stack) identifies critical blockers: brittle context windows, broken refactors, missing operational awareness (OS/environment), "agentic slop"
- **Multi-agent orchestration**: OpenAI Agents SDK and community converging on structured output-based orchestration patterns (chaining, handoffs)
- **OpenClaw vs Claude Code**: Community views them as complementary - OpenClaw = "Swiss Army knife" for proactive automation; Claude Code = "surgical scalpel" for strict self-correction
- **AI coding agents not production-ready**: Users report lack of OS/machine awareness, environment detection (conda/venv), and context budget management

### New ideas added
1. `IDEA-20260302-ironclaw-fulljob-routine-mode` - Scheduled job execution with scheduler dispatch
2. `IDEA-20260302-pi-skill-auto-discovery` - Skill auto-discovery parity confirmation (already implemented)
3. `IDEA-20260302-openclaw-mistral-provider-support` - Mistral AI provider support evaluation
4. `IDEA-20260302-community-ai-agent-production-readiness` - Address production deployment blockers

### Strategic confirmations
1. **Skill auto-discovery**: Lemon's approach is validated - Pi just added this as a new feature, Lemon already had it
2. **Production readiness**: Major industry gap identified - opportunity for Lemon to differentiate on reliability
3. **Mistral support**: Worth evaluating for EU market and cost-sensitive use cases
4. **Routine/Job scheduling**: IronClaw's FullJob pattern could enhance Lemon's cron/automation capabilities

## 2026-02-28 Research Snapshot

### Upstream repo deltas reviewed
- **oh-my-pi**: No new commits since 2026-02-23 (already captured: strict mode fixes, hashline edit operations, todo phase management, tool schema refactoring)
- **pi**: No new commits since 2026-02-23 (already captured: incremental highlight for streaming, extension theme persistence)
- **openclaw**: No new commits since 2026-02-22 (already captured: cron jobId hardening, markup sanitization, config redaction, Mistral support)
- **ironclaw**: No new commits since 2026-02-23 (already captured: shell completion, context compaction, Telegram improvements)

### Community/trend signals
- **MCP (Model Context Protocol)** is now officially an industry standard - OpenAI adopted it in March 2025 across products including ChatGPT desktop app
- **WASM sandboxing for AI agents** is gaining major traction - Microsoft released Wassette (WebAssembly-based tools for AI agents), NVIDIA published sandboxing guidance
- **Self-hosted AI coding agents** remain a strong community demand - users want local LLM support without external API dependencies
- **Multi-channel AI agents** (Discord, Telegram, Slack) are table stakes - OpenClaw's success driven by broad channel support
- **AI agent comparison content** shows OpenClaw vs Claude Code as the key comparison - OpenClaw wins on proactive automation/Heartbeat and local control; Claude Code wins on strict self-correction loops

### Research findings
All upstream deltas from Feb 22-23 have been previously captured. No new idea artifacts required for this run.

### Strategic confirmations
1. **MCP integration** remains high priority - industry standard now with OpenAI adoption
2. **WASM sandbox enhancements** align with Microsoft/NVIDIA industry direction
3. **Discord adapter** would capture OpenClaw-style community use cases
4. **Local/offline deployment** patterns need continued investment

## 2026-02-25 Late Snapshot

### Upstream repo deltas reviewed
- **openclaw**: system prompt now explicitly directs schema-first config behavior (`config.schema` before config edits/questions) (`975c9f4b5457`)
- **oh-my-pi**: changelog tooling hardening with shared categories + schema validation for entry/delete payloads (`80580edd5994`)

### Community/trend signals
- Long-running autonomous coding loops are converging on **episodic execution with git-verified handoffs** to avoid false progress and drift loops.
- Security operators are increasingly treating always-on local agents as **high-privilege automation surfaces** that need explicit consent scopes and exposure guardrails.

### New ideas added
- `IDEA-20260225-openclaw-schema-first-config-ops`
- `IDEA-20260225-oh-my-pi-changelog-schema-hardening`
- `IDEA-20260225-community-episodic-git-verified-handoffs`
- `IDEA-20260225-community-autonomous-agent-consent-scopes`

## 2026-02-25 Follow-up Snapshot

### Upstream repo deltas reviewed
- **openclaw**: onboarding/auth flow expanded for secret-ref parity across built-in and custom providers (`66295a7a1489`)
- **ironclaw**: fixed tool/channel name collisions with kind-aware extension lookup + stronger install validation (`e9f32eaebea2`)

### Community/trend signals
- Community reports now include a sharper failure mode than generic quota pauses: a **single session can remain permanently wedged** on rate-limit errors even after global reset windows.
- Industry guidance is shifting toward **trace-level agent evaluation** with drift alerts and periodic HITL audits (not just final-output scoring).

### New ideas added
- `IDEA-20260225-openclaw-secrets-onboarding-parity`
- `IDEA-20260225-ironclaw-kind-aware-extension-registry`
- `IDEA-20260225-community-rate-limit-session-self-healing`
- `IDEA-20260225-community-trace-driven-agent-evaluation`

## 2026-02-25 Research Snapshot

### Upstream repo deltas reviewed
- **ironclaw**: setup wizard now includes an OpenRouter preset with provider-specific labeling and prefilled base URL (`62dc5d046e28`)
- **openclaw**: cron path/schema hardening around `jobId` handling for `cron.runs` (`259d86335378`)
- **oh-my-pi / pi**: no additional high-priority functional gaps in latest week window beyond already tracked ideas

### Community/trend signals
- Long-run coding users continue requesting **auto-resume after provider limit reset** rather than manual return/resume.
- Industry automation guidance is converging on **workflow-as-markdown + mandatory human review** for high-impact actions.

### New ideas added
- `IDEA-20260225-ironclaw-openrouter-setup-preset`
- `IDEA-20260225-openclaw-cron-jobid-hardening`
- `IDEA-20260225-community-rate-limit-auto-resume`
- `IDEA-20260225-community-guardrailed-agentic-workflows`

## 2026-02-24 Research Snapshot

### Upstream repo deltas reviewed
- **oh-my-pi**: model picker role badge improvements (`1648b2ad0e42`)
- **openclaw**: env-backed secret refs + plaintext avoidance for auth persistence (`18546f31e61f`, `121f204828cb`)
- **ironclaw**: native Signal channel adapter via `signal-cli` HTTP daemon (`b0b3a50fa38d`)
- **pi**: streaming + resolver updates reviewed; no net-new high-priority gap beyond already-tracked items

### Community/trend signals
- OpenClaw usage narratives continue emphasizing multi-channel reach and local-first control.
- Azure/Microsoft architecture content reinforces multi-agent pattern maturity.
- Community feedback highlights quota/limit interruptions during long coding sessions.

### New ideas added
- `IDEA-20260224-openclaw-env-backed-secret-refs`
- `IDEA-20260224-ironclaw-signal-channel-adapter`
- `IDEA-20260224-oh-my-pi-model-role-badge`
- `IDEA-20260224-community-quota-aware-agent-runs`
