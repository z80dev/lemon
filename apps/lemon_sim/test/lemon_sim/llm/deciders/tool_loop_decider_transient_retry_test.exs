defmodule LemonSim.LLM.Deciders.ToolLoopDeciderTransientRetryTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{AssistantMessage, Context, Model, ToolCall}
  alias LemonSim.LLM.Deciders.ToolLoopDecider

  test "retries a transient rate-limit error and eventually succeeds" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _ctx, _stream_opts ->
      attempt = Agent.get_and_update(calls, fn n -> {n, n + 1} end)

      if attempt < 2 do
        {:error, http_error(429, "rate_limit_error: too many requests")}
      else
        {:ok, assistant_tool_call("tc-1", "attack", %{"target" => "goblin"})}
      end
    end

    assert {:ok, decision} =
             ToolLoopDecider.decide(
               Context.new(system_prompt: "Pick actions via tools only"),
               [action_tool("attack")],
               model: fake_model(),
               complete_fn: complete_fn,
               transient_backoff: fn _retry -> :ok end
             )

    assert decision["type"] == "tool_call"
    assert decision["tool_name"] == "attack"
    assert Agent.get(calls, & &1) == 3
  end

  test "retries plain transport-error atoms (:timeout, :closed, :econnreset)" do
    for reason <- [:timeout, :closed, :econnreset] do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      complete_fn = fn _model, _ctx, _stream_opts ->
        attempt = Agent.get_and_update(calls, fn n -> {n, n + 1} end)

        if attempt == 0 do
          {:error, reason}
        else
          {:ok, assistant_tool_call("tc-1", "attack", %{"target" => "goblin"})}
        end
      end

      assert {:ok, _decision} =
               ToolLoopDecider.decide(
                 Context.new(system_prompt: "Pick one action"),
                 [action_tool("attack")],
                 model: fake_model(),
                 complete_fn: complete_fn,
                 transient_backoff: fn _retry -> :ok end
               ),
             "expected reason #{inspect(reason)} to be retried"

      assert Agent.get(calls, & &1) == 2
    end
  end

  test "gives up after exhausting the configured transient retry budget" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _ctx, _stream_opts ->
      Agent.update(calls, &(&1 + 1))
      {:error, http_error(503, "overloaded_error: overloaded")}
    end

    assert {:error, %AssistantMessage{error_message: message}} =
             ToolLoopDecider.decide(
               Context.new(system_prompt: "Pick one action"),
               [action_tool("attack")],
               model: fake_model(),
               complete_fn: complete_fn,
               transient_retries: 2,
               transient_backoff: fn _retry -> :ok end
             )

    assert message =~ "503"
    # initial attempt + 2 retries = 3 total calls
    assert Agent.get(calls, & &1) == 3
  end

  test "propagates a non-retryable auth error immediately without retrying" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _ctx, _stream_opts ->
      Agent.update(calls, &(&1 + 1))
      {:error, http_error(401, "authentication_error: invalid x-api-key")}
    end

    assert {:error, %AssistantMessage{error_message: message}} =
             ToolLoopDecider.decide(
               Context.new(system_prompt: "Pick one action"),
               [action_tool("attack")],
               model: fake_model(),
               complete_fn: complete_fn,
               transient_backoff: fn _retry -> flunk("must not back off for auth errors") end
             )

    assert message =~ "401"
    assert Agent.get(calls, & &1) == 1
  end

  test "propagates a non-retryable bad-request error immediately without retrying" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _ctx, _stream_opts ->
      Agent.update(calls, &(&1 + 1))
      {:error, http_error(400, "invalid_request_error: missing field")}
    end

    assert {:error, %AssistantMessage{}} =
             ToolLoopDecider.decide(
               Context.new(system_prompt: "Pick one action"),
               [action_tool("attack")],
               model: fake_model(),
               complete_fn: complete_fn,
               transient_backoff: fn _retry ->
                 flunk("must not back off for 4xx client errors")
               end
             )

    assert Agent.get(calls, & &1) == 1
  end

  defp http_error(status, provider_message) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      stop_reason: :error,
      error_message: "HTTP #{status}: #{provider_message}",
      timestamp: System.system_time(:millisecond)
    }
  end

  defp assistant_tool_call(id, name, args) do
    %AssistantMessage{
      role: :assistant,
      content: [%ToolCall{type: :tool_call, id: id, name: name, arguments: args}],
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp action_tool(name) do
    %LemonAgent.Types.AgentTool{
      name: name,
      description: "#{name} action",
      parameters: %{"type" => "object", "properties" => %{}},
      label: name,
      execute: fn _id, _params, _signal, _on_update ->
        {:ok,
         %AgentToolResult{
           content: [LemonAgent.text_content("#{name} committed")],
           details: %{ok: true, event: %{"kind" => "#{name}_committed"}},
           trust: :trusted
         }}
      end
    }
  end
end
