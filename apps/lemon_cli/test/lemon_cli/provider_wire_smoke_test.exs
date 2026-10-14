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

        _ ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end
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
end
