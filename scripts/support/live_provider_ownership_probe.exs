defmodule LemonScripts.LiveProviderOwnershipProbe do
  @moduledoc false
  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias LemonAgent.ModelRuntime.{CredentialHealth, Credentials, CustomProviders, StreamOptions}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{Model, TextContent}

  @env ~w(HOME LEMON_AGENT_DIR LEMON_STORE_PATH LEMON_SECRETS_MASTER_KEY
    LEMON_FEATURE_SESSION_SEARCH OPENAI_API_KEY ANTHROPIC_API_KEY XAI_API_KEY
    GROQ_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY OPENAI_CODEX_API_KEY
    CHATGPT_TOKEN AZURE_OPENAI_API_KEY LIVE_OWNER_POOL)
  @private ~w(fixture-owner-a-pool fixture-owner-a-default fixture-owner-b-key
    fixture-owner-b-header fixture-owner-ambient fixture-owner-oauth-access
    fixture-owner-private-refresh)
  @startup_provider "live-provider-ownership-startup"
  @failure_provider "live-provider-ownership-failure"

  def log(event, %{config: %{owner: owner, ref: ref}}),
    do: send(owner, {ref, :log, event})

  def sandbox(root, fun) do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    paths = Application.fetch_env(:lemon_core, :paths)
    retry = Application.fetch_env(:lemon_ai, :provider_retry)
    File.mkdir_p!(root)
    Enum.each(@env, &System.delete_env/1)
    System.put_env("HOME", root)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    System.put_env("LEMON_STORE_PATH", Path.join(root, "store"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "off")
    Application.put_env(:lemon_core, :paths, home_dir: root)
    Application.put_env(:lemon_ai, :provider_retry, max_attempts: 1)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore_env(:lemon_core, :paths, paths)
      restore_env(:lemon_ai, :provider_retry, retry)
    end
  end

  def run(root, scenario) do
    ref = make_ref()
    owner = self()
    cwd = Path.join(root, Atom.to_string(scenario))
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    File.write!(Path.join(cwd, ".lemon/config.toml"), "[features]\nsession_search = \"off\"\n")
    System.put_env("ANTHROPIC_API_KEY", "fixture-owner-ambient")
    System.put_env("LIVE_OWNER_POOL", "fixture-owner-a-pool")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    url = "http://127.0.0.1:#{port}/v1"
    server = spawn(fn -> serve(listener, owner, ref, scenario, 0) end)
    handler = :live_provider_ownership_probe

    try do
      :ok =
        :logger.add_handler(handler, __MODULE__, %{level: :all, config: %{owner: owner, ref: ref}})

      {events, journal_ok} =
        case scenario do
          :live_fallback -> live_fallback(cwd, url)
          :same_provider_headers -> same_provider_headers(cwd, url)
          _ -> idle_switch(cwd, url, scenario)
        end

      :logger.remove_handler(handler)
      records = drain(ref, [])
      wires = for {:wire, request} <- records, do: request

      logs =
        for {:log, event} <- records,
            do: inspect(event, limit: :infinity, printable_limit: :infinity)

      # Tool-schema snapshots can exhaust Inspect's default limit before the
      # terminal refusal or a private value. Probe predicates must scan it all.
      event_text = inspect(events, limit: :infinity, printable_limit: :infinity)
      answered = answered?(events)
      refused = Enum.any?(events, &refusal?/1)
      completed = Enum.any?(events, &match?({:agent_end, _}, &1))

      credential_refusal =
        String.contains?(event_text, "A resolved credential is required for provider")

      leaked = Enum.any?(logs ++ [event_text], &String.contains?(&1, @private))
      a = Enum.filter(wires, &(&1.model == "gemma2-9b-it"))
      b = Enum.filter(wires, &(&1.model == "grok-3"))
      destination = Enum.filter(wires, &(&1.model == "fixture-keyless"))

      selected =
        Enum.filter(wires, &(&1.model in ["fixture-selected", "claude-sonnet-4-20250514"]))

      foreign_on_a = Enum.any?(a, &String.contains?(&1.headers, "fixture-owner-b"))
      pool_on_a = Enum.all?(a, &String.contains?(&1.headers, "Bearer fixture-owner-a-pool\r\n"))
      b_header = Enum.all?(b, &String.contains?(&1.headers, "Bearer fixture-owner-b-header\r\n"))

      same_header =
        case a do
          [bare_a, bare_b, caller_a, caller_b] ->
            Enum.all?([bare_a, bare_b], &(not String.contains?(&1.headers, "x-explicit-owner:"))) and
              Enum.all?(
                [caller_a, caller_b],
                &String.contains?(&1.headers, "x-explicit-owner: retained\r\n")
              )

          _ ->
            false
        end

      derived_headers_correct =
        case a do
          [bare_a, bare_b, caller_a, caller_b] ->
            Enum.all?(
              Enum.zip(
                [bare_a, bare_b, caller_a, caller_b],
                [
                  {"tenant-a", "model-a"},
                  {"tenant-b", "model-b"},
                  {"tenant-a", "genuine-caller"},
                  {"tenant-b", "genuine-caller"}
                ]
              ),
              fn {request, {tenant, overlay}} ->
                String.contains?(request.headers, "x-tenant: #{tenant}\r\n") and
                  String.contains?(request.headers, "x-caller-overlay: #{overlay}\r\n") and
                  String.contains?(request.headers, "x-client: provider-default\r\n")
              end
            )

          _ ->
            false
        end

      keyless =
        Enum.all?(
          destination,
          &(not String.contains?(String.downcase(&1.headers), "authorization:"))
        )

      passed =
        case scenario do
          s when s in [:idle_missing, :agent_missing, :plan_missing] ->
            length(a) == 1 and selected == [] and credential_refusal and not answered and
              journal_ok

          s when s in [:idle_keyless, :agent_keyless] ->
            length(selected) == 1 and length(destination) == 1 and completed and answered and
              not refused and keyless and journal_ok

          :live_fallback ->
            Enum.map(wires, & &1.model) == ["gemma2-9b-it", "grok-3", "gemma2-9b-it"] and
              completed and answered and not refused and not foreign_on_a and pool_on_a and
              b_header and journal_ok

          :same_provider_headers ->
            length(a) == 4 and completed and answered and not refused and same_header and
              derived_headers_correct and journal_ok
        end

      %{
        scenario: scenario,
        passed: passed and not leaked,
        requests: length(wires),
        a_requests: length(a),
        b_requests: length(b),
        selected_requests: length(selected),
        keyless_requests: length(destination),
        answered: answered,
        refused: refused,
        completed: completed,
        credential_refusal: credential_refusal,
        foreign_header_on_a: foreign_on_a,
        a_pool_selected: pool_on_a,
        b_explicit_header_preserved: b_header,
        same_provider_header_preserved: same_header,
        derived_headers_rebound_correctly: derived_headers_correct,
        keyless_without_authorization: keyless,
        journal_matches_selection: journal_ok,
        private_values_in_logs_or_events: leaked
      }
    after
      case :logger.get_handler_config(handler) do
        {:ok, %{module: __MODULE__, config: %{ref: ^ref}}} ->
          :logger.remove_handler(handler)

        _ ->
          :ok
      end

      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end
  end

  defp idle_switch(cwd, url, scenario) do
    reverse = scenario in [:idle_keyless, :agent_keyless]
    direct = scenario in [:agent_missing, :agent_keyless]
    secret = "live_owner_#{System.unique_integer([:positive])}"

    selected_id =
      if scenario == :plan_missing, do: "claude-sonnet-4-20250514", else: "fixture-selected"

    selected = model(:anthropic, selected_id, :anthropic_messages, url)
    ordinary = model(:groq, "gemma2-9b-it", :openai_completions, url)

    keyless = %{
      model("local-keyless", "fixture-keyless", :openai_completions, url)
      | compat: %{allow_missing_api_key: true}
    }

    providers = %{
      "groq" => %{api_key: "fixture-owner-a-default", base_url: url},
      "anthropic" => %{auth_source: "oauth", api_key_secret: secret, base_url: url},
      "local-keyless" => %{api: "openai_completions", auth: "none", base_url: url}
    }

    settings = settings(providers, %{enabled: false})

    settings =
      if scenario == :plan_missing,
        do: %{settings | model_roles: %{"plan" => "anthropic:#{selected_id}"}},
        else: settings

    {initial, destination} = if reverse, do: {selected, keyless}, else: {ordinary, selected}

    if reverse do
      {:ok, _} =
        LemonCore.Secrets.set(
          secret,
          Jason.encode!(%{
            "type" => "anthropic_oauth",
            "access_token" => "fixture-owner-oauth-access",
            "refresh_token" => "fixture-owner-private-refresh",
            "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
          })
        )
    end

    try do
      if direct do
        resolver = fn next, previous, options ->
          options =
            if next.provider == previous.provider,
              do: options,
              else: StreamOptions.sanitize_for_provider_switch(options)

          StreamOptions.build_stream_options(next, providers, options, cwd)
        end

        {:ok, agent} =
          LemonAgent.Agent.start_link(
            initial_state: %{model: initial, tools: []},
            stream_options: StreamOptions.build_stream_options(initial, providers, nil, cwd),
            get_api_key: Credentials.build_get_api_key(providers),
            resolve_stream_options: resolver,
            max_retries: 0
          )

        try do
          unsubscribe = LemonAgent.Agent.subscribe(agent, self())
          :ok = LemonAgent.Agent.prompt(agent, "First completed prompt.")
          first = await(:agent, [])
          idle!(:agent, agent)
          initial_answer!(first)
          :ok = LemonAgent.Agent.set_model(agent, destination)
          :ok = LemonAgent.Agent.prompt(agent, "Second prompt after idle switch.")
          events = await(:agent, [])
          idle!(:agent, agent)
          unsubscribe.()
          {events, LemonAgent.Agent.get_state(agent).model == destination}
        after
          GenServer.stop(agent)
        end
      else
        with_session(cwd, initial, settings, [], fn session ->
          :ok = Session.prompt(session, "First completed prompt.")
          first = await(:session, [])
          idle!(:session, session)
          initial_answer!(first)

          if scenario == :plan_missing do
            {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
          else
            :ok = Session.switch_model(session, destination)
          end

          :ok = Session.prompt(session, "Second prompt after idle switch.")
          events = await(:session, [])
          idle!(:session, session)
          {events, selection_recorded?(session, destination)}
        end)
      end
    after
      if reverse, do: LemonCore.Secrets.delete(secret)
    end
  end

  defp live_fallback(cwd, url) do
    # Both endpoints belong to the fixture: real provider health and rate
    # buckets must neither influence nor be consumed by repeated loopback runs.

    providers = %{
      @startup_provider => %{
        api: "openai_completions",
        api_key: "fixture-owner-a-default",
        base_url: url,
        headers: %{"x-provider-owner" => "a"}
      },
      @failure_provider => %{
        api: "openai_completions",
        api_key: "fixture-owner-b-key",
        base_url: url,
        headers: %{"Authorization" => "Bearer fixture-owner-b-header", "x-provider-owner" => "b"}
      }
    }

    a = CustomProviders.lookup(providers, @startup_provider, "gemma2-9b-it")
    b = CustomProviders.lookup(providers, @failure_provider, "grok-3")

    children =
      for provider <- [@startup_provider, @failure_provider],
          module <- [LemonAi.CircuitBreaker, LemonAi.RateLimiter] do
        Supervisor.child_spec({module, provider: provider}, id: {module, provider})
      end

    {:ok, health} = Supervisor.start_link(children, strategy: :one_for_one)

    [{breaker, _}] = Registry.lookup(LemonAi.CircuitBreakerRegistry, @failure_provider)

    routing = %{
      enabled: true,
      fallback_models: ["#{@startup_provider}:gemma2-9b-it"],
      fallback_providers: [],
      require_credentials: true,
      default_pool: "owner",
      credential_pools: %{
        "owner" => %{
          providers: [@startup_provider],
          strategy: "priority",
          credentials: %{@startup_provider => ["env:LIVE_OWNER_POOL"]}
        }
      }
    }

    {:ok, holder} = Agent.start_link(fn -> nil end)

    tool = %AgentTool{
      name: "switch_owner",
      description: "Switch fixture model",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ ->
        :ok = Session.switch_model(Agent.get(holder, & &1), b)
        %AgentToolResult{content: [%TextContent{text: "Switched fixture model."}]}
      end
    }

    try do
      with_session(cwd, a, settings(providers, routing), [tool], fn session ->
        Agent.update(holder, fn _ -> session end)
        :ok = Session.prompt(session, "Use the fixture switch tool, then answer.")
        events = await(:session, [])
        idle!(:session, session)
        {events, selection_recorded?(session, b)}
      end)
    after
      try do
        Agent.stop(holder)
        settle_provider_work!(breaker, System.monotonic_time(:millisecond) + 5_000)
      after
        Supervisor.stop(health)
        CredentialHealth.record_success(@failure_provider, "default")
        CredentialHealth.record_success(@startup_provider, "env:LIVE_OWNER_POOL")
      end
    end
  end

  defp settle_provider_work!(breaker, deadline) do
    {:ok, state} = GenServer.call(breaker, :get_state)

    # Owner DOWN can release a slot before terminal tracking commits health.
    # This private sandbox's model tasks must all end before their health
    # supervisor stops, including successful startup-provider callbacks.
    if state.failure_count == 1 and
         Task.Supervisor.children(LemonAi.StreamTaskSupervisor) == [] and
         LemonAi.CallDispatcher.get_active_requests(@startup_provider) == 0 and
         LemonAi.CallDispatcher.get_active_requests(@failure_provider) == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "fixture provider terminal accounting did not settle"
      else
        Process.sleep(10)
        settle_provider_work!(breaker, deadline)
      end
    end
  end

  defp same_provider_headers(cwd, url) do
    a = %{
      model(:groq, "gemma2-9b-it", :openai_completions, url)
      | headers: %{"x-tenant" => "tenant-a", "x-caller-overlay" => "model-a"}
    }

    providers = %{
      "groq" => %{
        api_key: "fixture-owner-a-default",
        base_url: url,
        headers: %{"x-client" => "provider-default"}
      }
    }

    {events, journals} =
      for caller_options <- [
            nil,
            %{
              headers: %{"x-explicit-owner" => "retained", "x-caller-overlay" => "genuine-caller"}
            }
          ] do
        with_session(
          cwd,
          a,
          settings(providers, %{enabled: true}),
          [],
          fn session ->
            :ok = Session.prompt(session, "First completed prompt.")
            first = await(:session, [])
            idle!(:session, session)
            initial_answer!(first)

            :ok =
              Session.switch_model(session, %{
                a
                | name: "Same provider new binding",
                  headers: %{"x-tenant" => "tenant-b", "x-caller-overlay" => "model-b"}
              })

            :ok = Session.prompt(session, "Second completed prompt.")
            events = await(:session, [])
            idle!(:session, session)
            {events, selection_recorded?(session, a)}
          end,
          stream_options: caller_options
        )
      end
      |> Enum.unzip()

    {List.flatten(events), Enum.all?(journals)}
  end

  defp with_session(cwd, model, settings, tools, fun, extra \\ []) do
    {:ok, session} =
      Session.start_link(
        [
          cwd: cwd,
          workspace_dir: Path.join(cwd, "workspace"),
          settings_manager: settings,
          model: model,
          system_prompt: "Fixture only.",
          tools: tools,
          thinking_level: :off
        ] ++ extra
      )

    try do
      unsubscribe = Session.subscribe(session)
      result = fun.(session)
      unsubscribe.()
      result
    after
      GenServer.stop(session)
    end
  end

  defp selection_recorded?(session, model) do
    :ok = Session.save(session)
    state = Session.get_state(session)
    {:ok, persisted} = SessionManager.load_from_file(state.session_file)

    last =
      persisted
      |> SessionManager.get_branch()
      |> Enum.filter(&(&1.type == :model_change))
      |> List.last()

    state.model.provider == model.provider and state.model.id == model.id and
      last != nil and to_string(last.provider) == to_string(model.provider) and
      last.model_id == model.id
  end

  defp settings(providers, routing),
    do: %SettingsManager{
      providers: providers,
      provider_routing: routing,
      default_thinking_level: :off,
      compaction_enabled: false,
      retry_enabled: false
    }

  defp model(provider, id, api, url),
    do: %Model{
      provider: provider,
      id: id,
      name: id,
      api: api,
      base_url: url,
      context_window: 8192,
      max_tokens: 128
    }

  defp await(kind, events) do
    receive do
      {:session_event, _, event} when kind == :session -> next(kind, event, events)
      {:agent_event, event} when kind == :agent -> next(kind, event, events)
    after
      15_000 -> raise "public lifecycle fixture did not terminate"
    end
  end

  defp next(_kind, {:agent_end, _} = event, events), do: Enum.reverse([event | events])
  defp next(_kind, {:error, _, _} = event, events), do: Enum.reverse([event | events])
  defp next(_kind, {:canceled, _} = event, events), do: Enum.reverse([event | events])
  defp next(kind, event, events), do: await(kind, [event | events])

  defp answered?(events),
    do:
      Enum.any?(events, fn
        {:message_end, %{role: :assistant, content: content}} when is_list(content) ->
          Enum.any?(content, &match?(%TextContent{text: "Ownership endpoint answered."}, &1))

        _ ->
          false
      end)

  defp refusal?({:error, _, _}), do: true
  defp refusal?({:message_end, %{stop_reason: :error}}), do: true
  defp refusal?(_), do: false

  defp idle!(kind, process) do
    agent = if kind == :session, do: Session.get_state(process).agent, else: process
    :ok = LemonAgent.Agent.wait_for_idle(agent, 10_000)
    false = LemonAgent.Agent.get_state(agent).is_streaming
    if kind == :session, do: false = Session.get_state(process).is_streaming
    :ok
  end

  defp initial_answer!(events) do
    unless answered?(events) and Enum.any?(events, &match?({:agent_end, _}, &1)) and
             not Enum.any?(events, &refusal?/1),
           do: raise("initial public fixture prompt did not complete with the expected content")
  end

  defp drain(ref, records) do
    receive do
      {^ref, :wire, request} -> drain(ref, [{:wire, request} | records])
      {^ref, :log, event} -> drain(ref, [{:log, event} | records])
    after
      0 -> Enum.reverse(records)
    end
  end

  defp serve(listener, owner, ref, scenario, count) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, body} = receive_headers(socket, "")
        [_, length] = Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers)
        body = receive_body(socket, body, String.to_integer(length))
        %{"model" => id} = Jason.decode!(body)
        send(owner, {ref, :wire, %{model: id, headers: headers <> "\r\n"}})
        {status, type, response} = response(scenario, count, id)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 ",
            status,
            "\r\ncontent-type: ",
            type,
            "\r\ncontent-length: ",
            Integer.to_string(byte_size(response)),
            "\r\nconnection: close\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve(listener, owner, ref, scenario, count + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp response(:live_fallback, 0, "gemma2-9b-it") do
    data = %{
      "id" => "fixture",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "switch-fixture",
                "type" => "function",
                "function" => %{"name" => "switch_owner", "arguments" => "{}"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    {"200 OK", "text/event-stream", "data: #{Jason.encode!(data)}\n\ndata: [DONE]\n\n"}
  end

  defp response(:live_fallback, _, "grok-3"),
    do:
      {"503 Service Unavailable", "application/json",
       Jason.encode!(%{"error" => %{"type" => "overloaded_error", "message" => "overloaded"}})}

  defp response(_, _, id) when id in ["fixture-selected", "claude-sonnet-4-20250514"] do
    events = [
      {"message_start",
       %{
         "type" => "message_start",
         "message" => %{
           "id" => "fixture",
           "type" => "message",
           "role" => "assistant",
           "content" => [],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
         }
       }},
      {"content_block_start",
       %{
         "type" => "content_block_start",
         "index" => 0,
         "content_block" => %{"type" => "text", "text" => ""}
       }},
      {"content_block_delta",
       %{
         "type" => "content_block_delta",
         "index" => 0,
         "delta" => %{"type" => "text_delta", "text" => "Ownership endpoint answered."}
       }},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
      {"message_delta",
       %{
         "type" => "message_delta",
         "delta" => %{"stop_reason" => "end_turn"},
         "usage" => %{"output_tokens" => 1}
       }},
      {"message_stop", %{"type" => "message_stop"}}
    ]

    body =
      Enum.map_join(events, fn {event, data} ->
        "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
      end)

    {"200 OK", "text/event-stream", body}
  end

  defp response(_, _, _) do
    data = %{
      "id" => "fixture",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"role" => "assistant", "content" => "Ownership endpoint answered."},
          "finish_reason" => "stop"
        }
      ]
    }

    {"200 OK", "text/event-stream", "data: #{Jason.encode!(data)}\n\ndata: [DONE]\n\n"}
  end

  defp receive_headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, buffer <> bytes)
    end
  end

  defp receive_body(_socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp receive_body(socket, body, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    receive_body(socket, body <> bytes, length)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
