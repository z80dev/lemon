defmodule LemonAgent.ModelRuntime.ProviderFailoverTest do
  # A lemon_agent-only consumer: failover comes from `AgentLoopConfig`, driven
  # by a `%LemonCore.Config{}`, with no coding_agent settings or session.
  use ExUnit.Case, async: false

  alias LemonAgent.EventStream
  alias LemonAgent.Loop.Streaming
  alias LemonAgent.ModelRuntime.{CredentialHealth, ProviderFailover, SessionPins}
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.{AssistantMessage, StreamOptions, TextContent, Usage, UserMessage}

  @pool_envs ~w(LEMON_FAILOVER_TEST_OPENAI_POOL LEMON_FAILOVER_TEST_AZURE_POOL)

  setup do
    previous = Map.new(@pool_envs, &{&1, System.get_env(&1)})
    System.put_env("LEMON_FAILOVER_TEST_OPENAI_POOL", "openai-pool-key")
    System.put_env("LEMON_FAILOVER_TEST_AZURE_POOL", "azure-pool-key")
    CredentialHealth.reset()

    on_exit(fn ->
      CredentialHealth.reset()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  # Two providers, each with a pool credential and an inline default key.
  defp config(routing \\ %{}) do
    %LemonCore.Config{
      agent: %{
        provider_routing:
          Map.merge(
            %{
              enabled: true,
              fallback_providers: ["azure_openai_responses"],
              require_credentials: true,
              default_pool: "p",
              credential_pools: %{
                "p" => %{
                  credentials: %{
                    "openai" => ["env:LEMON_FAILOVER_TEST_OPENAI_POOL"],
                    "azure_openai_responses" => ["env:LEMON_FAILOVER_TEST_AZURE_POOL"]
                  }
                }
              }
            },
            routing
          )
      },
      providers: %{
        "openai" => %{api_key: "openai-default"},
        "azure_openai_responses" => %{api_key: "azure-default"}
      },
      model_roles: %{}
    }
  end

  defp loop_config(stream_fn, opts) do
    %AgentLoopConfig{
      model: LemonAi.Models.get_model(:openai, "gpt-4"),
      convert_to_llm: & &1,
      max_retries: Keyword.get(opts, :max_retries, 2),
      retry_base_delay_ms: 1,
      check_model_cost: Keyword.get(opts, :check_model_cost),
      stream_options: %StreamOptions{
        provider_retry: %{jitter_fun: & &1, sleep_fun: fn _ -> :ok end}
      },
      stream_fn: stream_fn,
      provider_failover:
        ProviderFailover.new(Keyword.get(opts, :config, config()),
          session_id: Keyword.get(opts, :session_id)
        )
    }
  end

  defp respond(config) do
    context =
      AgentContext.new(
        system_prompt: "s",
        messages: [%UserMessage{role: :user, content: "hi", timestamp: 1}]
      )

    {:ok, stream} = EventStream.start_link(timeout: :infinity)
    result = Streaming.stream_assistant_response(context, config, nil, nil, stream)
    EventStream.complete(stream, [])
    result
  end

  defp attempts(parent, reply) do
    fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})
      reply.(model)
    end
  end

  test "2 providers x 2 credentials with max_retries 2 make at most four upstream attempts" do
    # Measured before the move on 065d3614e: the loop's three tries each walked
    # all four provider x credential candidates, 12 upstream attempts.
    parent = self()
    rate_limited = &{:ok, error_stream(&1, "Rate limit reached for requests (HTTP 429)")}

    assert {:ok, %{stop_reason: :error}, _} =
             respond(loop_config(attempts(parent, rate_limited), max_retries: 2))

    attempts = collect_attempts()
    assert length(attempts) <= 4
    assert length(attempts) == 3

    assert attempts == [
             {:openai, "openai-pool-key"},
             {:openai, "openai-default"},
             {:azure_openai_responses, "azure-pool-key"}
           ]
  end

  test "a lemon_agent-only consumer fails over from AgentLoopConfig and pins the winner" do
    parent = self()
    session = "failover-#{System.unique_integer([:positive])}"

    reply = fn model ->
      case model.provider do
        :openai -> {:ok, error_stream(model, "Service temporarily unavailable (HTTP 503)")}
        :azure_openai_responses -> {:ok, success_stream(model, "fallback answer")}
      end
    end

    assert {:ok, message, _} =
             respond(loop_config(attempts(parent, reply), session_id: session))

    assert message.provider == :azure_openai_responses
    assert [%TextContent{text: "fallback answer"}] = message.content
    assert [{:openai, "openai-pool-key"}, {:azure_openai_responses, _}] = collect_attempts()
    assert %{provider: "azure_openai_responses"} = SessionPins.get(session)
    on_exit(fn -> SessionPins.clear(session) end)
  end

  test "the cost check runs for each failover candidate and skips a capped one" do
    parent = self()

    check = fn model, _context, _options ->
      send(parent, {:cost_checked, model.provider})

      if model.provider == :azure_openai_responses,
        do: {:error, :model_routing_cost_cap},
        else: :ok
    end

    reply = &{:ok, error_stream(&1, "Service temporarily unavailable (HTTP 503)")}

    assert {:ok, %{stop_reason: :error}, _} =
             respond(
               loop_config(attempts(parent, reply),
                 max_retries: 1,
                 check_model_cost: check,
                 config: config(%{credential_pools: %{}, default_pool: nil})
               )
             )

    assert_received {:cost_checked, :openai}
    assert_received {:cost_checked, :azure_openai_responses}
    # The capped fallback never reached the provider.
    assert [_ | _] = attempts = collect_attempts()
    assert Enum.all?(attempts, &match?({:openai, "openai-default"}, &1))
  end

  defp collect_attempts(acc \\ []) do
    receive do
      {:attempt, provider, key} -> collect_attempts([{provider, key} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp success_stream(model, text) do
    message = message(model, :stop, text, nil)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, %{message | content: []}})
      LemonAi.EventStream.push(stream, {:text_start, 0})
      LemonAi.EventStream.push(stream, {:text_delta, 0, text})
      LemonAi.EventStream.push(stream, {:text_end, 0, text})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end

  defp error_stream(model, error) do
    message = message(model, :error, "", error)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, %{message | content: []}})
      LemonAi.EventStream.error(stream, message)
    end)

    stream
  end

  defp message(model, stop_reason, text, error) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{},
      stop_reason: stop_reason,
      error_message: error,
      timestamp: System.system_time(:millisecond)
    }
  end
end
