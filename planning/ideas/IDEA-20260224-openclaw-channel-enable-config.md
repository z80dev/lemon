---
id: IDEA-20260224-openclaw-channel-enable-config
title: Per-channel enabled configuration for bundled channels
source: openclaw
source_commit: 3cadc3eed
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw fixed a configuration issue where bundled channels weren't properly respecting the `channels.<id>.enabled` setting. This allows fine-grained control over which bundled channels are active.

Key features:
- Honor `channels.<id>.enabled` configuration for bundled channels
- Proper plugin loader integration with channel enablement checks
- Test coverage for channel enable/disable scenarios

Example configuration:
```yaml
channels:
  slack:
    enabled: false  # Disable bundled Slack channel
  discord:
    enabled: true   # Enable bundled Discord channel
```

# Lemon Status
- Current state: Lemon has channel configuration but unclear if per-channel enable is supported
- Gap: Need to verify if lemon_channels supports per-channel enabled flags

# Investigation Notes
- Complexity estimate: S
- Value estimate: M (configuration flexibility)
- Open questions:
  - Does Lemon's GatewayConfig already support per-channel enabled flags?
  - How does Lemon handle channel enablement currently?
  - Is this a bug fix or a new feature for Lemon?

# Recommendation
investigate - Need to verify current Lemon behavior. If Lemon doesn't properly respect per-channel enabled flags, this is a small bug fix. If it does, this can be closed as already implemented.

# References
- OpenClaw commit: 3cadc3eed
- Files affected: plugins/loader.ts, plugins/loader.test.ts
