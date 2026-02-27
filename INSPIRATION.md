# INSPIRATION.md

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

## 2026-02-27 Research Snapshot

### Upstream repo deltas reviewed
- **ironclaw**: web UX now persists tool-call history and restores pending approvals when switching threads (`759cd7e4ff2b`)
- **openclaw**: model routing hardening for Gemini provider aliases/bare IDs (`e6be26ef1c1a`, `17578d77e1d9`)
- **oh-my-pi / pi**: reviewed latest week window; notable commits tracked but no higher-priority net-new gaps beyond current focus areas

### Community/trend signals
- Agent operators continue asking for **deny-first command approval models** (explicit allowlists, path-aware command trust boundaries).
- Multi-channel users are increasingly requesting **capability-aware agent responses** (attachments, rich blocks, native stream semantics) instead of text-only fallback behavior.

### New ideas added
- `IDEA-20260227-ironclaw-approval-state-thread-resume`
- `IDEA-20260227-openclaw-provider-model-alias-normalization`
- `IDEA-20260227-community-reverse-permission-hierarchy`
- `IDEA-20260227-community-channel-capability-negotiation`

## 2026-02-27 Late Snapshot

### Upstream repo deltas reviewed
- **ironclaw**: routines now support notification delivery across all installed channels from a single run (`e4f2fba762f0`)
- **openclaw**: improved device-auth v2 migration diagnostics for clearer remediation (`cb9374a2a10a`)
- **oh-my-pi / pi**: reviewed latest window; notable commits were lower-priority relative to active Lemon roadmap gaps

### Community/trend signals
- Operators want **persistent per-channel model policy** (not ephemeral session-only overrides) for cost/performance segmentation.
- Multi-channel orchestrator users need **durable sessions independent of thread capability** in specific adapters.

### New ideas added
- `IDEA-20260227-ironclaw-routine-multichannel-broadcast`
- `IDEA-20260227-openclaw-device-auth-migration-diagnostics`
- `IDEA-20260227-community-per-channel-model-overrides`
- `IDEA-20260227-community-session-thread-decoupling`

## 2026-02-27 Late Snapshot #2

### Upstream repo deltas reviewed
- **openclaw**: hardened tool dispatch by normalizing whitespace-padded tool call names before lookup (`6b317b1f174d`)
- **openclaw**: Telegram reply context now includes replied media metadata/files, not just text/caption (`aae90cb0364e`)
- **oh-my-pi / pi / ironclaw**: reviewed latest week window; additional commits noted but lower-priority vs active Lemon gaps

### Community/trend signals
- Community automation requests are expanding toward **programmatic channel lifecycle ops** (create/configure/archive channels) instead of message-only integrations.
- Industry research is emphasizing **topology-adaptive orchestration** (parallel/sequential/hierarchical/hybrid) as a primary lever for multi-agent performance.

### New ideas added
- `IDEA-20260227-openclaw-tool-call-name-normalization`
- `IDEA-20260227-openclaw-telegram-reply-media-context`
- `IDEA-20260227-community-channel-lifecycle-ops`
- `IDEA-20260227-community-topology-adaptive-orchestration`

## 2026-02-27 Late Snapshot #3

### Upstream repo deltas reviewed
- **oh-my-pi**: introduced lenient schema/argument validation fallback + circular-safe handling for malformed provider payloads (`d78321b5fda9`, `cde857a5b6be`)
- **pi**: added offline startup mode and network timeout budgeting for coding-agent bootstrap (`757d36a41b96`)
- **openclaw / ironclaw**: reviewed latest week window; no higher-priority net-new gaps beyond already tracked channel/session and routine continuity items

### Community/trend signals
- Community onboarding friction remains high when channel setup fails with generic plugin-availability errors, with weak guided recovery (OpenClaw issue #24781 + related threads).
- Industry self-hosted momentum is increasingly bundling "offline/air-gapped readiness" as a purchase/adoption criterion, not only model quality.

### New ideas added
- `IDEA-20260227-oh-my-pi-lenient-schema-validation-fallback`
- `IDEA-20260227-pi-offline-startup-network-timeouts`
- `IDEA-20260227-community-channel-onboarding-plugin-diagnostics`
- `IDEA-20260227-industry-airgapped-agent-profile`
