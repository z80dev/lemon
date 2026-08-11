# Build your first agent

This guide takes you from an empty directory to an agent that calls a tool and
answers a question, with a test suite that runs offline. It should take about
ten minutes, and you do not need an API key until the last section.

Everything here is written against the output of `mix lemon.new`, so you can
paste any block into the project you generate in step 2 and it will work.

## 1. Install the generator

The platform packages are not on Hex yet, so both the generator and the
dependencies come from a checkout of the [lemon](https://github.com/z80dev/lemon)
repository.

```bash
git clone https://github.com/z80dev/lemon
cd lemon/installer
MIX_ENV=prod mix archive.build
mix archive.install lemon_new-0.1.0.ez
```

You need Elixir 1.19 or later on OTP 27+. Check with `elixir --version`.

## 2. Generate a project

```bash
cd ~/code
mix lemon.new my_agent
cd my_agent
mix test
```

The tests pass. Nothing has talked to a model yet — more on that in step 4.

The generator wrote a plain Mix project, not an umbrella app:

```
my_agent/
  mix.exs                          three path deps on the platform
  config/config.exs                which model to run
  lib/my_agent.ex                  the facade
  lib/my_agent/application.ex      supervision tree
  lib/my_agent/agent.ex            model, system prompt, tool list
  lib/my_agent/console.ex          a terminal channel
  lib/my_agent/tools/word_count.ex one tool
  test/support/fake_llm.ex         a scripted model
```

### About those path dependencies

`mix.exs` points at your lemon checkout:

```elixir
{:lemon_core, path: "/path/to/lemon/apps/lemon_core"},
{:lemon_ai, path: "/path/to/lemon/apps/lemon_ai"},
{:lemon_agent, path: "/path/to/lemon/apps/lemon_agent"},
```

The generator bakes in the checkout it was built from. Override it with
`mix lemon.new my_agent --lemon-path /elsewhere/lemon` or by exporting
`LEMON_PATH`. When the packages publish, each path line is replaced by the Hex
line commented beneath it — note that two of the packages have a Hex name that
differs from the application name your code uses (`LemonAi` ships as `lemon_ai`,
`LemonAgent` as `lemon_agent`).

## 3. Read the agent

`lib/my_agent/agent.ex` is the only file where your decisions live. It does
three things.

**It picks a model.** `LemonAi.Models` is a registry of several hundred models across
about twenty providers, carrying the context window, pricing and capability
flags the loop needs:

```elixir
def model do
  provider = Application.get_env(:my_agent, :provider)
  id = Application.get_env(:my_agent, :model)
  LemonAi.Models.get_model(provider, id) || raise "..."
end
```

**It assembles the tool list.** Your own tools, plus any a dependency
contributed at runtime through `LemonAgent.ToolRegistry`:

```elixir
def tools do
  builtin = [MyAgent.Tools.WordCount.tool()]
  taken = Enum.map(builtin, &String.to_atom(&1.name))
  contributed = for {_name, module} <- LemonAgent.ToolRegistry.available(taken), do: module.tool()
  builtin ++ contributed
end
```

**It starts the loop.** `LemonAgent.new_agent/1` starts a GenServer holding the
conversation. `ask/2` prompts it and waits:

```elixir
def ask(agent, prompt) when is_binary(prompt) do
  with :ok <- LemonAgent.prompt(agent, prompt),
       :ok <- LemonAgent.wait_for_idle(agent) do
    case LemonAgent.get_state(agent) do
      %AgentState{error: nil} = state -> {:ok, last_answer(state)}
      %AgentState{error: error} -> {:error, error}
    end
  end
end
```

### What one run actually does

`LemonAgent.prompt/2` starts a run, and a run is a loop:

1. Send the conversation and the tool schemas to the model.
2. Stream the response back, emitting an event per fragment.
3. If the response contains tool calls, execute them — concurrently, each in a
   supervised task — and append the results to the conversation.
4. If any tool ran, go back to step 1. Otherwise the run ends.

The loop stops on its own when the model answers without asking for a tool, and
gives up after `max_tool_turns` (25 by default) if it never does.

## 4. Talk to a real model

```bash
export ANTHROPIC_API_KEY=sk-ant-...
mix run --no-halt -e "MyAgent.Console.start()"
```

```
MyAgent console. Ask something, or /quit to leave.

you> how many words are in "the quick brown fox"?
bot>
  [word_count…]There are 4 words.
```

The key is read per request from the provider's own environment variable, so
switching providers is a config change plus a different key:

```bash
MY_AGENT_PROVIDER=openai MY_AGENT_MODEL=gpt-5 OPENAI_API_KEY=sk-... \
  mix run --no-halt -e "MyAgent.Console.start()"
```

`LemonAi.Models.get_model_ids(:openai)` lists what a provider offers.

## 5. How the tests run without a key

`LemonAgent` reaches providers through exactly one function: a `stream_fn` taking
`(model, context, options)` and returning `{:ok, LemonAi.EventStream.t()}`. Replace it
and nothing else changes — the loop still parses tool calls, still executes
tools, still feeds results back.

`test/support/fake_llm.ex` is a scripted implementation of that function. Each
entry answers one model call:

```elixir
test "calls a tool and answers from its result" do
  agent =
    start_supervised!(
      {Agent,
       name: nil,
       stream_fn:
         FakeLLM.scripted([
           FakeLLM.tool_call("word_count", %{"text" => "one two three"}),
           FakeLLM.say("Three words.")
         ])}
    )

  assert {:ok, "Three words."} = Agent.ask(agent, "how many words in 'one two three'?")
end
```

That test really runs `MyAgent.Tools.WordCount.execute/4`. What it does not test
is whether your prompt makes a real model reach for the tool — no offline test
can, and it is worth being explicit about the boundary rather than trusting a
green suite too far.

There is no LLM test double in the platform packages today, so every project
writes some version of this file. If you build a better one, it belongs
upstream.

## Where to go next

- [Add a tool](add-a-tool.md) — the tool contract, and the two rules that matter
  more than the rest.
- [Add a channel](add-a-channel.md) — from the console loop to a registered
  `LemonChannels.Plugin`.
- [Persist memory](persist-memory.md) — durable, searchable memory across runs.
