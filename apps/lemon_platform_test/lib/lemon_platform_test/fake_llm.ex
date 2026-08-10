defmodule LemonPlatformTest.FakeLLM do
  @moduledoc """
  A scripted, deterministic stand-in for a real LLM provider, for driving an
  `AgentCore` agent loop in tests without a network call or an API key.

  `AgentCore` talks to a model through a *stream function* — a
  `fn model, context, options -> {:ok, event_stream} | {:error, reason}` that
  returns an `Ai.EventStream` process emitting a documented sequence of events:

      {:start, message}
      {:text_start, index, message}
      {:text_delta, index, chunk, message}
      {:text_end, index, message}
      {:tool_call_start, index, tool_call, message}
      {:tool_call_end, index, tool_call, message}
      {:done, stop_reason, message}

  That protocol is what every provider adapter produces and what the loop
  consumes; it is also fiddly to hand-roll, which is why testing a third-party
  agent against Lemon has meant reverse-engineering it. `FakeLLM` produces a
  conforming stream function from a plain script, so you can assert on what your
  agent *does* with a tool call or a refusal, rather than on how a model streams.

  ## A worked example

  `script/2` turns a list of turns — one per LLM round-trip — into a stream
  function you drop into `AgentCore.Types.AgentLoopConfig`:

      alias AgentCore.Loop
      alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
      alias Ai.Types.{StreamOptions, TextContent, UserMessage}
      alias LemonPlatformTest.FakeLLM

      weather_tool = %AgentTool{
        name: "get_weather",
        description: "Current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        },
        label: "Weather",
        execute: fn _id, %{"city" => city}, _signal, _on_update ->
          %AgentToolResult{content: [%TextContent{type: :text, text: "sunny in \#{city}"}]}
        end
      }

      # Round 1: the model calls the tool. Round 2, after it sees the result,
      # it answers in plain text.
      stream_fn =
        FakeLLM.script([
          {:tool_call, "get_weather", %{"city" => "Paris"}},
          {:text, "It is sunny in Paris."}
        ])

      context =
        AgentContext.new(
          system_prompt: "You are helpful.",
          tools: [weather_tool]
        )

      config = %AgentLoopConfig{
        model: FakeLLM.model(),
        convert_to_llm: & &1,
        stream_options: %StreamOptions{},
        stream_fn: stream_fn
      }

      prompt = %UserMessage{role: :user, content: "Weather in Paris?", timestamp: 0}
      stream = Loop.agent_loop([prompt], context, config, nil, nil)
      {:ok, messages} = AgentCore.EventStream.result(stream)

  `messages` now holds the whole exchange the loop produced: the assistant's
  tool call, the `get_weather` tool result, and the final text answer — exactly
  what a real provider would have driven, with nothing mocked in the loop itself.

  ## Script steps

  Each element of the script is one LLM round-trip. In order, the loop consumes
  one step per call to the stream function:

    * `{:text, text}` — a plain-text answer. Stops the loop (`stop_reason: :stop`).
    * `{:tool_call, name, arguments}` — a single tool call
      (`stop_reason: :tool_use`); the loop runs the tool and calls again for the
      next step. `arguments` is the map the tool's `execute` receives.
    * `{:tool_calls, [{name, arguments}, ...]}` — several tool calls in one
      assistant turn, run as a batch. List elements may also be `Ai.Types.ToolCall`
      structs when you need to pin the call id.
    * `{:refusal, text}` — the model declines: an assistant message carrying
      `text` with `stop_reason: :error` and `error_message` set. Use this to test
      how your agent surfaces a model-side refusal.
    * `{:error, reason}` — the provider call itself fails. The stream function
      returns `{:error, reason}` and no stream is produced, exercising the loop's
      transport-error path.
    * `%Ai.Types.AssistantMessage{}` — used verbatim, for cases the shorthands do
      not cover.
    * `fn model, context, options -> ... end` — an escape hatch invoked as the
      stream function for that one turn; return whatever a stream function may.

  ## Options

    * `:model` / `:provider` — stamped onto every generated message
      (defaults `"fake-llm"` / `:fake`). See also `model/1`.
    * `:usage` — an `Ai.Types.Usage` put on every generated message.
    * `:on_exhaust` — what to do when the loop asks for a step past the end of
      the script (most often because a tool-call turn was scripted without the
      answer turn that follows it): `:stop` (default) emits a terminal
      `stop_reason: :stop` message carrying a marker string, so the loop ends
      with `{:ok, messages}`; `:raise` raises instead, to catch a script shorter
      than the run it drives.

  A single step may be passed instead of a list; `script({:text, "hi"})` is
  `script([{:text, "hi"}])`.
  """

  alias Ai.Types.{AssistantMessage, Cost, TextContent, ToolCall, Usage}

  @default_model "fake-llm"
  @default_provider :fake
  @exhausted_text "(fake-llm: script exhausted)"

  @type step ::
          {:text, String.t()}
          | {:tool_call, String.t(), map()}
          | {:tool_calls, [{String.t(), map()} | ToolCall.t()]}
          | {:refusal, String.t()}
          | {:error, term()}
          | AssistantMessage.t()
          | (any(), any(), any() -> {:ok, pid()} | {:error, term()} | pid())

  @type stream_fn :: (any(), any(), any() -> {:ok, pid()} | {:error, term()})

  @doc """
  Builds a stream function that plays `steps` in order, one step per call.

  Suitable for `AgentCore.Types.AgentLoopConfig`'s `:stream_fn`. See the
  moduledoc for the step grammar and options.
  """
  @spec script(step() | [step()], keyword()) :: stream_fn()
  def script(steps, opts \\ [])

  def script(steps, opts) when is_list(steps) do
    # An assistant turn is itself a list of content blocks, so a bare tool-call
    # tuple list would be ambiguous. Steps are always the outer list; a single
    # step must be wrapped by the caller (or passed via the non-list clause).
    {:ok, agent} = Agent.start_link(fn -> steps end)
    on_exhaust = Keyword.get(opts, :on_exhaust, :stop)

    fn model, context, options ->
      step =
        Agent.get_and_update(agent, fn
          [] -> {:exhausted, []}
          [head | tail] -> {head, tail}
        end)

      run_step(step, model, context, options, opts, on_exhaust)
    end
  end

  def script(step, opts), do: script([step], opts)

  @doc """
  A synthetic `Ai.Types.Model` accepted by the agent loop.

  Pass `id:` / `provider:` to override; other fields carry test-friendly
  defaults. Handy as `AgentLoopConfig.model` when you only need the loop to run.
  """
  @spec model(keyword()) :: Ai.Types.Model.t()
  def model(opts \\ []) do
    %Ai.Types.Model{
      id: Keyword.get(opts, :id, @default_model),
      name: Keyword.get(opts, :name, "Fake LLM"),
      api: Keyword.get(opts, :api, :fake),
      provider: Keyword.get(opts, :provider, @default_provider),
      base_url: Keyword.get(opts, :base_url, "https://fake.invalid"),
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0},
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: %{},
      compat: nil
    }
  end

  # ── Step interpretation ─────────────────────────────────────────────────────

  defp run_step(:exhausted, _model, _ctx, _opts_in, opts, :stop) do
    # The loop rejects an empty assistant turn as an error, so the terminal
    # message must carry visible text; the marker makes its origin obvious if it
    # ever shows up in a transcript.
    {:ok, event_stream(assistant_message([text_block(@exhausted_text)], :stop, opts))}
  end

  defp run_step(:exhausted, _model, _ctx, _opts_in, _opts, :raise) do
    raise "LemonPlatformTest.FakeLLM script exhausted: the agent loop requested " <>
            "another LLM turn than the script provides. Add a step or pass " <>
            "on_exhaust: :empty."
  end

  defp run_step({:error, reason}, _model, _ctx, _opts_in, _opts, _exhaust) do
    {:error, reason}
  end

  defp run_step(fun, model, context, options, _opts, _exhaust) when is_function(fun, 3) do
    fun.(model, context, options)
  end

  defp run_step({:text, text}, _model, _ctx, _opts_in, opts, _exhaust) when is_binary(text) do
    {:ok, event_stream(assistant_message([text_block(text)], :stop, opts))}
  end

  defp run_step({:refusal, text}, _model, _ctx, _opts_in, opts, _exhaust) when is_binary(text) do
    message = %{
      assistant_message([text_block(text)], :error, opts)
      | error_message: text
    }

    {:ok, event_stream(message)}
  end

  defp run_step({:tool_call, name, args}, _model, _ctx, _opts_in, opts, _exhaust) do
    {:ok, event_stream(assistant_message([tool_call_block(name, args)], :tool_use, opts))}
  end

  defp run_step({:tool_calls, calls}, _model, _ctx, _opts_in, opts, _exhaust)
       when is_list(calls) do
    blocks = Enum.map(calls, &to_tool_call/1)
    {:ok, event_stream(assistant_message(blocks, :tool_use, opts))}
  end

  defp run_step(%AssistantMessage{} = message, _model, _ctx, _opts_in, _opts, _exhaust) do
    {:ok, event_stream(message)}
  end

  defp run_step(other, _model, _ctx, _opts_in, _opts, _exhaust) do
    raise ArgumentError,
          "LemonPlatformTest.FakeLLM: unrecognised script step #{inspect(other)}. " <>
            "See the moduledoc for the step grammar."
  end

  # ── Message construction ────────────────────────────────────────────────────

  defp assistant_message(content, stop_reason, opts) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :fake,
      provider: Keyword.get(opts, :provider, @default_provider),
      model: Keyword.get(opts, :model, @default_model),
      usage: Keyword.get(opts, :usage, default_usage()),
      stop_reason: stop_reason,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp text_block(text), do: %TextContent{type: :text, text: text}

  defp tool_call_block(name, args) do
    %ToolCall{type: :tool_call, id: generate_id(), name: name, arguments: args}
  end

  defp to_tool_call(%ToolCall{} = call), do: call
  defp to_tool_call({name, args}), do: tool_call_block(name, args)

  defp default_usage do
    %Usage{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
    }
  end

  # ── Event stream (the push protocol) ────────────────────────────────────────

  # Reproduces the exact event sequence a real provider adapter pushes, so the
  # agent loop's stream reducer sees nothing unusual. One EventStream per turn.
  defp event_stream(%AssistantMessage{} = message) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, message})

      message.content
      |> Enum.with_index()
      |> Enum.each(fn {block, index} -> push_block(stream, block, index, message) end)

      Ai.EventStream.push(stream, {:done, message.stop_reason, message})
      Ai.EventStream.complete(stream, message)
    end)

    stream
  end

  defp push_block(stream, %TextContent{text: text}, index, message) do
    Ai.EventStream.push(stream, {:text_start, index, message})
    Ai.EventStream.push(stream, {:text_delta, index, text, message})
    Ai.EventStream.push(stream, {:text_end, index, text, message})
  end

  defp push_block(stream, %ToolCall{} = call, index, message) do
    Ai.EventStream.push(stream, {:tool_call_start, index, message})
    Ai.EventStream.push(stream, {:tool_call_end, index, call, message})
  end

  defp push_block(_stream, _other, _index, _message), do: :ok

  defp generate_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
