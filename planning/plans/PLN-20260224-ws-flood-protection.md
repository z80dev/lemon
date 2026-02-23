## Metadata
- **Plan ID**: PLN-20260224-ws-flood-protection
- **Status**: landed
- **Created**: 2026-02-24
- **Author**: claude
- **Workspace**: feature/ws-flood-protection
- **Change ID**: svnuxqzrqyqzovnmywpzzvptztrqmyyv
- **Idea Source**: [IDEA-20260224-openclaw-ws-flood-protection](../ideas/IDEA-20260224-openclaw-ws-flood-protection.md)

## Summary

Add an unauthorized request flood guard to the `TwilioWebSocket` WebSocket handler in `lemon_gateway`. Connections that send more than 10 consecutive unauthorized (unrecognized/malformed) post-handshake frames are closed with a normal stop. This mirrors the OpenClaw security hardening in PR #24294.

## Scope

### In Scope
- Track unauthorized post-handshake requests per WebSocket connection in handler state
- Close connections that reach or exceed the configurable threshold (default: 10)
- Count three categories of unauthorized frames: invalid JSON, unrecognized Twilio event types, and unexpected binary frames
- Test coverage for all flood guard scenarios

### Out of Scope
- Rate limiting on the HTTP upgrade / pre-handshake path
- IP-level blocking or persistent ban lists
- Changes to DeepgramClient or CallSession

## Implementation

### Files Changed
- `apps/lemon_gateway/lib/lemon_gateway/voice/twilio_websocket.ex`
- `apps/lemon_gateway/test/lemon_gateway/voice/twilio_websocket_test.exs`

### Design

Added `unauthorized_count: 0` to `TwilioWebSocket` state and a module attribute `@unauthorized_flood_threshold 10`. All paths that receive a frame not matching the expected Twilio Media Streams protocol call the new private function `handle_unauthorized_request/1`:

- `handle_in` text path — JSON decode failure
- `handle_in` binary path — unexpected binary frame
- `handle_twilio_message/2` catch-all — unrecognized event type

`handle_unauthorized_request/1` increments the counter and returns `{:stop, :normal, state}` once the threshold is reached, logging a warning with call SID and request count.

Authorized traffic (`connected`, `start`, `media`, `mark`, `stop` events on text frames) is unaffected and does not increment the counter.

## Success Criteria
- [x] Unauthorized flood guard implemented with configurable threshold
- [x] Connections exceeding threshold are closed (`{:stop, :normal, state}`)
- [x] Authorized traffic does not increment counter
- [x] Tests cover: single unauthorized frame, threshold crossing, binary frames, authorized traffic immunity, sub-threshold behavior
- [x] All 40 voice tests pass

## Progress Log
| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-02-24 13:05 | claude | Implemented flood guard and tests | 40/40 tests pass | - |

## Related
- Idea: [IDEA-20260224-openclaw-ws-flood-protection](../ideas/IDEA-20260224-openclaw-ws-flood-protection.md)
- OpenClaw source: PR #24294, commit 7fb69b7cd26a0981931544a556fb67bed8a31e6c
