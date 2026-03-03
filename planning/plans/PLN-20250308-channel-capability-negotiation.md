---
id: PLN-20250308-channel-capability-negotiation
title: Channel Capability Negotiation (Attachments, Rich Blocks, Streaming)
status: landed
owner: janitor
workspace: feature/pln-20250308-channel-capability-negotiation
change_id: dfd1cf5b
created: 2026-03-08
landed: 2026-03-08
---

# Channel Capability Negotiation (Attachments, Rich Blocks, Streaming)

## Summary

Implement a capability registry and negotiation layer that allows tools and renderers to query what each channel supports (attachments, structured UI blocks, streaming) and gracefully degrade when capabilities are unavailable.

## Background

- **Source**: Community demand (OpenClaw issues #18426, #12602, #4391)
- **Related Idea**: `IDEA-20260227-community-channel-capability-negotiation`
- **Current State**: Lemon has adapters for Telegram/Discord/X/XMTP but no explicit capability contracts

## Problem Statement

Current channel adapters handle capabilities implicitly:
- File uploads work differently per channel
- Rich message blocks (Block Kit, etc.) are adapter-specific
- Streaming support varies
- Tools can't query capabilities before attempting operations

This leads to:
- Adapter-specific one-off implementations
- Inconsistent user experience across channels
- Fragile error handling for unsupported features

## Scope

### In Scope

1. **Capability Registry**: Define capability types (attachments, rich_blocks, streaming, threads, reactions)
2. **Channel Capability Declaration**: Each adapter declares its capabilities
3. **Capability Query API**: Tools can query channel capabilities
4. **Graceful Degradation**: Automatic fallback for unsupported capabilities
5. **Rich Block Abstraction**: Common format that maps to channel-specific blocks

### Out of Scope

- New channel adapters (use existing ones)
- UI for capability configuration
- Dynamic capability changes at runtime

## Success Criteria

- [ ] Capability registry with all major capability types
- [ ] All existing adapters declare their capabilities
- [ ] Tools can query capabilities before operations
- [ ] Rich blocks render appropriately per channel
- [ ] Graceful degradation for unsupported features
- [ ] Tests for capability negotiation
- [ ] Documentation for adding new capabilities

## Implementation Plan

### Phase 1: Capability Registry (M1)

1. Create `LemonChannels.Capability` module with capability types
2. Define capability struct and validation
3. Add capability sets for common patterns
4. Create registry for capability lookups

### Phase 2: Adapter Capabilities (M2)

1. Add capability declarations to Telegram adapter
2. Add capability declarations to Discord adapter
3. Add capability declarations to X adapter
4. Add capability declarations to XMTP adapter
5. Create capability query functions

### Phase 3: Rich Block Abstraction (M3)

1. Design common rich block format
2. Implement Telegram block renderer
3. Implement Discord block renderer
4. Implement fallback text renderer
5. Add block validation

### Phase 4: Integration and Testing (M4)

1. Integrate capability checks into tool execution
2. Add graceful degradation logic
3. Unit tests for all capability types
4. Integration tests across adapters
5. Update documentation

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-08 | janitor | Created plan from IDEA-20260227-community-channel-capability-negotiation | Plan created | - |

## Related

- Parent idea: `IDEA-20260227-community-channel-capability-negotiation`
- Related work: Channel adapters in `apps/lemon_channels/`
- Related: Message rendering in channel adapters
