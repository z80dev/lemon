defmodule CodingAgent.Session.DefaultProviderAuthorityWireTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SettingsManager}

  @aggregator_id "anthropic/claude-lemon-uncatalogued"
  @aggregator_key "synthetic-openrouter-wire-key"
  @ambient_trap "synthetic-ambient-anthropic-trap"
  @env ~w(HOME ANTHROPIC_API_KEY ANTHROPIC_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENROUTER_API_KEY
          LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL)

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        opts[:test_pid],
        {:wire, opts[:tag], conn.method, conn.request_path, Map.new(conn.req_headers), body}
      )

      case opts[:tag] do
        :aggregator ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, completion_stream())

        :trap ->
          Plug.Conn.send_resp(conn, 500, "foreign provider trap")
      end
    end

    defp completion_stream do
      chunk = fn choice ->
        Jason.encode!(%{
          "id" => "chatcmpl-wire",
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => "anthropic/claude-lemon-uncatalogued",
          "choices" => [Map.put(choice, "index", 0)]
        })
      end

      [
        chunk.(%{"delta" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => nil}),
        chunk.(%{"delta" => %{}, "finish_reason" => "stop"}),
        "[DONE]"
      ]
      |> Enum.map_join(&("data: " <> &1 <> "\n\n"))
    end
  end

  setup do
    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    saved_req = Req.default_options()

    root =
      Path.join(System.tmp_dir!(), "default_provider_wire_#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    cwd = Path.join(root, "cwd")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)

    Enum.each(@env, &System.delete_env/1)
    System.put_env("HOME", home)
    # Ambient credential for the provider named by the aggregator namespace.
    System.put_env("ANTHROPIC_API_KEY", @ambient_trap)
    Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))

    for provider <- [:openrouter, :anthropic], do: LemonAi.CircuitBreaker.reset(provider)
    LemonAgent.ModelRuntime.CredentialHealth.reset()

    on_exit(fn ->
      Req.default_options(saved_req)

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{cwd: cwd, aggregator: endpoint(:aggregator), trap: endpoint(:trap)}
  end

  test "an explicit aggregator default sends its namespaced id to the aggregator", ctx do
    settings = settings(%{"provider" => "openrouter", "model" => @aggregator_id}, ctx)
    session = start_supervised!({Session, session_opts(ctx.cwd, settings)})
    Session.subscribe(session)

    assert :ok = Session.prompt(session, "hello")

    assert_receive {:wire, :aggregator, "POST", path, headers, body}, 5_000
    assert String.ends_with?(path, "/chat/completions")
    assert headers["authorization"] == "Bearer " <> @aggregator_key
    assert Jason.decode!(body)["model"] == @aggregator_id
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    refute_received {:wire, :trap, _, _, _, _}
    refute Enum.any?(Session.get_messages(session), &(inspect(&1) =~ @ambient_trap))
  end

  test "without a configured provider a qualified default still selects its provider", ctx do
    settings = settings(%{"model" => "openrouter/" <> @aggregator_id}, ctx)
    session = start_supervised!({Session, session_opts(ctx.cwd, settings)})
    Session.subscribe(session)

    assert :ok = Session.prompt(session, "hello")

    assert_receive {:wire, :aggregator, "POST", _path, headers, body}, 5_000
    assert headers["authorization"] == "Bearer " <> @aggregator_key
    assert Jason.decode!(body)["model"] == @aggregator_id
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    refute_received {:wire, :trap, _, _, _, _}
  end

  defp endpoint(tag) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, test_pid: self(), tag: tag},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: {:endpoint, tag}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  # Configuration-loaded provenance: `defaults` without a provider resolves to
  # the built-in fallback with `:inherited` source; naming one is `:explicit`.
  defp settings(defaults, ctx) do
    agent =
      LemonCore.Config.Agent.resolve(%{
        "defaults" => defaults,
        "runtime" => %{"provider_routing" => %{"enabled" => false}}
      })

    expected_source = if Map.has_key?(defaults, "provider"), do: :explicit, else: :inherited
    assert agent.default_provider_source == expected_source

    settings =
      SettingsManager.from_config(%LemonCore.Config{
        agent: Map.from_struct(agent),
        providers: %{
          "openrouter" => %{api_key: @aggregator_key, base_url: ctx.aggregator <> "/api/v1"},
          "anthropic" => %{base_url: ctx.trap}
        }
      })

    %{
      settings
      | compaction_enabled: false,
        retry_enabled: false,
        tools: %{wasm: %{enabled: false}}
    }
  end

  defp session_opts(cwd, settings) do
    [
      cwd: cwd,
      settings_manager: settings,
      tools: [],
      system_prompt: "Reply briefly."
    ]
  end
end
