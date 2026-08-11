# lemon_ai

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_ai` is the provider-agnostic LLM client: it owns the provider behaviour and its
implementations, the model registry, rate limiting, circuit breaking, context compaction,
and the token/text helpers. It sits at the bottom of the platform dependency graph — it
depends on nothing else in the platform and everything above it (`lemon_agent`, and
through it router/gateway/channels/products) depends on it. This page will become the
package README: supported providers, how to register a new one, streaming and tool-call
semantics, and the retry/rate-limit knobs. Source today is `apps/lemon_ai`; it is published
first because every other package needs it.
