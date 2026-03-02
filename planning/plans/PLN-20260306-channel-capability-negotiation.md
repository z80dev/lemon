# Plan: Channel Capability Negotiation

## Metadata
- **Plan ID**: PLN-20260306-channel-capability-negotiation
- **Status**: planned
- **Created**: 2026-03-06
- **Author**: janitor
- **Workspace**: feature/pln-20260306-channel-capability-negotiation
- **Change ID**: pending

## Summary

Implement a channel capability negotiation system that allows agents to adapt output based on what each channel supports (file uploads, rich message blocks, streaming). This addresses community demand from OpenClaw issues (#18426, #12602, #4391) for channel-specific capabilities and enables graceful degradation when capabilities are unavailable.

The system provides:
1. A capability registry defining what each channel supports
2. A negotiation layer for querying channel support at runtime
3. Graceful degradation to supported formats when capabilities are unavailable
4. Rich output adaptation for attachments, structured blocks, and streaming semantics

This makes existing channels more powerful and future adapter additions safer and faster by providing explicit capability contracts rather than adapter-specific one-offs.

## Scope

### In Scope

- **Capability registry and schema definition** (M1)
  - Define capability taxonomy (attachments, rich blocks, streaming, etc.)
  - Schema for channel capability declarations
  - Versioning strategy for capability evolution

- **Channel capability detection and registration** (M2)
  - Runtime capability registration for adapters
  - Static capability definitions for built-in channels (Telegram, Discord, X, XMTP)
  - Dynamic capability probing where supported by underlying APIs

- **Capability query API for tools and renderers** (M3)
  - Runtime API for tools to query channel capabilities
  - Capability-aware rendering context injection
  - Type-safe capability contracts

- **Graceful degradation layer** (M4)
  - Automatic fallback to text-only when rich features unavailable
  - Content transformation pipeline (rich blocks → markdown → plain text)
  - User-visible indicators when content is simplified

- **Rich output adaptation** (M5)
  - Attachment upload adaptation (images, files, documents)
  - Structured block rendering (Block Kit, Discord embeds, Telegram rich text)
  - Streaming semantics adaptation (true streaming vs simulated)

- **Testing and documentation** (M6)
  - Unit tests for capability registry and negotiation
  - Integration tests across channel adapters
  - Developer documentation for adding new capabilities

### Out of Scope

- New channel adapters (Discord, Slack, WhatsApp) — these are tracked separately
- Full Block Kit/Discord embed builder UI components
- Multi-channel broadcast/fanout (tracked in IDEA-20260227-ironclaw-routine-multichannel-broadcast)
- Voice/audio streaming capabilities
- Video streaming or real-time media
- Channel lifecycle operations (create/archive/configure)

## Milestones

### M1: Capability Registry and Schema Definition

**Goal**: Establish the foundational capability taxonomy and schema.

**Deliverables**:
- [ ] Define capability taxonomy:
  - `attachments` (images, files, documents)
  - `rich_blocks` (structured UI components)
  - `streaming` (true streaming vs polling)
  - `reactions` (emoji reactions)
  - `threads` (native thread support)
  - `editing` (message editing)
  - `deletion` (message deletion)
  - `formatting` (markdown, HTML, plain text)
- [ ] Design capability schema (JSON/YAML/Elixir struct)
- [ ] Define capability versioning strategy
- [ ] Create capability validation functions

**Acceptance Criteria**:
- Schema can represent all current Lemon channel capabilities
- Validation rejects invalid capability declarations
- Documentation explains capability taxonomy

### M2: Channel Capability Detection and Registration

**Goal**: Enable channels to declare and register their capabilities.

**Deliverables**:
- [ ] Capability registry GenServer/ETS storage
- [ ] Registration API for channel adapters
- [ ] Static capability definitions for:
  - Telegram adapter
  - Discord adapter
  - X/Twitter adapter
  - XMTP adapter
- [ ] Capability introspection endpoints (for debugging)

**Acceptance Criteria**:
- All existing adapters register their capabilities
- Registry persists across hot reloads
- CLI command to list channel capabilities

### M3: Capability Query API for Tools and Renderers

**Goal**: Provide runtime capability querying for tools and renderers.

**Deliverables**:
- [ ] `Channel.capabilities/1` query function
- [ ] `Channel.supports?/2` predicate function
- [ ] Capability context injection into tool execution
- [ ] Capability-aware renderer selection

**Acceptance Criteria**:
- Tools can query capabilities before generating output
- Renderers adapt based on capability context
- Query API has <1ms latency (cached)

### M4: Graceful Degradation Layer

**Goal**: Implement automatic fallback when capabilities are unavailable.

**Deliverables**:
- [ ] Content transformation pipeline:
  - Rich blocks → Markdown
  - Markdown → Plain text
  - Attachments → Text links
- [ ] Degradation strategy configuration per channel
- [ ] User-visible "simplified" indicators
- [ ] Telemetry for degradation events

**Acceptance Criteria**:
- Rich content degrades gracefully to any channel
- Users understand when content is simplified
- Degradation is reversible (no data loss)

### M5: Rich Output Adaptation

**Goal**: Implement full rich output adaptation for supported channels.

**Deliverables**:
- [ ] Attachment upload adaptation:
  - Image uploads with caption handling
  - File/document upload with metadata
  - Size/format constraints per channel
- [ ] Structured block rendering:
  - Block Kit payloads for Slack (future)
  - Discord embeds
  - Telegram rich text/markdown
- [ ] Streaming semantics:
  - True streaming where supported
  - Simulated streaming for polling adapters
  - Chunking strategies per channel

**Acceptance Criteria**:
- Images upload natively where supported, fallback to links
- Rich blocks render in native format per channel
- Streaming behaves consistently across channels

### M6: Testing and Documentation

**Goal**: Ensure system reliability and developer adoption.

**Deliverables**:
- [ ] Unit tests for capability registry (90%+ coverage)
- [ ] Integration tests for each adapter
- [ ] Property-based tests for degradation paths
- [ ] Developer guide for adding capabilities
- [ ] Migration guide for existing adapters

**Acceptance Criteria**:
- All tests pass in CI
- Documentation is complete and reviewed
- Example adapter implementation provided

## Success Criteria

- [ ] All existing channel adapters register capabilities and pass integration tests
- [ ] Tool outputs automatically adapt to channel capabilities without code changes
- [ ] Rich content degrades gracefully with <100ms transformation overhead
- [ ] New capability can be added with <50 lines of code
- [ ] Documentation enables third-party adapter authors to implement capabilities
- [ ] Zero regressions in existing channel functionality
- [ ] Telemetry shows capability usage and degradation events

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-06 18:00 | janitor | Plan created | - | - |

## Related

- Parent idea: [IDEA-20260227-community-channel-capability-negotiation](../ideas/IDEA-20260227-community-channel-capability-negotiation.md)
- Related ideas:
  - IDEA-20260227-community-channel-adapters (additional channel adapters)
  - IDEA-20260227-ironclaw-routine-multichannel-broadcast (multi-channel broadcast)
  - IDEA-20260227-community-channel-lifecycle-ops (channel lifecycle operations)
