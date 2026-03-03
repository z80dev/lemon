---
id: IDEA-20260306-oh-my-pi-strict-mode-openai
title: Tool Schema Strict Mode for OpenAI Providers
source: oh-my-pi
source_commit: 6c52f8cf6, 3a9ff9720
discovered: 2026-03-06
status: proposed
---

# Description
Oh-My-Pi v13.0+ introduced "strict mode" for tool schemas when using OpenAI providers. This enforces stricter JSON schema validation and can improve tool call reliability with certain OpenAI models that benefit from explicit strict mode signaling.

**Key behaviors:**
- Adds `strict: true` to tool schemas for OpenAI providers when enabled
- Corrected logic to treat undefined `tool.strict` as false (not true)
- Restructured tool schemas for consistency and clarity
- Simplified hashline edit operations with consolidated replace op

**Related changes:**
- Hashline edit operations consolidated into cleaner schema
- XML tag indent stripping improvements
- Developer role message handling simplification

# Lemon Status
- **Current state**: No strict mode support for OpenAI providers
- **Gap analysis**: Lemon's tool schemas don't signal strict mode to OpenAI; may miss reliability improvements

# Investigation Notes
- **Complexity estimate**: S
- **Value estimate**: M
- **Open questions**:
  - Which OpenAI models benefit from strict mode?
  - Does strict mode affect tool call success rates measurably?
  - Should strict mode be default or opt-in?
  - Impact on non-OpenAI providers (should be ignored)

# Recommendation
**Investigate** - Low-cost addition that may improve OpenAI tool call reliability. Worth measuring impact before full rollout.

**Implementation sketch:**
1. Add `strict` field to tool schema generation for OpenAI provider
2. Make it configurable per-provider or global
3. A/B test tool call success rates with/without strict mode
4. Consider default enablement based on results

# References
- Oh-My-Pi commits: `6c52f8cf6` ("feat: strict mode + simplified hashline edit operations"), `3a9ff9720` ("fix(ai): corrected strict mode logic")
- Oh-My-Pi release: v13.0.0, v13.0.2
