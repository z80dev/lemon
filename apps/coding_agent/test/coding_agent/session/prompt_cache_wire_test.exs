defmodule CodingAgent.Session.PromptCacheWireTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias LemonAi.Types.{Model, ModelCost}

  @moduletag :tmp_dir
  @providers [
    {:openai, :openai_responses},
    {:openai_codex, :openai_codex_responses},
    {:anthropic, :anthropic_messages},
    {:vercel_ai_gateway, :anthropic_messages},
    {:vercel_ai_gateway, :openai_responses}
  ]

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(%{method: "HEAD"} = conn, _opts), do: Plug.Conn.send_resp(conn, 200, "")

    def call(conn, opts) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(opts[:owner], {:cache_wire, body, Map.new(conn.req_headers)})

      events =
        if Map.has_key?(body, "messages") do
          [
            %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}},
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "text", "text" => ""}
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "OK"}
            },
            %{"type" => "content_block_stop", "index" => 0},
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "end_turn"},
              "usage" => %{"output_tokens" => 1}
            },
            %{"type" => "message_stop"}
          ]
        else
          item = %{
            "id" => "msg_wire",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "OK", "annotations" => []}]
          }

          [
            %{
              "type" => "response.output_item.added",
              "output_index" => 0,
              "item" => Map.put(item, "content", [])
            },
            %{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "OK"},
            %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
            %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_wire",
                "status" => "completed",
                "output" => [item],
                "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
              }
            }
          ]
        end

      sse =
        Enum.map_join(events, "", fn event ->
          "event: " <> event["type"] <> "\ndata: " <> Jason.encode!(event) <> "\n\n"
        end)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse)
    end
  end

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Directory-only instructions.")
    saved_req = Req.default_options()
    Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))
    LemonAgent.ModelRuntime.CredentialHealth.reset()

    for {provider, _api} <- @providers, do: LemonAi.CircuitBreaker.reset(provider)

    on_exit(fn ->
      Req.default_options(saved_req)
      LemonAgent.ModelRuntime.CredentialHealth.reset()
      for {provider, _api} <- @providers, do: LemonAi.CircuitBreaker.reset(provider)
    end)

    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, owner: self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}"}
  end

  for {provider, api} <- @providers do
    test "#{provider}/#{api} keeps native session cache controls across turns and resume",
         context do
      provider = unquote(provider)
      api = unquote(api)
      path = Path.join(context.tmp_dir, "session.jsonl")
      session = start_session(context, provider, api, path)
      id = Session.get_stats(session).session_id

      first = request(session, "First turn.")
      second = request(session, "Second turn.")
      stop_supervised!(Session)
      resumed = start_session(context, provider, api, path)
      assert Session.get_stats(resumed).session_id == id
      third = request(resumed, "Third turn after resume.")

      for wire <- [first, second, third] do
        assert_cache_controls(wire, provider, api, id)
      end

      assert system(first) == system(second)
      assert system(first) == system(third)
      stop_supervised!(Session)
      fresh = start_session(context, provider, api, Path.join(context.tmp_dir, "fresh.jsonl"))
      fresh_id = Session.get_stats(fresh).session_id
      refute fresh_id == id
      fresh_wire = request(fresh, "Independent session.")
      assert_cache_controls(fresh_wire, provider, api, fresh_id)
    end
  end

  defp assert_cache_controls({body, headers}, provider, api, id) do
    if api == :anthropic_messages do
      assert_anthropic_breakpoints(body)
    else
      assert body["prompt_cache_key"] == id
    end

    if provider == :openai_codex do
      for header <- ["session_id", "conversation_id", "x-client-request-id"] do
        assert headers[header] == id
      end
    end

    if provider == :vercel_ai_gateway do
      assert body["session_id"] == id
    else
      refute Map.has_key?(body, "session_id")
    end
  end

  defp start_session(context, provider, api, path) do
    unless File.exists?(path) do
      :ok = SessionManager.save_to_file(path, SessionManager.new(context.tmp_dir))
    end

    token =
      if provider == :openai_codex do
        claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "wire-account"}}
        "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"
      else
        "test-key"
      end

    settings = %SettingsManager{
      compaction_enabled: false,
      retry_enabled: false,
      providers: %{Atom.to_string(provider) => %{auth_source: "api_key", api_key: token}}
    }

    model = %Model{
      id: "wire-model",
      name: "Wire model",
      provider: provider,
      api: api,
      base_url: context.base_url,
      max_tokens: 1024,
      cost: %ModelCost{}
    }

    session =
      start_supervised!(
        {Session,
         cwd: context.tmp_dir,
         workspace_dir: Path.join(context.tmp_dir, "workspace"),
         session_file: path,
         model: model,
         settings_manager: settings,
         system_prompt: "Shared cacheable instructions.",
         stream_options: %{session_id: "caller-supplied-wrong-session"},
         tools: [],
         mcp_tools: [],
         extension_inventory: {[], []},
         project_memory_capture: false}
      )

    Session.subscribe(session)
    session
  end

  defp request(session, text) do
    assert :ok = Session.prompt(session, text)
    assert_receive {:cache_wire, body, headers}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    {body, headers}
  end

  defp system({%{"instructions" => system}, _headers}), do: system
  defp system({%{"system" => system}, _headers}), do: system
  defp system({%{"input" => [system | _]}, _headers}), do: system

  defp assert_anthropic_breakpoints(body) do
    system = body["system"]
    marker = Enum.find_index(system, &Map.has_key?(&1, "cache_control"))
    assert is_integer(marker)
    {prefix, footer} = Enum.split(system, marker + 1)
    assert Enum.any?(prefix, &String.contains?(&1["text"], "Shared cacheable instructions."))
    assert Enum.any?(footer, &String.contains?(&1["text"], "Directory-only instructions."))
    refute Enum.any?(prefix, &String.contains?(&1["text"], "Directory-only instructions."))
    refute Enum.any?(footer, &Map.has_key?(&1, "cache_control"))
    assert length(Regex.scan(~r/"cache_control":/, Jason.encode!(body))) == 2

    assert List.last(List.last(body["messages"])["content"])["cache_control"] ==
             %{"type" => "ephemeral"}
  end
end
