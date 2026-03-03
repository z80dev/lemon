---
id: IDEA-20260306-community-mcp-industry-standard
title: MCP (Model Context Protocol) Now Industry Standard - Full Ecosystem Support
source: community
source_url: https://thenewstack.io/ai-engineering-trends-in-2025-agents-mcp-and-vibe-coding/
discovered: 2026-03-06
status: proposed
---

# Description
MCP (Model Context Protocol) has become an official industry standard as of March 2025, with OpenAI adopting it alongside Anthropic. This represents a major shift in the AI agent ecosystem toward protocol-based tool interoperability.

**Key developments:**
- OpenAI officially adopted MCP in March 2025
- Frameworks now competing on MCP-native support vs adapter layers
- MCP-native frameworks (mcp-agent, PydanticAI, OpenAI SDK, Google ADK) work directly with the protocol
- Frameworks that added MCP later use adapter layers (potential compatibility gaps)
- 12+ major frameworks now support MCP

**Community demand signals:**
- "How to build AI agents with MCP" is a top search query
- MCP servers for filesystem, fetch, Slack, Jira, FastMCP apps connect without custom adapters
- Production-ready features: Temporal-backed durability, structured logging, token accounting

# Lemon Status
- **Current state**: Partial implementation exists (`apps/lemon_mcp/`)
- **Gap analysis**: Lemon has MCP client/server but may need deeper ecosystem integration and promotion as a first-class feature

# Investigation Notes
- **Complexity estimate**: M
- **Value estimate**: H
- **Open questions**:
  - Is Lemon's MCP implementation complete enough for ecosystem compatibility?
  - Should we prioritize MCP tool registry integration?
  - How do we position against mcp-agent and other MCP-native frameworks?
  - What MCP servers should we test compatibility with?

# Recommendation
**Proceed** - MCP is now table stakes for AI agent frameworks. Lemon should ensure full MCP compatibility and consider it a core differentiator.

**Action items:**
1. Audit current MCP implementation for spec compliance
2. Test compatibility with popular MCP servers (filesystem, GitHub, Slack)
3. Document MCP capabilities prominently
4. Consider MCP-first architecture for new tool integrations
5. Add MCP server discovery/registration capabilities

# References
- https://thenewstack.io/ai-engineering-trends-in-2025-agents-mcp-and-vibe-coding/
- https://clickhouse.com/blog/how-to-build-ai-agents-mcp-12-frameworks
- https://dev.to/hani__8725b7a/agentic-ai-frameworks-comparison-2025-mcp-agent-langgraph-ag2-pydanticai-crewai-h40
- https://github.com/lastmile-ai/mcp-agent
