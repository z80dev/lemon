defmodule LemonHoncho.ClientTest do
  # `async: false` because the transport is injected through the application
  # environment, which is process-wide: a concurrent module setting
  # `:req_options` would steal this module's stub.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonHoncho.Client
  alias LemonHoncho.Config

  @moduletag :capture_log

  setup do
    on_exit(fn -> Application.delete_env(:lemon_honcho, :req_options) end)
    :ok
  end

  describe "route shapes" do
    test "ensure_workspace posts the workspace id" do
      stub_json(%{"id" => "lemon"})

      assert {:ok, %{"id" => "lemon"}} = Client.ensure_workspace(config())

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces"
      assert request.body == %{"id" => "lemon"}
    end

    test "ensure_peer posts the peer id under the workspace" do
      stub_json(%{"id" => "z80"})

      assert {:ok, %{"id" => "z80"}} = Client.ensure_peer(config(), "z80")

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/peers"
      assert request.body == %{"id" => "z80"}
    end

    test "ensure_session sends peers as an object keyed by peer id" do
      stub_json(%{"id" => "proj"})

      specs = [
        {"z80", %{observe_me: true, observe_others: true}},
        {"lemon", %{observe_me: false, observe_others: true}}
      ]

      assert {:ok, _body} = Client.ensure_session(config(), "proj", specs)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/sessions"

      assert request.body == %{
               "id" => "proj",
               "peers" => %{
                 "z80" => %{"observe_me" => true, "observe_others" => true},
                 "lemon" => %{"observe_me" => false, "observe_others" => true}
               }
             }
    end

    test "set_peer_config puts only the observation flags" do
      stub_json(%{})

      flags = %{observe_me: true, observe_others: false, bogus: "dropped"}

      assert {:ok, _body} = Client.set_peer_config(config(), "proj", "z80", flags)

      assert_received {:honcho_request, request}
      assert request.method == "PUT"
      assert request.path == "/v3/workspaces/lemon/sessions/proj/peers/z80/config"
      assert request.body == %{"observe_me" => true, "observe_others" => false}
    end

    test "add_messages wraps the messages in a messages key" do
      stub_json([])

      messages = [
        %{content: "how do I deploy?", peer_id: "z80"},
        %{content: "with mix release", peer_id: "lemon"}
      ]

      assert {:ok, []} = Client.add_messages(config(), "proj", messages)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/sessions/proj/messages"

      assert request.body == %{
               "messages" => [
                 %{"content" => "how do I deploy?", "peer_id" => "z80"},
                 %{"content" => "with mix release", "peer_id" => "lemon"}
               ]
             }
    end

    test "session_context sends the options it was given as query params" do
      stub_json(%{"summary" => nil, "messages" => []})

      opts = [
        summary: true,
        tokens: 1200,
        peer_target: "z80",
        peer_perspective: "lemon",
        search_query: "deploys",
        limit_to_session: false
      ]

      assert {:ok, %{"messages" => []}} = Client.session_context(config(), "proj", opts)

      assert_received {:honcho_request, request}
      assert request.method == "GET"
      assert request.path == "/v3/workspaces/lemon/sessions/proj/context"

      assert request.query == %{
               "summary" => "true",
               "tokens" => "1200",
               "peer_target" => "z80",
               "peer_perspective" => "lemon",
               "search_query" => "deploys",
               "limit_to_session" => "false"
             }
    end

    test "session_context omits options that were not given" do
      stub_json(%{})

      assert {:ok, _body} = Client.session_context(config(), "proj", summary: true)

      assert_received {:honcho_request, request}
      assert request.query == %{"summary" => "true"}
    end

    test "peer_context reads the peer context route" do
      stub_json(%{"representation" => "knows elixir"})

      opts = [target: "lemon", search_query: "editor", search_top_k: 5, max_conclusions: 20]

      assert {:ok, %{"representation" => "knows elixir"}} =
               Client.peer_context(config(), "z80", opts)

      assert_received {:honcho_request, request}
      assert request.method == "GET"
      assert request.path == "/v3/workspaces/lemon/peers/z80/context"

      assert request.query == %{
               "target" => "lemon",
               "search_query" => "editor",
               "search_top_k" => "5",
               "max_conclusions" => "20"
             }
    end

    test "chat posts a non-streaming dialectic query and returns the content" do
      stub_json(%{"content" => "They prefer green."})

      opts = [target: "z80", session_id: "proj", reasoning_level: :high]

      assert {:ok, "They prefer green."} = Client.chat(config(), "lemon", "favorite color?", opts)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/peers/lemon/chat"

      assert request.body == %{
               "query" => "favorite color?",
               "stream" => false,
               "target" => "z80",
               "session_id" => "proj",
               "reasoning_level" => "high"
             }
    end

    test "session_search posts query and limit and returns the result list" do
      stub_json([%{"id" => "m1"}])

      assert {:ok, [%{"id" => "m1"}]} =
               Client.session_search(config(), "proj", "deploy", limit: 5)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/sessions/proj/search"
      assert request.body == %{"query" => "deploy", "limit" => 5}
    end

    test "workspace_search searches across sessions and defaults the limit" do
      stub_json([])

      assert {:ok, []} = Client.workspace_search(config(), "deploy")

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/search"
      assert request.body == %{"query" => "deploy", "limit" => 10}
    end

    test "get_peer_card reads the card route and unwraps peer_card" do
      stub_json(%{"peer_card" => ["likes green", "lucky number 888"]})

      assert {:ok, ["likes green", "lucky number 888"]} =
               Client.get_peer_card(config(), "z80", target: "lemon")

      assert_received {:honcho_request, request}
      assert request.method == "GET"
      assert request.path == "/v3/workspaces/lemon/peers/z80/card"
      assert request.query == %{"target" => "lemon"}
    end

    test "set_peer_card puts the card lines" do
      stub_json(%{"peer_card" => ["likes green"]})

      assert {:ok, ["likes green"]} = Client.set_peer_card(config(), "z80", ["likes green"])

      assert_received {:honcho_request, request}
      assert request.method == "PUT"
      assert request.path == "/v3/workspaces/lemon/peers/z80/card"
      assert request.query == %{}
      assert request.body == %{"peer_card" => ["likes green"]}
    end

    test "create_conclusions posts the conclusions array and drops a nil session" do
      stub_json([])

      conclusions = [
        %{observer_id: "lemon", observed_id: "z80", content: "ships on Fridays", session_id: nil},
        %{observer_id: "lemon", observed_id: "z80", content: "uses zsh", session_id: "proj"}
      ]

      assert {:ok, []} = Client.create_conclusions(config(), conclusions)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/conclusions"

      assert request.body == %{
               "conclusions" => [
                 %{
                   "observer_id" => "lemon",
                   "observed_id" => "z80",
                   "content" => "ships on Fridays"
                 },
                 %{
                   "observer_id" => "lemon",
                   "observed_id" => "z80",
                   "content" => "uses zsh",
                   "session_id" => "proj"
                 }
               ]
             }
    end

    test "query_conclusions sends observer and observed inside filters" do
      stub_json([%{"content" => "uses zsh"}])

      opts = [observer_id: "lemon", observed_id: "z80", top_k: 3]

      assert {:ok, [%{"content" => "uses zsh"}]} =
               Client.query_conclusions(config(), "shell", opts)

      assert_received {:honcho_request, request}
      assert request.method == "POST"
      assert request.path == "/v3/workspaces/lemon/conclusions/query"

      assert request.body == %{
               "query" => "shell",
               "top_k" => 3,
               "filters" => %{"observer_id" => "lemon", "observed_id" => "z80"}
             }
    end

    test "delete_conclusion deletes by id and normalizes the empty body" do
      stub_response(204, "")

      assert Client.delete_conclusion(config(), "conc_1") == {:ok, %{}}

      assert_received {:honcho_request, request}
      assert request.method == "DELETE"
      assert request.path == "/v3/workspaces/lemon/conclusions/conc_1"
    end
  end

  describe "base url resolution" do
    test "a trailing version segment on the base url is stripped" do
      stub_json(%{})

      versioned = config(base_url: "https://honcho.example/v3/")

      assert {:ok, _body} = Client.ensure_workspace(versioned)

      assert_received {:honcho_request, request}
      assert request.host == "honcho.example"
      assert request.path == "/v3/workspaces"
      refute request.path =~ "/v3/v3"
    end

    test "a base url without a version segment is used as given" do
      stub_json(%{})

      assert {:ok, _body} = Client.ensure_workspace(config(base_url: "https://honcho.example"))

      assert_received {:honcho_request, request}
      assert request.host == "honcho.example"
      assert request.path == "/v3/workspaces"
    end

    test "environments map to their deployments and unknown falls back to production" do
      assert environment_host("production") == {"api.honcho.dev", 443}
      assert environment_host("demo") == {"demo.honcho.dev", 443}
      assert environment_host("local") == {"localhost", 8000}
      assert environment_host("staging") == {"api.honcho.dev", 443}
    end

    test "path segments containing slashes and spaces are percent-encoded" do
      stub_json(%{})

      awkward = config(workspace: "acme/team one")

      assert {:ok, _body} = Client.ensure_peer(awkward, "z80/laptop")

      assert_received {:honcho_request, request}
      assert request.path == "/v3/workspaces/acme%2Fteam%20one/peers"
    end
  end

  describe "authorization" do
    test "a configured api key is sent as a bearer token" do
      stub_json(%{})

      assert {:ok, _body} = Client.ensure_workspace(config(api_key: "sk-live-1"))

      assert_received {:honcho_request, request}

      assert List.keyfind(request.headers, "authorization", 0) ==
               {"authorization", "Bearer sk-live-1"}
    end

    test "no header is sent when a local deployment has no key" do
      stub_json(%{})

      keyless = config(api_key: nil, base_url: "http://localhost:8000")

      assert {:ok, _body} = Client.ensure_workspace(keyless)

      assert_received {:honcho_request, request}
      assert List.keyfind(request.headers, "authorization", 0) == nil
    end

    test "a missing key is only worth mentioning for a public endpoint" do
      stub_json(%{})
      public = config(api_key: nil, base_url: "https://honcho.example")
      public_log = capture_log(fn -> assert {:ok, _body} = Client.ensure_workspace(public) end)

      stub_json(%{})
      # 100.64.0.0/10 is carrier-grade NAT — where a Tailscale self-host lives.
      tailscale = config(api_key: nil, base_url: "http://100.101.102.103:8000")

      private_log =
        capture_log(fn -> assert {:ok, _body} = Client.ensure_workspace(tailscale) end)

      assert public_log =~ "no API key configured"
      refute private_log =~ "no API key configured"
    end
  end

  describe "error contract" do
    test "an empty config is not configured" do
      assert {:error, :not_configured} = Client.ensure_workspace(%Config{})
      assert {:error, :not_configured} = Client.chat(%Config{}, "z80", "hi")
    end

    test "401 is distinguished from other api errors" do
      stub_response(401, ~s({"error":"bad key"}))

      assert {:error, {:unauthorized, _body}} = Client.ensure_workspace(config())
    end

    test "other non-2xx statuses come back tagged with the status" do
      stub_response(500, ~s({"error":"boom"}))

      assert {:error, {:api_error, 500, _body}} = Client.ensure_workspace(config())
    end

    test "a transport failure is tagged and never raised" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, _reason}} = Client.ensure_workspace(config())
    end

    test "a garbage body is returned as-is rather than raising" do
      stub_response(200, "<html>not json</html>")

      assert {:ok, "<html>not json</html>"} = Client.ensure_workspace(config())
    end

    test "chat returns nil content instead of crashing" do
      stub_json(%{"content" => nil})
      assert {:ok, nil} = Client.chat(config(), "lemon", "anything?")

      stub_json(%{"content" => "   "})
      assert {:ok, nil} = Client.chat(config(), "lemon", "anything?")
    end

    test "an unexpected card payload degrades to nil" do
      stub_json(%{"unexpected" => true})

      assert {:ok, nil} = Client.get_peer_card(config(), "z80")
    end

    test "an unexpected search payload degrades to an empty list" do
      stub_json(%{"unexpected" => true})

      assert {:ok, []} = Client.workspace_search(config(), "deploy")
    end
  end

  ## Helpers

  defp config(overrides \\ []) do
    struct!(Config, Keyword.merge([api_key: "sk-test", workspace: "lemon"], overrides))
  end

  # Every stub records the outbound request into the test's mailbox rather than
  # asserting inside the plug: the client rescues exceptions raised by the
  # transport, so an assertion failure inside a plug would be swallowed into an
  # `{:error, {:transport, _}}` instead of failing the test where it happened.
  defp stub_json(response) do
    stub_recording(fn conn -> Req.Test.json(conn, response) end)
  end

  defp stub_response(status, body) do
    stub_recording(fn conn -> Plug.Conn.send_resp(conn, status, body) end)
  end

  defp stub_recording(respond) do
    test_pid = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:honcho_request, snapshot(conn, raw)})
      respond.(conn)
    end)
  end

  defp stub(plug) do
    Application.put_env(:lemon_honcho, :req_options, plug: plug, retry: false)
  end

  defp snapshot(conn, raw) do
    %{
      method: conn.method,
      host: conn.host,
      port: conn.port,
      path: conn.request_path,
      query: URI.decode_query(conn.query_string || ""),
      headers: conn.req_headers,
      body: decode_body(raw)
    }
  end

  defp decode_body(""), do: nil
  defp decode_body(raw), do: Jason.decode!(raw)

  defp environment_host(environment) do
    stub_json(%{})

    assert {:ok, _body} = Client.ensure_workspace(config(environment: environment))
    assert_received {:honcho_request, request}

    {request.host, request.port}
  end
end
