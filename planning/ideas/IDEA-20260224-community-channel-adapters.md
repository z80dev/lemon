---
id: IDEA-20260224-community-channel-adapters
title: [Community] Additional Channel Adapters (Discord, Slack, WhatsApp)
source: community
source_url: https://openclaw.ai/
discovered: 2026-02-24
status: proposed
---

# Description
Community users are actively deploying AI agents across multiple messaging platforms. OpenClaw's success is largely driven by its multi-channel support, enabling users to interact with agents through their preferred platforms.

## Evidence

### OpenClaw Multi-Channel Support
OpenClaw supports extensive channel integrations:
- **Discord** - Primary community platform
- **Telegram** - One bot per agent
- **WhatsApp** - Link each phone number per account
- **Slack** - Enterprise integration
- **iMessage** - Apple ecosystem
- **Signal** - Privacy-focused
- **Google Chat** - Workspace integration
- **Microsoft Teams** - Enterprise
- **Matrix** - Open protocol
- **Zalo** - Regional (Vietnam)
- **BlueBubbles** - iMessage on non-Apple devices
- **WebChat** - Browser-based

### Community Usage Patterns
- **Discord bots** for community management
- **WhatsApp** for personal assistant use
- **Slack/Teams** for workplace automation
- **Telegram** for developer workflows
- **iMessage** for Apple users

### Use Cases
- "Discord admin deploys an OpenClaw bot to help manage their server"
- "Claw can just keep building upon itself just by talking to it in discord"
- Multi-channel routing for different contexts

# Lemon Status
- Current state: **Partial** - Has Telegram and X (Twitter) adapters
- Gap analysis:
  - Has `LemonChannels.Adapters.Telegram`
  - Has `LemonChannels.Adapters.XAPI`
  - Has XMTP adapter (messaging protocol)
  - No Discord adapter
  - No Slack adapter
  - No WhatsApp adapter
  - No other messaging platform support

## Current Implementation
```
apps/lemon_channels/lib/lemon_channels/adapters/:
- telegram/ - Telegram bot adapter
- telegram.ex
- x_api/ - X (Twitter) adapter
- x_api.ex
- xmtp/ - XMTP messaging protocol
- xmtp.ex
```

## What's Missing
1. Discord adapter (highest community demand)
2. Slack adapter (enterprise use)
3. WhatsApp adapter (personal use)
4. iMessage/BlueBubbles adapter
5. Signal adapter
6. Google Chat adapter
7. Microsoft Teams adapter
8. Matrix adapter
9. WebChat/WebSocket adapter

# Value Assessment
- Community demand: **HIGH** - OpenClaw's success driven by multi-channel
- Strategic fit: **MEDIUM** - Expands addressable use cases
- Implementation complexity: **MEDIUM** - Each adapter requires platform-specific work

# Recommendation
**Investigate** - Prioritize channel adapters by demand:
1. **Discord** - Highest community demand, OpenClaw's primary platform
2. **Slack** - Enterprise use cases
3. **WhatsApp** - Personal assistant use
4. **WebChat** - Generic web interface

## Implementation Approach
Each adapter should:
1. Implement `LemonChannels.Adapter` behavior
2. Support inbound messages (agent receives)
3. Support outbound messages (agent sends)
4. Handle platform-specific auth
5. Support rich content (images, files) where possible

# References
- https://openclaw.ai/
- https://docs.openclaw.ai/concepts/multi-agent
- https://github.com/openclaw/openclaw
- https://www.ibm.com/think/news/clawdbot-ai-agent-testing-limits-vertical-integration
