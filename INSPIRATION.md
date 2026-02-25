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
