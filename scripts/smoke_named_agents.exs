# On-demand offline integration smoke; invoke through smoke_named_agents.sh.
# Native inference is scripted. Sessions, gateway execution, router admission,
# queues, identity ownership and authenticated WebSocket handlers are real.
# Product REST uses the real addressed service plus a native fixture executor;
# unchanged managed-node TLS/MCP invocation proof is deliberately not claimed.
defmodule LemonNamedAgentsSmoke.Provider do
  alias LemonAi.Types.{AssistantMessage, TextContent, ToolCall, ToolResultMessage, Usage}

  def stream(model, context, _opts) do
    messages = Map.fetch!(context, :messages)
    history = Enum.map_join(messages, "\n", &text/1)
    latest = messages |> List.last() |> text()

    {step, answer} =
      cond do
        String.starts_with?(
          Map.get(context, :system_prompt) || "",
          "Extract durable repository facts"
        ) ->
          {:project_facts, "[]"}

        match?(
          %ToolResultMessage{tool_name: "agent_message", is_error: false},
          List.last(messages)
        ) ->
          require_context!(latest, "\"message_id\":\"agent-message-")
          {:alice_tool_ack, "Alice submitted the named tool request."}

        String.contains?(latest, "SMOKE_ASK_BOB_WITH_TOOL") ->
          require_context!(history, "ALICE_PRIVATE=amber")

          {:alice_tool_call,
           %ToolCall{
             id: "smoke-named-tool",
             name: "agent_message",
             arguments: %{"to" => "@robert", "message" => "SMOKE_TOOL_QUERY_BOB"}
           }}

        String.contains?(latest, "SMOKE_TOOL_QUERY_BOB") ->
          require_context!(history, "BOB_PRIVATE=violet")
          {:bob_tool_reply, "TOOL_BOB_ANSWER=violet"}

        String.contains?(latest, "TOOL_BOB_ANSWER=") ->
          require_context!(history, "ALICE_PRIVATE=amber")
          {:alice_tool_reply, "Alice observed tool-mediated Bob in original context."}

        String.contains?(latest, "SMOKE_SEED_BOB") ->
          {:bob_seed, "Bob retained his private context."}

        String.contains?(latest, "SMOKE_SEED_ALICE") ->
          {:alice_seed, "Alice retained her private context."}

        String.contains?(latest, "SMOKE_SEED_CAROL") ->
          {:carol_seed, "Carol retained her private context."}

        String.contains?(latest, "SMOKE_SEED_PRODUCT") ->
          {:product_seed, "Product owner retained private context."}

        String.contains?(latest, "PRODUCT_BOB_REPLY=") ->
          require_context!(history, "PRODUCT_PRIVATE=indigo")
          {:product_source_reply, "Product owner observed Bob in original context."}

        String.contains?(latest, "PRODUCT_REPLY=") ->
          require_context!(history, "ALICE_PRIVATE=amber")
          {:alice_product_reply, "Alice observed product response in original context."}

        String.contains?(latest, "SMOKE_PRODUCT_TO_BOB") ->
          require_context!(history, "BOB_PRIVATE=violet")
          {:bob_product_reply, "PRODUCT_BOB_REPLY=violet"}

        String.contains?(latest, "SMOKE_PRODUCT_QUERY") ->
          require_context!(history, "PRODUCT_PRIVATE=indigo")
          {:product_target_reply, "PRODUCT_REPLY=indigo"}

        String.contains?(latest, "BOB_REPLY_") ->
          require_context!(history, "ALICE_PRIVATE=amber")

          answer =
            if String.contains?(latest, "BOB_REPLY_TWO"),
              do: "Alice observed Bob's second answer in her original context.",
              else: "Alice observed Bob's first answer in her original context."

          {:alice_reply, answer}

        String.contains?(latest, "CAROL_REPLY=") ->
          require_context!(history, "ALICE_PRIVATE=amber")
          {:alice_external_reply, "Alice observed Carol's answer in her original context."}

        String.contains?(latest, "SMOKE_BOB_QUERY_ONE") ->
          require_context!(history, "BOB_PRIVATE=violet")
          {:bob_first, "BOB_REPLY_ONE=violet"}

        String.contains?(latest, "SMOKE_BOB_QUERY_TWO") ->
          require_context!(history, "BOB_PRIVATE=violet")
          require_context!(history, "BOB_REPLY_ONE=violet")
          {:bob_second, "BOB_REPLY_TWO=violet; prior answer retained"}

        String.contains?(latest, "SMOKE_CAROL_QUERY") ->
          require_context!(history, "CAROL_PRIVATE=teal")
          {:carol_reply, "CAROL_REPLY=teal"}

        String.contains?(latest, "SMOKE_BOT_TO_BOB") ->
          require_context!(history, "BOB_PRIVATE=violet")
          {:bob_external, "BOB_EXTERNAL_REPLY=violet"}

        true ->
          raise "unexpected scripted inference request"
      end

    Agent.update(LemonNamedAgentsSmoke.Observations, &[step | &1])
    tool_call? = is_struct(answer, ToolCall)

    message = %AssistantMessage{
      role: :assistant,
      content: if(tool_call?, do: [answer], else: [%TextContent{text: answer}]),
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{},
      stop_reason: if(tool_call?, do: :tool_use, else: :stop),
      timestamp: System.system_time(:millisecond)
    }

    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})

      if tool_call? do
        LemonAi.EventStream.push(stream, {:tool_call_start, 0, answer, message})
        LemonAi.EventStream.push(stream, {:tool_call_end, 0, answer, message})
      else
        LemonAi.EventStream.push(stream, {:text_start, 0, message})
        LemonAi.EventStream.push(stream, {:text_delta, 0, answer, message})
        LemonAi.EventStream.push(stream, {:text_end, 0, answer, message})
      end

      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    {:ok, stream}
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_list(value), do: Enum.map_join(value, "\n", &text/1)
  defp text(%{content: content}), do: text(content)
  defp text(%{text: text}), do: text(text)
  defp text(_), do: ""

  defp require_context!(history, sentinel) do
    if not String.contains?(history, sentinel), do: raise("existing native context was lost")
  end
end

defmodule LemonNamedAgentsSmoke do
  def run do
    source = File.cwd!()
    root = System.fetch_env!("LEMON_SMOKE_ROOT")
    cwd = Path.join(root, "workspace")
    File.cd!(cwd)
    cwd = File.cwd!()
    Logger.configure(level: :error)
    File.mkdir_p!(Path.join(System.user_home!(), ".lemon"))

    private_write(Path.join(System.user_home!(), ".lemon/config.toml"), """
    [defaults]
    provider = "openai"
    model = "gpt-4o-mini"
    thinking_level = "off"
    [providers.openai]
    api_key = "offline-scripted-inference-not-a-real-key"
    base_url = "http://127.0.0.1:1/v1"
    [gateway]
    enable_telegram = false
    max_concurrent_runs = 4
    """)

    # No Keychain access, external secret source, inherited config or live token.
    System.put_env("LEMON_NAMED_SMOKE_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    Application.put_env(:lemon_core, LemonCore.Secrets,
      key_providers: [:env],
      env_var: "LEMON_NAMED_SMOKE_MASTER_KEY"
    )

    Application.put_env(:lemon_core, :store_runtime_override,
      backend: LemonCore.Store.EtsBackend,
      backend_opts: []
    )

    Application.put_env(
      :lemon_core,
      LemonCore.Store,
      Keyword.merge(Application.get_env(:lemon_core, LemonCore.Store, []),
        backend: LemonCore.Store.EtsBackend,
        backend_opts: []
      )
    )

    Application.put_env(:lemon_core, LemonCore.RunHistoryStore, path: Path.join(root, "history"))
    Application.put_env(:lemon_core, :bus_backend, :pubsub)
    Application.put_env(:coding_agent, :agent_dir, Path.join(root, "agent"))
    Application.put_env(:coding_agent, :primary_session, nil)
    Application.put_env(:coding_agent, :task_store_path, Path.join(root, "tasks.dets"))
    Application.put_env(:coding_agent, :run_graph_path, Path.join(root, "run_graph.dets"))
    Application.put_env(:coding_agent, :process_store_path, Path.join(root, "processes.dets"))

    Application.put_env(:lemon_router, LemonRouter.RoutingFeedbackStore,
      path: Path.join(root, "routing")
    )

    Application.put_env(:lemon_router, :health_enabled, false)
    Application.put_env(:lemon_router, :engine_runtime, LemonGateway.Runtime)
    Application.put_env(:lemon_gateway, :health_enabled, false)
    Application.put_env(:lemon_gateway, :gateway_ingress_enabled, false)

    Application.put_env(:lemon_gateway, LemonGateway.Config,
      enable_telegram: false,
      max_concurrent_runs: 4,
      bindings: [],
      projects: %{}
    )

    Application.put_env(:lemon_channels, :adapters, [])
    Application.put_env(:lemon_honcho, :enabled, false)

    for app <- [:crypto, :ssl, :bandit, :coding_agent, :lemon_gateway, :lemon_router] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    {:ok, _} = Agent.start_link(fn -> [] end, name: __MODULE__.Observations)
    # Replace every registered inference API, not only the selected model's API:
    # an unintended model fallback also stays offline and must satisfy the script.
    for api <- LemonAi.ProviderRegistry.list(),
        do: LemonAi.ProviderRegistry.register(api, __MODULE__.Provider)

    case Application.load(:lemon_control_plane) do
      :ok -> :ok
      {:error, {:already_loaded, :lemon_control_plane}} -> :ok
    end

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    credential = Path.join(root, "operator.token")
    private_write(credential, token <> "\n")
    Application.put_env(:lemon_control_plane, :operator_token, token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    {:ok, _} =
      Supervisor.start_link(
        [
          LemonControlPlane.LogRing,
          LemonControlPlane.Methods.Registry,
          LemonControlPlane.Presence,
          LemonControlPlane.EventBridge,
          {DynamicSupervisor,
           strategy: :one_for_one, name: LemonControlPlane.ConnectionSupervisor},
          {Registry, keys: :unique, name: LemonControlPlane.ConnectionRegistry},
          {Task.Supervisor, name: LemonControlPlane.A2A.TaskSupervisor}
        ],
        strategy: :one_for_one
      )

    :ok = LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)

    {:ok, listener} =
      Bandit.start_link(
        plug: LemonControlPlane.HTTP.Router,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    manifest = Path.join(root, "runtime.json")

    private_write(
      manifest,
      Jason.encode!(%{
        url: "ws://127.0.0.1:#{port}/ws",
        credentialFile: credential,
        cwd: cwd,
        root: root
      })
    )

    {_, status} =
      System.cmd("bun", [Path.join(source, "scripts/smoke_named_agents.ts"), manifest],
        cd: cwd,
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    if status != 0 do
      receipts =
        case LemonRouter.AgentMessageStore.all() do
          {:ok, rows} ->
            Enum.map(
              rows,
              &Map.take(&1, [:status, :reply_state, :source_kind, :target_kind, :error])
            )

          _ ->
            :unavailable
        end

      IO.puts(
        Jason.encode!(%{
          smokeFailure: true,
          inferenceSteps: Agent.get(__MODULE__.Observations, &Enum.frequencies/1),
          receipts: receipts
        })
      )
    end

    check(status == 0, "authenticated named-agent smoke failed")

    # Manual UI use may deliberately submit additional messages after assertions.
    if System.get_env("LEMON_NAMED_SMOKE_KEEP_ALIVE") != "1" do
      observations = Agent.get(__MODULE__.Observations, &Enum.frequencies/1)

      for step <- [
            :alice_seed,
            :bob_seed,
            :carol_seed,
            :bob_first,
            :bob_second,
            :alice_tool_call,
            :alice_tool_ack,
            :bob_tool_reply,
            :alice_tool_reply,
            :product_seed,
            :product_source_reply,
            :alice_product_reply,
            :bob_product_reply,
            :product_target_reply
          ],
          do:
            check(Map.get(observations, step) == 1, "missing or duplicated native inference step")

      check(
        Map.get(observations, :alice_reply) == 2,
        "native replies did not reach the original sender exactly once"
      )

      check(
        Map.get(observations, :alice_external_reply) == 1,
        "external reply did not reach the original sender"
      )

      check(Map.get(observations, :carol_reply) == 1, "external request did not run exactly once")

      check(
        Map.get(observations, :bob_external) == 1,
        "external source did not address existing Bob"
      )
    end

    IO.puts(
      Jason.encode!(%{
        status: "passed",
        inference: "scripted",
        nativeRouter: true,
        authenticatedWebSocket: true,
        liveProviderCalls: 0,
        platformCalls: 0,
        existingContext: true,
        renameStableId: true,
        nativeAgentMessageTool: true,
        nativeReplies: 2,
        externalRequestReply: true,
        productAddressedService: true,
        managedProof: false
      })
    )
  end

  defp check(true, _), do: :ok
  defp check(false, message), do: raise(message)

  defp private_write(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o600)
  end
end

try do
  LemonNamedAgentsSmoke.run()
rescue
  error ->
    # Never dump transport payloads, private state, or random credentials.
    IO.puts(
      :stderr,
      "Named-agent smoke failed (#{inspect(error.__struct__)}); no passing evidence claimed."
    )

    System.halt(1)
end
