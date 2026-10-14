defmodule CodingAgent.Session.ProviderFallbackResilienceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ProviderFallback
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.{CredentialHealth, SessionPins}
  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, TextContent, ThinkingContent, ToolCall, Usage}

  test "pre-commit event buffering is bounded and does not replay overflow" do
    parent = self()
    primary = primary()
    stream_fn = fn model, _, _ ->
      send(parent, {:attempt, model.id})
      empty = message(model, :stop, [])
      events = List.duplicate({:start, empty}, 257)
      {:ok, event_stream(events, empty)}
    end
    wrapped = wrap(stream_fn, primary, model_settings())
    assert {:error, %{error_message: "provider_event_buffer_overflow"}} = result(wrapped, primary)
    assert_receive {:attempt, "gpt-4"}
    refute_receive {:attempt, _}
  end

  test "request-level cancellation is terminal even when its reason is timeout" do
    parent = self()
    primary = primary()
    stream_fn = fn model, _, _ ->
      send(parent, {:attempt, model.id})
      {:error, {:canceled, :timeout}}
    end
    wrapped = wrap(stream_fn, primary, model_settings())
    {:ok, output} = wrapped.(primary, %Context{}, %StreamOptions{})
    assert Enum.to_list(LemonAi.EventStream.events(output)) == [{:canceled, :timeout}]
    assert_receive {:attempt, "gpt-4"}
    refute_receive {:attempt, _}
  end

  test "stream cooldown timing preserves an explicit hint when nested metadata has none" do
    primary = primary()
    stream_fn = fn model, _, options ->
      if options.api_key == "fake-key-a" do
        error = %{error_message(model, 429, "rate limited") | retry_after_ms: 234_567}
        {:ok, event_stream([], error)}
      else
        {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
      end
    end
    before = System.monotonic_time(:millisecond)
    wrapped = wrap(stream_fn, primary, settings())
    assert {:ok, _} = result(wrapped, primary)
    after_attempt = System.monotonic_time(:millisecond)
    deadline = CredentialHealth.cooldown_until(:openai, "env:PF_RESILIENCE_A")
    assert deadline >= before + 234_567
    assert deadline <= after_attempt + 234_567
  end

  test "Azure credential rotation overrides rebuilt keys and provider options" do
    parent = self()
    settings = settings()
    routing = %{settings.provider_routing | fallback_models: [], credential_pools: %{
      "test" => %{providers: ["azure_openai_responses"], strategy: "priority",
        credentials: %{"azure_openai_responses" => ["env:PF_RESILIENCE_A", "env:PF_RESILIENCE_B"]}}
    }}
    settings = %{settings | provider_routing: routing}
    primary = CodingAgent.Session.ModelResolver.resolve_session_model("azure_openai_responses:gpt-4", settings)
    stream_fn = fn model, _, options ->
      send(parent, {:azure_key, options.api_key, options.provider_options.azure_openai_responses.api_key})
      if options.api_key == "fake-key-a",
        do: failure(model, 429, "usage limit reached", :stream),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
    end
    wrapped = wrap(stream_fn, primary, settings)
    assert {:ok, _} = result(wrapped, primary)
    assert_receive {:azure_key, "fake-key-a", "fake-key-a"}
    assert_receive {:azure_key, "fake-key-b", "fake-key-b"}
  end

  test "a per-call provider switch rebuilds options even without fallbacks" do
    parent = self()
    original = primary()
    settings = model_settings()
    settings = %{settings | provider_routing: %{settings.provider_routing | fallback_models: []}}
    switched = CodingAgent.Session.ModelResolver.resolve_session_model("azure_openai_responses:gpt-4o", settings)
    stream_fn = fn model, _, options ->
      send(parent, {:switched_options, options})
      {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
    end
    wrapped = wrap(stream_fn, original, settings)
    {:ok, stream} = wrapped.(switched, %Context{}, %StreamOptions{
      api_key: "old-provider-key", access_token: "old-token", headers: %{"authorization" => "old-token"},
      provider_options: %{openai: %{api_key: "old-provider-key"}}, max_tokens: 123
    })
    assert {:ok, %{provider: :azure_openai_responses}} = LemonAi.EventStream.result(stream, 1_000)
    assert_receive {:switched_options, options}
    assert options.api_key == "destination-key"
    assert options.access_token == nil
    assert options.headers == %{}
    refute Map.has_key?(options.provider_options, :openai)
    assert options.max_tokens == 123
  end

  setup do
    CredentialHealth.reset()
    SessionPins.reset()
    System.put_env("PF_RESILIENCE_A", "fake-key-a")
    System.put_env("PF_RESILIENCE_B", "fake-key-b")

    on_exit(fn ->
      CredentialHealth.reset()
      SessionPins.reset()
      System.delete_env("PF_RESILIENCE_A")
      System.delete_env("PF_RESILIENCE_B")
    end)

    :ok
  end

  for mode <- [:request, :stream] do
    test "#{mode} 401 refreshes the same credential once before rotating" do
      mode = unquote(mode)
      parent = self()
      primary = primary()
      settings = settings()
      refresh = fn config, provider, ref, previous ->
        assert config == settings
        send(parent, {:refresh, provider, ref, previous})
        {:ok, "fake-fresh-a"}
      end

      stream_fn = fn model, _, options ->
        send(parent, {:attempt, model.provider, model.id, options.api_key})
        if options.api_key in ["fake-key-a", "fake-fresh-a"] do
          failure(model, 401, "Unauthorized", mode)
        else
          {:ok, terminal_stream(model, :stop, [%TextContent{text: "rotated"}])}
        end
      end

      wrapped = wrap(stream_fn, primary, settings, refresh_api_key: refresh)
      assert {:ok, _} = result(wrapped, primary)
      assert_receive {:attempt, :openai, "gpt-4", "fake-key-a"}
      assert_receive {:refresh, :openai, "env:PF_RESILIENCE_A", "fake-key-a"}
      assert_receive {:attempt, :openai, "gpt-4", "fake-fresh-a"}
      assert_receive {:attempt, :openai, "gpt-4", "fake-key-b"}
      refute_receive {:refresh, _, _, _}
      assert CredentialHealth.in_cooldown?(:openai, "env:PF_RESILIENCE_A")
    end

    test "#{mode} failed refresh rotates; 403 and usage never refresh" do
      mode = unquote(mode)
      for status <- [401, 403, 429] do
        CredentialHealth.reset()
        parent = self()
        primary = primary()
        refresh = fn _, provider, ref, key ->
          send(parent, {:refresh, status, provider, ref, key})
          {:error, :reauth_required}
        end
        stream_fn = fn model, _, options ->
          send(parent, {:attempt, status, options.api_key})
          if options.api_key == "fake-key-a" do
            failure(model, status, if(status == 429, do: "usage limit reached", else: "Unauthorized"), mode)
          else
            {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
          end
        end

        wrapped = wrap(stream_fn, primary, settings(), refresh_api_key: refresh)
        assert {:ok, _} = result(wrapped, primary)
        assert_receive {:attempt, ^status, "fake-key-a"}
        assert_receive {:attempt, ^status, "fake-key-b"}
        if status == 401 do
          assert_receive {:refresh, 401, :openai, "env:PF_RESILIENCE_A", "fake-key-a"}
        else
          refute_receive {:refresh, ^status, _, _, _}
        end
      end
    end

    test "#{mode} 400 and context overflow terminally surface without walking candidates" do
      mode = unquote(mode)
      for {status, body, category} <- [
            {400, "messages must be non-empty", :client},
            {400, "maximum context length exceeded (context_length_exceeded)", :context_length}
          ] do
        parent = self()
        primary = primary()
        stream_fn = fn model, _, options ->
          send(parent, {:attempt, options.api_key})
          failure(model, status, body, mode)
        end
        wrapped = wrap(stream_fn, primary, settings())
        assert {:error, message} = result(wrapped, primary)
        assert LemonAi.Error.classify(message) == category
        assert message.provider == :openai
        assert_receive {:attempt, "fake-key-a"}
        refute_receive {:attempt, _}
        refute CredentialHealth.in_cooldown?(:openai, "env:PF_RESILIENCE_A")
      end
    end

    test "#{mode} failures honor structured retry-after cooldown hints" do
      mode = unquote(mode)
      primary = primary()
      stream_fn = fn model, _, options ->
        if options.api_key == "fake-key-a" do
          failure(model, 429, "rate limited", mode, [{"retry-after-ms", "123456"}])
        else
          {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
        end
      end
      before = System.monotonic_time(:millisecond)
      wrapped = wrap(stream_fn, primary, settings())
      assert {:ok, _} = result(wrapped, primary)
      after_attempt = System.monotonic_time(:millisecond)
      deadline = CredentialHealth.cooldown_until(:openai, "env:PF_RESILIENCE_A")
      assert deadline >= before + 123_456
      assert deadline <= after_attempt + 123_456
    end
  end

  test "a successful refresh retries without cooling down or rotating the credential" do
    parent = self()
    primary = primary()
    stream_fn = fn model, _, options ->
      send(parent, {:attempt, options.api_key})
      if options.api_key == "fake-key-a",
        do: failure(model, 401, "Unauthorized", :stream),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "refreshed"}])}
    end
    wrapped = wrap(stream_fn, primary, settings(), refresh_api_key: fn _, _, _, _ -> {:ok, "fresh"} end)
    assert {:ok, _} = result(wrapped, primary)
    assert_receive {:attempt, "fake-key-a"}
    assert_receive {:attempt, "fresh"}
    refute_receive {:attempt, "fake-key-b"}
    refute CredentialHealth.in_cooldown?(:openai, "env:PF_RESILIENCE_A")
  end

  test "refresh works with no fallback model or credential" do
    primary = primary()
    settings = %SettingsManager{providers: %{"openai" => %{api_key: "stale"}}}
    stream_fn = fn model, _, options ->
      if options.api_key == "stale",
        do: failure(model, 401, "Unauthorized", :request),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
    end
    wrapped = wrap(stream_fn, primary, settings, refresh_api_key: fn _, _, "default", "stale" -> {:ok, "fresh"} end)
    assert {:ok, _} = result(wrapped, primary)
  end

  test "same-provider models precede cross-provider models and model identity stays pinned" do
    parent = self()
    primary = primary()
    settings = model_settings()
    stream_fn = fn model, _, options ->
      send(parent, {:attempt, model.provider, model.id, options.api_key})
      if model.id == "gpt-4",
        do: failure(model, 503, "unavailable", :stream),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "same-provider"}])}
    end
    wrapped = wrap(stream_fn, primary, settings, session_id: "same-model-pin")
    assert {:ok, %{provider: :openai, model: "gpt-4o"}} = result(wrapped, primary)
    assert_receive {:attempt, :openai, "gpt-4", "primary-key"}
    assert_receive {:attempt, :openai, "gpt-4o", "primary-key"}
    assert SessionPins.get("same-model-pin") == %{provider: "openai", model_id: "gpt-4o", credential_ref: "default"}

    assert {:ok, %{model: "gpt-4o"}} = result(wrapped, primary)
    assert_receive {:attempt, :openai, "gpt-4o", "primary-key"}
    refute_receive {:attempt, _, _, _}
  end

  test "cross-provider fallback uses destination credentials and pins its distinct model" do
    parent = self()
    primary = primary()
    settings = model_settings()
    stream_fn = fn model, _, options ->
      send(parent, {:attempt, model.provider, model.id, options})
      if model.provider == :openai,
        do: failure(model, 503, "unavailable", :request),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "cross-provider"}])}
    end
    wrapped = wrap(stream_fn, primary, settings, session_id: "cross-model-pin")
    options = %StreamOptions{api_key: "caller-primary-secret", access_token: "caller-token",
      service_account_json: "caller-service-account", headers: %{"authorization" => "caller-secret"},
      thinking_budgets: %{high: 16_000, azure_base_url: "https://old-provider.invalid", azure_api_version: "old"},
      provider_options: %{openai: %{api_key: "caller-secret"}}, max_tokens: 123, stream_timeout: 456}
    {:ok, stream} = wrapped.(primary, %Context{}, options)
    assert {:ok, %{provider: :azure_openai_responses, model: "gpt-4o"}} = LemonAi.EventStream.result(stream, 1_000)
    assert_receive {:attempt, :openai, "gpt-4", _}
    assert_receive {:attempt, :openai, "gpt-4o", _}
    assert_receive {:attempt, :azure_openai_responses, "gpt-4o", destination}
    assert destination.api_key == "destination-key"
    assert destination.access_token == nil
    assert destination.service_account_json == nil
    assert destination.headers == %{}
    refute Map.has_key?(destination.provider_options, :openai)
    assert destination.max_tokens == 123
    assert destination.stream_timeout == 456
    assert destination.thinking_budgets.high == 16_000
    refute Map.get(destination.thinking_budgets, :azure_base_url) == "https://old-provider.invalid"
    refute Map.get(destination.thinking_budgets, :azure_api_version) == "old"
    assert SessionPins.get("cross-model-pin").model_id == "gpt-4o"
  end

  for gate <- [:whitespace_text, :thinking, :tool_delta, :terminal_text, :terminal_thinking, :terminal_tool] do
    test "#{gate} commits output and prevents replay" do
      gate = unquote(gate)
      parent = self()
      primary = primary()
      stream_fn = fn model, _, _ ->
        send(parent, {:attempt, model.id})
        error = error_message(model, 503, "unavailable")
        {events, content} = case gate do
          :whitespace_text -> {[{:text_delta, 0, " \n", error}], []}
          :thinking -> {[{:thinking_delta, 0, "private thinking", error}], []}
          :tool_delta -> {[{:tool_call_delta, 0, "{", error}], []}
          :terminal_text -> {[], [%TextContent{text: " "}]}
          :terminal_thinking -> {[], [%ThinkingContent{thinking: "private"}]}
          :terminal_tool -> {[], [%ToolCall{id: "call", name: "read", arguments: %{}}]}
        end
        {:ok, event_stream(events, %{error | content: content})}
      end
      wrapped = wrap(stream_fn, primary, model_settings())
      assert {:error, %{model: "gpt-4"}} = result(wrapped, primary)
      assert_receive {:attempt, "gpt-4"}
      refute_receive {:attempt, _}
    end
  end

  test "nonempty successful final content pins the model without deltas" do
    parent = self()
    primary = primary()
    SessionPins.pin("final-pin", "openai", "default", "gpt-4o")
    stream_fn = fn model, _, _ ->
      send(parent, {:attempt, model.id})
      {:ok, terminal_stream(model, :stop, [%TextContent{text: "final only"}])}
    end
    wrapped = wrap(stream_fn, primary, model_settings(), session_id: "final-pin")
    assert {:ok, %{model: "gpt-4o"}} = result(wrapped, primary)
    assert_receive {:attempt, "gpt-4o"}
    assert SessionPins.get("final-pin").model_id == "gpt-4o"
  end

  test "caller aborted error terminals never walk models or refresh" do
    parent = self()
    primary = primary()
    stream_fn = fn model, _, _ ->
      send(parent, {:attempt, model.id})
      {:ok, event_stream([], %{error_message(model, 503, "unavailable") | stop_reason: :aborted})}
    end
    wrapped = wrap(stream_fn, primary, model_settings())
    assert {:error, %{stop_reason: :aborted}} = result(wrapped, primary)
    assert_receive {:attempt, "gpt-4"}
    refute_receive {:attempt, _}
  end

  test "non-timeout provider cancellation relays unchanged, with no fallback" do
    parent = self()
    primary = primary()
    stream_fn = fn model, _, _ ->
      send(parent, {:attempt, model.id})
      {:ok, stream} = LemonAi.EventStream.start_link(owner: self())
      LemonAi.EventStream.push(stream, {:canceled, :aborted})
      {:ok, stream}
    end
    wrapped = wrap(stream_fn, primary, model_settings())
    {:ok, output} = wrapped.(primary, %Context{}, %StreamOptions{})
    assert Enum.to_list(LemonAi.EventStream.events(output)) == [{:canceled, :aborted}]
    assert_receive {:attempt, "gpt-4"}
    refute_receive {:attempt, _}
  end

  test "config fallback models pass through settings into the real session wrapper" do
    parent = self()
    agent = LemonCore.Config.Agent.resolve(%{
      "defaults" => %{"provider" => "openai", "model" => "gpt-4"},
      "runtime" => %{"provider_routing" => %{"fallback_models" => ["@smol"]}}
    })
    config = %LemonCore.Config{agent: Map.from_struct(agent), model_roles: %{"smol" => "openai:gpt-4o"},
      providers: %{"openai" => %{api_key: "fake-session-key"}}}
    settings = SettingsManager.from_config(config)
    assert settings.provider_routing.fallback_models == ["@smol"]
    stream_fn = fn model, _, _ ->
      send(parent, {:session_attempt, model.id})
      if model.id == "gpt-4",
        do: failure(model, 503, "unavailable", :stream),
        else: {:ok, terminal_stream(model, :stop, [%TextContent{text: "ok"}])}
    end
    {:ok, session} = CodingAgent.Session.start_link(cwd: System.tmp_dir!(), model: primary(),
      settings_manager: settings, stream_fn: stream_fn)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    :ok = CodingAgent.Session.prompt(session, "hello")
    assert_receive {:session_attempt, "gpt-4"}, 1_000
    assert_receive {:session_attempt, "gpt-4o"}, 1_000
    wait_idle(session, 100)
    id = CodingAgent.Session.get_state(session).session_manager.header.id
    assert %{provider: "openai", model_id: "gpt-4o"} = SessionPins.get(id)
  end

  defp primary, do: LemonAi.Models.get_model(:openai, "gpt-4")

  defp settings do
    %SettingsManager{
      providers: %{"openai" => %{api_key: "primary-key"}, "azure_openai_responses" => %{api_key: "destination-key"}},
      provider_routing: %{enabled: true, require_credentials: true,
        fallback_models: ["openai:gpt-4o", "azure_openai_responses:gpt-4o"], default_pool: "test",
        credential_pools: %{"test" => %{providers: ["openai"], strategy: "priority",
          credentials: %{"openai" => ["env:PF_RESILIENCE_A", "env:PF_RESILIENCE_B"]}}}}
    }
  end

  defp model_settings do
    settings = settings()
    %{settings | provider_routing: Map.drop(settings.provider_routing, [:default_pool, :credential_pools])}
  end

  defp wrap(stream_fn, model, settings, opts \\ []) do
    opts = Keyword.put_new(opts, :refresh_api_key, fn _, _, _, _ -> {:error, :not_refreshable} end)
    ProviderFallback.maybe_wrap(stream_fn, model, settings, File.cwd!(), opts)
  end

  defp result(wrapped, model) do
    {:ok, stream} = wrapped.(model, %Context{}, %StreamOptions{})
    LemonAi.EventStream.result(stream, 1_000)
  end

  defp failure(model, status, body, mode, headers \\ []) do
    reason = {:http_error, status, %{"error" => %{"message" => body}}, headers}
    if mode == :request, do: {:error, reason}, else: {:ok, event_stream([], error_message(model, status, body, headers))}
  end

  defp error_message(model, status, body, headers \\ []) do
    details = LemonAi.Error.parse_http_error(status, %{"error" => %{"message" => body}}, headers)
    %{message(model, :error, []) | error_message: details.message, error_details: details}
  end

  defp terminal_stream(model, reason, content), do: event_stream([], message(model, reason, content))

  defp event_stream(events, message) do
    {:ok, stream} = LemonAi.EventStream.start_link(owner: self())
    Enum.each(events, &LemonAi.EventStream.push(stream, &1))
    if message.stop_reason in [:error, :aborted],
      do: LemonAi.EventStream.error(stream, message),
      else: LemonAi.EventStream.complete(stream, message)
    stream
  end

  defp message(model, reason, content) do
    %AssistantMessage{provider: model.provider, model: model.id, api: model.api,
      content: content, stop_reason: reason, usage: %Usage{}, timestamp: System.system_time(:millisecond)}
  end

  defp wait_idle(_session, 0), do: flunk("session did not finish")
  defp wait_idle(session, attempts) do
    if CodingAgent.Session.get_state(session).is_streaming do
      Process.sleep(10)
      wait_idle(session, attempts - 1)
    end
  end
end
