# Lemon for Dummies

A plain-English guide to how Lemon works, written for someone who wants to use
Lemon as a personal AI assistant and understand what happens under the hood.

No Elixir or BEAM experience required. We'll explain everything as we go.

---

## How to Read This Guide

The guide follows a single message from your phone all the way through Lemon
and back. Each part zooms into one layer of the system. You can read them in
order for the full picture, or jump to whichever part interests you.

| Part | Title | What You'll Learn |
|------|-------|-------------------|
| [1](01-big-picture.md) | The Big Picture | What Lemon is, why it exists, and a bird's-eye view of the architecture |
| [2](02-message-journey.md) | Your Message's Journey | End-to-end trace of a Telegram message through every layer and back |
| [3](03-the-front-door.md) | The Front Door (lemon_channels) | How Telegram messages arrive, get normalized, and how responses get delivered |
| [4](04-the-traffic-cop.md) | The Traffic Cop (lemon_router) | How messages get routed to the right agent, sessions, and run orchestration |
| [5](05-the-engine-room.md) | The Engine Room (lemon_gateway) | How AI engines are selected and managed, the scheduling system |
| [6](06-the-agent.md) | The Agent (coding_agent + agent_core) | What Lemon can actually do: tools, the agent loop, sessions, and memory |
| [7](07-talking-to-llms.md) | Talking to LLMs (ai) | How Lemon communicates with Claude, GPT, Gemini, and other AI models |
| [8](08-the-foundation.md) | The Foundation (lemon_core) | Config, storage, the event bus, and the glue that holds everything together |

---

## The One-Paragraph Version

You send a message to a Telegram bot on your phone. That message is picked up
by **lemon_channels**, which normalizes it and hands it to the **lemon_router**.
The router figures out which conversation this belongs to, what AI engine to use,
and queues up a "run." The **lemon_gateway** picks up that run, selects an
engine (like Claude or Lemon's native engine), and starts executing. The engine
uses **agent_core** to run an agent loop that can call 30+ **tools** (read
files, run shell commands, search the web, etc.) and talks to LLM providers
through the **ai** package. As the AI streams its response, the text flows back
through the gateway, router, and channels, ultimately appearing as a Telegram
message on your phone. All of this is built on top of **lemon_core**, which
provides config, storage, and the event bus that connects everything.

---

## Prerequisites

This guide assumes you:

- Have Lemon installed and running (see the main [README](../../README.md) for setup)
- Have a Telegram bot configured and can send it messages
- Are curious about how things work under the hood

You do **not** need to know Elixir, Erlang, or anything about the BEAM VM.
We'll explain relevant concepts in plain English when they come up.
