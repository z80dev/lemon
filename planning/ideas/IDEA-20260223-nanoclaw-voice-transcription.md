---
id: IDEA-20260223-nanoclaw-voice-transcription
title: [Nanoclaw] Voice Transcription as Nanorepo Skill
source: nanoclaw
source_commit: a407216
discovered: 2026-02-23
status: proposed
---

# Description
Nanoclaw added voice transcription as a nanorepo skill (commit a407216). This feature:
- Adds OpenAI Whisper-based voice transcription
- Integrates with WhatsApp to detect/transcribe voice notes
- Includes 3 test cases and 8 skill validation tests
- Uses skills engine for modular deployment

Key changes in upstream:
- New skill at `.claude/skills/add-voice-transcription/`
- Modified `src/channels/whatsapp.ts` for voice note handling
- Added `src/transcription.ts` with Whisper integration

# Lemon Status
- Current state: **Partial** - Lemon has SMS/voice tools but may lack transcription
- Gap analysis:
  - Lemon has `LemonGateway.Tools.SmsListMessages` and `SmsWaitForCode`
  - Has Twilio integration for SMS
  - May not have voice note transcription
  - No WhatsApp integration currently

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M** - Useful for voice-based interactions
- Open questions:
  1. Does Lemon have any voice transcription currently?
  2. Should this be a skill or built-in feature?
  3. How would this integrate with Lemon's channel system?
  4. What's the cost/complexity of Whisper integration?

# Recommendation
**Defer** - Nice feature but not critical. Consider when:
1. Voice becomes a priority for Lemon
2. WhatsApp integration is added
3. Skills system supports this type of extension

# References
- Nanoclaw commit: a407216
- Lemon files:
  - `apps/lemon_gateway/lib/lemon_gateway/tools/sms_list_messages.ex`
  - `apps/lemon_gateway/lib/lemon_gateway/tools/sms_wait_for_code.ex`
