defmodule LemonHoncho.IsolationTest.FakeHoncho do
  @moduledoc false
  # A small in-memory Honcho behind the real `LemonHoncho.Client`, installed as a
  # `Req.Test` plug. It models what makes memory leak in the real one:
  #
  #   * messages are stored per session exactly as posted (metadata included),
  #     and a session's summary is the text of its messages;
  #   * a peer's representation is everything that peer ever said, in any
  #     session (peer-level, cross-session — like Honcho's), and the dialectic
  #     answers from the target's (or the asking peer's own) representation;
  #   * peer cards and conclusions are stored per peer, by id;
  #   * both message searches ignore `filters` and conclusion queries ignore
  #     the observer/observed filters: a server that does not understand a
  #     filter must still not leak another owner's memory.

  use Agent

  def start_link(owner) do
    Agent.start_link(
      fn -> %{owner: owner, messages: [], cards: %{}, conclusions: %{}, next: 1} end,
      name: __MODULE__
    )
  end

  def messages, do: Agent.get(__MODULE__, &Enum.reverse(&1.messages))
  def conclusions, do: Agent.get(__MODULE__, & &1.conclusions)

  def seed(session_id, message) do
    Agent.update(__MODULE__, &store(&1, session_id, message))
  end

  def seed_card(peer, lines), do: Agent.update(__MODULE__, &put_in(&1.cards[peer], lines))

  def seed_conclusion(conclusion) do
    Agent.get_and_update(__MODULE__, fn state ->
      id = "con_#{state.next}"
      stored = Map.put(conclusion, "id", id)
      {id, %{state | conclusions: Map.put(state.conclusions, id, stored), next: state.next + 1}}
    end)
  end

  def plug(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)
    conn = Plug.Conn.fetch_query_params(conn)
    owner = Agent.get(__MODULE__, & &1.owner)
    segments = conn.path_info

    send(owner, {:fake_honcho, conn.method, segments, body})

    case respond(conn.method, segments, body, conn.query_params) do
      {:status, status} -> Plug.Conn.send_resp(conn, status, "")
      response -> Req.Test.json(conn, response)
    end
  end

  defp respond("POST", ["v3", "workspaces", _ws, "sessions", session_id, "messages"], body, _q) do
    Enum.each(body["messages"] || [], &seed(session_id, &1))
    []
  end

  defp respond("GET", ["v3", "workspaces", _ws, "sessions", session_id, "context"], _body, _q) do
    content = session_id |> in_session() |> Enum.map_join("\n", & &1["content"])
    %{"summary" => %{"content" => content}}
  end

  defp respond("POST", ["v3", "workspaces", _ws, "sessions", session_id, "search"], _body, _q),
    do: in_session(session_id)

  defp respond("POST", ["v3", "workspaces", _ws, "search"], _body, _q), do: messages()

  defp respond("GET", ["v3", "workspaces", _ws, "peers", peer, "context"], _body, query) do
    subject = query["target"] || peer
    %{"representation" => representation(subject), "peer_card" => card(subject)}
  end

  defp respond("GET", ["v3", "workspaces", _ws, "peers", peer, "card"], _body, query),
    do: %{"peer_card" => card(query["target"] || peer)}

  defp respond("PUT", ["v3", "workspaces", _ws, "peers", peer, "card"], body, _q) do
    seed_card(peer, body["peer_card"])
    %{"peer_card" => body["peer_card"]}
  end

  defp respond("POST", ["v3", "workspaces", _ws, "peers", peer, "chat"], body, _q) do
    %{"content" => "Dialectic: " <> representation(body["target"] || peer)}
  end

  defp respond("POST", ["v3", "workspaces", _ws, "conclusions"], body, _q) do
    Enum.map(body["conclusions"] || [], &seed_conclusion/1)
  end

  defp respond("POST", ["v3", "workspaces", _ws, "conclusions", "query"], _body, _q),
    do: Map.values(conclusions())

  defp respond("GET", ["v3", "workspaces", _ws, "conclusions", id], _body, _q),
    do: Map.get(conclusions(), id) || {:status, 404}

  defp respond("DELETE", ["v3", "workspaces", _ws, "conclusions", id], _body, _q) do
    Agent.update(__MODULE__, &%{&1 | conclusions: Map.delete(&1.conclusions, id)})
    {:status, 204}
  end

  defp respond(_method, _segments, _body, _q), do: %{}

  defp representation(peer) do
    messages() |> Enum.filter(&(&1["peer_id"] == peer)) |> Enum.map_join("\n", & &1["content"])
  end

  defp card(peer), do: Agent.get(__MODULE__, &Map.get(&1.cards, peer))

  defp in_session(session_id), do: Enum.filter(messages(), &(&1["session_id"] == session_id))

  defp store(state, session_id, message) do
    stored =
      message
      |> Map.take(["content", "peer_id", "metadata"])
      |> Map.merge(%{
        "id" => "msg_#{state.next}",
        "session_id" => session_id,
        "created_at" => "2026-11-17T10:00:00Z"
      })

    %{state | messages: [stored | state.messages], next: state.next + 1}
  end
end

defmodule LemonHoncho.IsolationTest do
  @moduledoc """
  Cross-user and cross-profile isolation of Honcho memory, end to end through
  the session manager, the real HTTP client, the `honcho_search` tool and the
  memory provider against an in-memory Honcho.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonHoncho.{Config, SessionManager}
  alias LemonHoncho.IsolationTest.FakeHoncho
  alias LemonHoncho.Tools.Search
  alias LemonMemory.Document

  @moduletag :tmp_dir

  @os_env ~w(HONCHO_API_KEY HONCHO_BASE_URL LEMON_HONCHO_ENABLED LEMON_HONCHO_SESSION_STRATEGY
             LEMON_HONCHO_RECALL_MODE HONCHO_PEER HONCHO_AI_PEER HONCHO_WORKSPACE)
  @app_env [:enabled, :api_key, :base_url, :client, :req_options, :recall_mode, :user_peer]

  @alice_key "agent:demo:telegram:default:dm:111"
  @bob_key "agent:demo:telegram:default:dm:222"
  @alice %{channel_id: "telegram", sender_id: "111", is_bot: false, verified?: true}
  @bob %{channel_id: "telegram", sender_id: "222", is_bot: false, verified?: true}

  setup %{tmp_dir: tmp_dir} do
    saved_os = Map.new(@os_env, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_env, &{&1, Application.fetch_env(:lemon_honcho, &1)})
    Enum.each(@os_env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved_os, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(saved_app, fn
        {key, :error} -> Application.delete_env(:lemon_honcho, key)
        {key, {:ok, value}} -> Application.put_env(:lemon_honcho, key, value)
      end)
    end)

    stop_application_manager()
    start_supervised!({FakeHoncho, self()})

    Application.put_env(:lemon_honcho, :enabled, true)
    Application.put_env(:lemon_honcho, :api_key, "sk-isolation-test")
    Application.put_env(:lemon_honcho, :user_peer, "user")
    Application.delete_env(:lemon_honcho, :base_url)
    Application.put_env(:lemon_honcho, :client, LemonHoncho.Client)
    Application.put_env(:lemon_honcho, :req_options, plug: &FakeHoncho.plug/1, retry: false)

    start_supervised!(
      {SessionManager,
       config: %Config{
         api_key: "sk-isolation-test",
         user_peer: "user",
         ai_peer: "lemon",
         first_turn_wait_ms: 2_000
       },
       client: LemonHoncho.Client}
    )

    %{workspace: Path.join(tmp_dir, "demo/workspace")}
  end

  describe "session identity" do
    test "two profiles whose cwd basename is `workspace` never share a session or a summary",
         %{tmp_dir: tmp_dir} do
      alpha = request("agent:alpha:main", Path.join(tmp_dir, "profiles/alpha/workspace"))
      beta = request("agent:beta:main", Path.join(tmp_dir, "profiles/beta/workspace"))

      upload(alpha, "alpha private launch plan")
      assert SessionManager.context_for(alpha) =~ "alpha private launch plan"

      refute SessionManager.context_for(beta) =~ "alpha private launch plan"
      assert session_id(alpha) != session_id(beta)
      refute session_id(alpha) == "workspace"
    end

    test "two profiles in the very same directory are still separate", %{workspace: workspace} do
      alpha = request("agent:alpha:main", workspace)
      beta = request("agent:beta:main", workspace)

      upload(alpha, "alpha private launch plan")
      assert SessionManager.context_for(alpha) =~ "alpha private launch plan"

      refute SessionManager.context_for(beta) =~ "alpha private launch plan"
      assert session_id(alpha) != session_id(beta)
    end

    test "two channel senders of one profile never see each other's summary",
         %{workspace: workspace} do
      alice = request(@alice_key, workspace, @alice)
      bob = request(@bob_key, workspace, @bob)

      upload(alice, "alice medical appointment")
      assert SessionManager.context_for(alice) =~ "alice medical appointment"

      refute SessionManager.context_for(bob) =~ "alice medical appointment"
      assert session_id(alice) != session_id(bob)
    end

    test "names that differ only in punctuation do not share a session" do
      config = %Config{session_strategy: :per_session}

      refute LemonHoncho.SessionName.resolve(config, session_id: "a:b") ==
               LemonHoncho.SessionName.resolve(config, session_id: "a/b")
    end
  end

  describe "honcho_search" do
    test "an unmapped session says so and makes no workspace-wide request",
         %{workspace: workspace} do
      FakeHoncho.seed("workspace", %{"content" => "bob secret", "peer_id" => "telegram_222"})

      result = search(%{"query" => "secret"}, @alice_key, workspace, @alice)

      assert text(result) =~ "not mapped"
      refute text(result) =~ "bob secret"
      refute_received {:fake_honcho, "POST", ["v3", "workspaces", _ws, "search"], _body}

      refute_received {:fake_honcho, "POST", ["v3", "workspaces", _ws, "sessions", _, "search"],
                       _}
    end

    test "a tool without a session key never adopts another user's mapped session",
         %{workspace: workspace} do
      bob = request(@bob_key, workspace, @bob)
      upload(bob, "bob secret")
      SessionManager.context_for(bob)

      result = Search.execute("call", %{"query" => "secret"}, nil, nil, cwd: workspace)

      refute text(result) =~ "bob secret"
    end

    test "workspace scope returns only the requesting sender's own messages",
         %{workspace: workspace} do
      alice = request(@alice_key, workspace, @alice)
      bob = request(@bob_key, workspace, @bob)
      upload(alice, "alice note about lunch")
      upload(bob, "bob note about lunch")
      FakeHoncho.seed("legacy", %{"content" => "legacy note about lunch", "peer_id" => "owner"})

      result =
        search(%{"query" => "lunch", "scope" => "workspace"}, @alice_key, workspace, @alice)

      assert text(result) =~ "alice note about lunch"
      refute text(result) =~ "bob note about lunch"
      refute text(result) =~ "legacy note about lunch"

      assert_received {:fake_honcho, "POST", ["v3", "workspaces", _ws, "search"], body}
      assert is_map(body["filters"])
    end
  end

  describe "private memory contexts" do
    @private_a %{
      memory_context_key: "actor-a",
      invocation_context_key: "epoch-1",
      memory_context_verified: true
    }
    @private_b %{@private_a | memory_context_key: "actor-b"}

    test "a private run uploads to its own peer and session, never into legacy memory",
         %{workspace: workspace} do
      legacy = request("agent:demo:main", workspace)
      private_a = Map.merge(legacy, @private_a)
      private_b = Map.merge(legacy, @private_b)

      upload_run(legacy, @private_a, "actor-a private diagnosis")

      assert [%{"peer_id" => peer, "metadata" => metadata} | _] =
               Enum.filter(FakeHoncho.messages(), &(&1["content"] == "actor-a private diagnosis"))

      refute peer == owner_of(legacy).user_peer
      assert peer == owner_of(private_a).user_peer
      assert metadata == LemonHoncho.Owner.metadata(owner_of(private_a))

      assert SessionManager.context_for(private_a) =~ "actor-a private diagnosis"
      refute SessionManager.context_for(legacy) =~ "actor-a private diagnosis"
      refute SessionManager.context_for(private_b) =~ "actor-a private diagnosis"
      assert session_id(private_a) != session_id(legacy)
    end

    test "unproven or partial ownership is never uploaded, served or searched",
         %{workspace: workspace} do
      legacy = request("agent:demo:main", workspace)
      partial = Map.delete(@private_a, :invocation_context_key)
      unverified = %{@private_a | memory_context_verified: false}

      for claim <- [partial, unverified] do
        upload_run(legacy, claim, nil)
      end

      # Documents are handled in order, so once this one lands the two above
      # have been seen and dropped.
      upload_run(legacy, %{}, "legacy sentinel")

      refute Enum.any?(FakeHoncho.messages(), &(&1["content"] =~ "unsent"))

      for claim <- [partial, unverified] do
        flush_mailbox()
        assert SessionManager.context_for(Map.merge(legacy, claim)) == ""

        opts = [session_key: legacy.session_key, cwd: workspace] ++ Map.to_list(claim)
        result = Search.execute("call", %{"query" => "x", "scope" => "workspace"}, nil, nil, opts)

        assert text(result) =~ "not proven"
        refute_received {:fake_honcho, _method, _segments, _body}
      end
    end

    test "a channel conversation that does not name its sender never uses the owner's memory",
         %{workspace: workspace} do
      owner = request("agent:demo:main", workspace)
      upload(owner, "owner tax notes")
      assert SessionManager.context_for(owner) =~ "owner tax notes"

      # A subagent of a stranger's channel run carries the channel key but, by
      # design, no channel identity.
      stop_supervised!(SessionManager)

      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-isolation-test",
           user_peer: "user",
           ai_peer: "lemon",
           inject_in_subagents?: true,
           first_turn_wait_ms: 2_000
         },
         client: LemonHoncho.Client}
      )

      subagent = %{request(@bob_key <> ":sub:task1", workspace) | session_scope: :subagent}
      flush_mailbox()

      assert SessionManager.context_for(subagent) == ""
      refute_received {:fake_honcho, _method, _segments, _body}

      result =
        Search.execute("call", %{"query" => "tax", "scope" => "workspace"}, nil, nil,
          session_key: subagent.session_key,
          session_scope: :subagent,
          cwd: workspace
        )

      assert text(result) =~ "not proven"
      refute text(result) =~ "owner tax notes"
      refute_received {:fake_honcho, _method, _segments, _body}

      # Its finished run is not uploaded under the owner's peer either.
      upload_run(%{subagent | session_key: @bob_key}, %{}, nil)
      upload(owner, "owner sentinel")

      refute Enum.any?(FakeHoncho.messages(), &(&1["content"] =~ "unsent"))
    end
  end

  describe "peer-level memory (representations, cards, dialectic, conclusions)" do
    test "what the assistant told the operator never reaches a channel sender or a private context",
         %{workspace: workspace} do
      operator = request("agent:demo:main", workspace)
      alice = request(@alice_key, workspace, @alice)
      private = Map.merge(operator, @private_a)

      upload(operator, "operator question", "operator salary is 250k")
      assert SessionManager.context_for(operator) =~ "operator salary is 250k"
      assert text(reason(Map.to_list(operator), "ai")) =~ "operator salary is 250k"

      for other <- [alice, private] do
        refute SessionManager.context_for(other) =~ "operator salary"

        opts = Map.to_list(other)

        for target <- ["ai", "user"] do
          refute text(reason(opts, target)) =~ "operator salary"
        end

        context = LemonHoncho.Tools.Context.execute("call", %{}, nil, nil, opts)
        refute text(context) =~ "operator salary"
      end
    end

    test "two profiles of the same person never share a card or a conclusion",
         %{workspace: workspace} do
      alpha = [session_key: "agent:alpha:main", cwd: workspace]
      beta = [session_key: "agent:beta:main", cwd: workspace]

      profile(alpha, %{"card" => ["alpha-only fact"]})
      refute text(profile(beta, %{})) =~ "alpha-only fact"

      conclude(alpha, %{"conclusion" => "alpha-only conclusion"})
      refute text(conclude(beta, %{"query" => "conclusion"})) =~ "alpha-only conclusion"
      assert text(conclude(alpha, %{"query" => "conclusion"})) =~ "alpha-only conclusion"

      assert [{alpha_id, _}] = Enum.to_list(FakeHoncho.conclusions())
      result = conclude(beta, %{"delete_id" => alpha_id})

      assert text(result) =~ "nothing was deleted"
      assert Map.has_key?(FakeHoncho.conclusions(), alpha_id)
      refute_received {:fake_honcho, "DELETE", _segments, _body}

      assert text(conclude(alpha, %{"delete_id" => alpha_id})) =~ "Deleted"
      refute Map.has_key?(FakeHoncho.conclusions(), alpha_id)
    end

    test "a session key spelled like another owner's old cache key cannot reach its entry",
         %{workspace: workspace} do
      private = Map.merge(request("agent:demo:main", workspace), @private_a)
      upload_run(private, @private_a, "actor-a private diagnosis")
      assert SessionManager.context_for(private) =~ "actor-a private diagnosis"

      # Exactly the key the private entry used to be cached under:
      # `key <> ":honcho-memory:" <> sha256("private:" <> context_key)`.
      forged_key =
        "agent:demo:main:honcho-memory:" <>
          (:crypto.hash(:sha256, "private:actor-a") |> Base.encode16(case: :lower))

      forged = request(forged_key, workspace)

      refute SessionManager.context_for(forged) =~ "actor-a private diagnosis"
      refute cache_key(forged) == cache_key(private)
      refute session_id(forged) == session_id(private)

      upload(forged, "forged upload")

      refute SessionManager.context_for(private) =~ "forged upload"
    end

    test "records written before owner partitioning are never read", %{workspace: workspace} do
      # The pre-fix layout: bare `user`/`lemon` peers, a directory-named session,
      # untagged messages, a peer card and a conclusion on the bare peers.
      FakeHoncho.seed("workspace", %{"content" => "legacy user secret", "peer_id" => "user"})
      FakeHoncho.seed("workspace", %{"content" => "legacy reply secret", "peer_id" => "lemon"})
      FakeHoncho.seed_card("user", ["legacy card secret"])

      legacy_id =
        FakeHoncho.seed_conclusion(%{
          "observer_id" => "lemon",
          "observed_id" => "user",
          "content" => "legacy conclusion secret"
        })

      operator = request("agent:demo:main", workspace)
      opts = Map.to_list(operator)

      refute SessionManager.context_for(operator) =~ "legacy"
      refute text(profile(opts, %{})) =~ "legacy"
      refute text(conclude(opts, %{"query" => "what was concluded"})) =~ "legacy"
      refute text(search(%{"query" => "anything", "scope" => "workspace"}, operator)) =~ "legacy"

      assert text(conclude(opts, %{"delete_id" => legacy_id})) =~ "nothing was deleted"
      assert Map.has_key?(FakeHoncho.conclusions(), legacy_id)
    end
  end

  ## Helpers

  defp request(session_key, cwd, identity \\ nil) do
    %{
      cwd: cwd,
      session_key: session_key,
      session_scope: :main,
      channel_identity: identity,
      query: "what do you remember?"
    }
  end

  defp upload(request, text, answer \\ "noted") do
    SessionManager.sync_document(
      Document.new(
        session_key: request.session_key,
        agent_id: LemonCore.SessionKey.agent_id(request.session_key) || "default",
        workspace_key: request.cwd,
        prompt_summary: text,
        answer_summary: answer,
        meta: %{channel_identity: request.channel_identity}
      )
    )

    wait_until(fn -> Enum.any?(FakeHoncho.messages(), &(&1["content"] == text)) end)
  end

  defp owner_of(request) do
    {:ok, owner} = LemonHoncho.Owner.from_context(Config.load(), request)
    owner
  end

  defp profile(opts, params) do
    LemonHoncho.Tools.Profile.execute("call", params, nil, nil, opts)
  end

  defp reason(opts, target) do
    LemonHoncho.Tools.Reasoning.execute(
      "call",
      %{"query" => "what do you know?", "target" => target},
      nil,
      nil,
      opts
    )
  end

  defp conclude(opts, params) do
    LemonHoncho.Tools.Conclude.execute("call", params, nil, nil, opts)
  end

  # A finished run through the real ingest document builder, so ownership is
  # stamped by `LemonMemory.ContextScope.run_metadata/1` exactly as in production.
  defp upload_run(request, ownership, text) do
    SessionManager.sync_document(
      Document.from_run("run-#{System.unique_integer([:positive])}", %{}, %{
        session_key: request.session_key,
        agent_id: LemonCore.SessionKey.agent_id(request.session_key),
        cwd: request.cwd,
        prompt: text || "unsent #{inspect(ownership)}",
        completed: %{answer: "noted"},
        meta: ownership
      })
    )

    if text, do: wait_until(fn -> Enum.any?(FakeHoncho.messages(), &(&1["content"] == text)) end)
  end

  defp flush_mailbox do
    receive do
      {:fake_honcho, _, _, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp session_id(request) do
    SessionManager.context_for(request)
    {:ok, id} = SessionManager.honcho_session_id(cache_key(request))
    id
  end

  defp cache_key(request), do: SessionManager.cache_key(request, Config.load())

  defp search(params, session_key, cwd, identity) do
    Search.execute("call", params, nil, nil,
      session_key: session_key,
      cwd: cwd,
      channel_identity: identity
    )
  end

  defp search(params, request), do: Search.execute("call", params, nil, nil, Map.to_list(request))

  defp text(%AgentToolResult{content: content}), do: Enum.map_join(content, "", & &1.text)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
