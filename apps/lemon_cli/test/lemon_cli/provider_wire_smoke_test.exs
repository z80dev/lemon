defmodule LemonCli.ProviderWireSmokeTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, CustomProviders, StreamOptions}
  alias LemonAi.Types.{Context, UserMessage}

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:owner], {:wire_request, conn.method, conn.request_path, conn.req_headers})

      case {conn.method, conn.request_path} do
        {"GET", "/v1/models"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "wire-model"}]}))

        {"POST", "/v1/chat/completions"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(opts[:owner], {:wire_payload, Jason.decode!(body)})

          events = [
            %{"choices" => [%{"index" => 0, "delta" => %{"content" => "loopback reply"}}]},
            %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}
          ]

          sse = Enum.map_join(events, "\n\n", &("data: " <> Jason.encode!(&1)))

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, sse <> "\n\ndata: [DONE]\n\n")

        {"POST", path}
        when path in [
               "/v1/responses",
               "/v1/messages",
               "/v1/models/wire-model:streamGenerateContent"
             ] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(opts[:owner], {:wire_payload, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, success_body(path))

        _ ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end

    defp success_body("/v1/responses") do
      data(%{"type" => "response.completed", "response" => %{"status" => "completed"}})
    end

    defp success_body("/v1/messages") do
      Enum.map_join(
        [
          {"message_start", %{"message" => %{"usage" => %{}}}},
          {"message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}},
          {"message_stop", %{}}
        ],
        fn {event, payload} -> "event: #{event}\n" <> data(payload) end
      )
    end

    defp success_body("/v1/models/wire-model:streamGenerateContent") do
      data(%{"candidates" => [%{"finishReason" => "STOP"}]})
    end

    defp data(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  test "custom config discovers and streams over loopback without borrowing an ambient key" do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous_key = System.get_env("OPENAI_API_KEY")
    previous_req = Req.default_options()
    Req.default_options(Keyword.drop(previous_req, [:plug, :adapter, :base_url]))
    System.put_env("OPENAI_API_KEY", "ambient-decoy-never-send")

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous_key,
        do: System.put_env("OPENAI_API_KEY", previous_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, owner: self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    {:ok, settings} =
      Toml.decode("""
      [providers.wire-gateway]
      api = "openai_completions"
      base_url = "http://127.0.0.1:#{port}/v1"
      api_key = "synthetic-gateway-key"
      discovery = "openai"
      headers = { "X-Team" = "wire-smoke" }
      """)

    providers = LemonCore.Config.Providers.resolve(settings).providers
    assert Credentials.provider_has_credentials?("wire-gateway", providers)

    assert [%{id: "wire-model", provider: "wire-gateway"}] =
             CustomProviders.models(providers, discover: true)

    model = CustomProviders.lookup(providers, "wire-gateway", "wire-model")
    options = StreamOptions.build_stream_options(model, providers, nil, nil)
    context = Context.new(messages: [%UserMessage{content: "Hello"}])
    assert {:ok, stream} = LemonAi.stream(model, context, options)
    assert LemonAi.EventStream.collect_text(stream) == "loopback reply"
    assert {:ok, %{stop_reason: :stop}} = LemonAi.EventStream.result(stream)

    assert_received {:wire_request, "GET", "/v1/models", discovery_headers}
    assert_received {:wire_request, "POST", "/v1/chat/completions", stream_headers}
    assert_received {:wire_payload, %{"model" => "wire-model", "stream" => true}}

    for headers <- [discovery_headers, stream_headers] do
      assert {"authorization", "Bearer synthetic-gateway-key"} in headers
      assert {"x-team", "wire-smoke"} in headers
      refute inspect(headers) =~ "ambient-decoy-never-send"
    end
  end

  for {api, path, auth_header} <- [
        {"openai_completions", "/v1/chat/completions", "authorization"},
        {"openai_responses", "/v1/responses", "authorization"},
        {"anthropic_messages", "/v1/messages", "x-api-key"},
        {"google_generative_ai", "/v1/models/wire-model:streamGenerateContent", "x-goog-api-key"}
      ] do
    @wire_api api
    @wire_path path
    @wire_auth_header auth_header

    test "#{api} sends model then caller overrides once, using only its own credential" do
      {:ok, _} = Application.ensure_all_started(:lemon_ai)
      saved_req = Req.default_options()
      Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))
      env_keys = ~w(OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GEMINI_API_KEY)
      saved_env = Map.new(env_keys, &{&1, System.get_env(&1)})
      Enum.each(env_keys, &System.put_env(&1, "ambient-decoy-never-send"))

      on_exit(fn ->
        Req.default_options(saved_req)

        Enum.each(saved_env, fn {key, value} ->
          if value, do: System.put_env(key, value), else: System.delete_env(key)
        end)
      end)

      server =
        start_supervised!(
          {Bandit,
           plug: {Endpoint, owner: self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
      root = "http://127.0.0.1:#{port}"
      base_url = if @wire_api == "anthropic_messages", do: root, else: root <> "/v1"

      {:ok, settings} =
        Toml.decode("""
        [providers.wire-gateway]
        api = "#{@wire_api}"
        base_url = "#{base_url}"
        api_key = "synthetic-gateway-key"
        headers = { "X-Tenant" = "providerA", "X-Route" = "providerA", "X-Default" = "retained" }

        [[providers.wire-gateway.models]]
        id = "wire-model"
        headers = { "x-TENANT" = "modelB", "x-route" = "modelB" }
        """)

      providers = LemonCore.Config.Providers.resolve(settings).providers
      model = CustomProviders.lookup(providers, "wire-gateway", "wire-model")
      context = Context.new(messages: [%UserMessage{content: "Hello"}])

      for {caller, selected, beta} <- [
            {nil, "modelB", nil},
            {%{headers: %{"X-TENANT" => "callerC", "X-ROUTE" => "callerC"}}, "callerC", nil},
            {%{headers: %{"AnThRoPiC-BeTa" => "caller-beta"}}, "modelB", "caller-beta"}
          ] do
        options = StreamOptions.build_stream_options(model, providers, caller, nil)
        assert {:ok, stream} = LemonAi.stream(model, context, options)
        assert {:ok, %{stop_reason: :stop}} = LemonAi.EventStream.result(stream, 5_000)
        assert_receive {:wire_request, "POST", path, headers}
        assert path == @wire_path
        assert_receive {:wire_payload, _}

        assert header_values(headers, "x-tenant") == [selected]
        assert header_values(headers, "x-route") == [selected]
        assert header_values(headers, "x-default") == ["retained"]

        expected_key =
          if @wire_auth_header == "authorization",
            do: "Bearer synthetic-gateway-key",
            else: "synthetic-gateway-key"

        assert header_values(headers, @wire_auth_header) == [expected_key]

        for name <- ["authorization", "x-api-key", "x-goog-api-key"] -- [@wire_auth_header] do
          assert header_values(headers, name) == []
        end

        refute Enum.any?(headers, fn {_, value} -> value == "ambient-decoy-never-send" end)

        if @wire_api == "anthropic_messages" do
          assert [betas] = header_values(headers, "anthropic-beta")
          assert "interleaved-thinking-2025-05-14" in String.split(betas, ",")
          assert "fine-grained-tool-streaming-2025-05-14" in String.split(betas, ",")
          if beta, do: assert(beta in String.split(betas, ","))
        end
      end

      # Keyless custom endpoints must not acquire ambient auth in any protocol.
      keyless_cfg =
        providers["wire-gateway"]
        |> Map.put(:auth, "none")
        |> Map.delete(:api_key)

      providers = Map.put(providers, "wire-gateway", keyless_cfg)
      model = CustomProviders.lookup(providers, "wire-gateway", "wire-model")
      options = StreamOptions.build_stream_options(model, providers, nil, nil)
      assert {:ok, stream} = LemonAi.stream(model, context, options)
      assert {:ok, %{stop_reason: :stop}} = LemonAi.EventStream.result(stream, 5_000)
      assert_receive {:wire_request, "POST", path, headers}
      assert path == @wire_path
      assert_receive {:wire_payload, _}
      assert header_values(headers, "x-tenant") == ["modelB"]

      for name <- ["authorization", "x-api-key", "x-goog-api-key"] do
        assert header_values(headers, name) == []
      end
    end
  end

  defp header_values(headers, name) do
    for {key, value} <- headers, key == name, do: value
  end
end
