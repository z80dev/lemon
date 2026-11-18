defmodule LemonControlPlane.Methods.ContentScopeAgentsTest do
  @moduledoc """
  `operator.read` is metadata-only for omp sessions, profile memory, named
  agent messages, the agent directory and the learning timeline. Titles,
  transcripts, todo text, memory bodies, labels and answers need
  `operator.content`.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    AgentIdentityRegister,
    AgentMessageComplete,
    AgentMessageSend,
    MemoryAdd,
    Registry
  }

  alias LemonCore.{NodeRegistry, ProfileStore, Store}

  @prose "The merger closes Friday at 41 dollars per share"
  @unlabelled "PROMPT_SECRET_7Q2X9"
  @content "#{@prose}; reference #{@unlabelled}"

  @read %{role: :operator, scopes: [:read]}
  @content_auth %{role: :operator, scopes: [:read, :content]}

  @fake_omp Path.expand("../../support/fake_omp", __DIR__)
  @omp_env_keys [:executable, :agent_dir, :command_timeout_ms, :ready_timeout_ms]

  defp ctx(auth, extra \\ %{}),
    do: Map.merge(%{auth: auth, conn_id: "content-agents", conn_pid: self()}, extra)

  defp refute_content(result) do
    encoded = inspect(result) <> Jason.encode!(elem(result, 1))
    refute encoded =~ @prose
    refute encoded =~ @unlabelled
  end

  describe "omp sessions" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      workspace = Path.join(root, "workspace")
      agent_dir = Path.join(root, "agent")
      File.mkdir_p!(workspace)
      File.mkdir_p!(agent_dir)

      previous_app = Map.new(@omp_env_keys, &{&1, Application.get_env(:lemon_omp, &1)})
      previous_bin = System.get_env("LEMON_OMP_BIN")
      System.delete_env("LEMON_OMP_BIN")
      Application.put_env(:lemon_omp, :executable, @fake_omp)
      Application.put_env(:lemon_omp, :agent_dir, agent_dir)
      Application.put_env(:lemon_omp, :command_timeout_ms, 2_000)
      Application.put_env(:lemon_omp, :ready_timeout_ms, 5_000)

      on_exit(fn ->
        for session <- LemonOmp.list(include_ended: false, limit: 100),
            do: LemonOmp.close(session["id"])

        Enum.each(previous_app, fn
          {key, nil} -> Application.delete_env(:lemon_omp, key)
          {key, value} -> Application.put_env(:lemon_omp, key, value)
        end)

        if previous_bin, do: System.put_env("LEMON_OMP_BIN", previous_bin)
      end)

      {:ok, workspace: workspace, agent_dir: agent_dir}
    end

    test "list, get, subagent and discover withhold titles, text and transcripts",
         %{workspace: workspace, agent_dir: agent_dir} do
      write = ctx(%{role: :operator, scopes: [:write]})

      assert {:ok, %{"session" => %{"id" => id}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "HOLD #{@content}", "cwd" => workspace},
                 write
               )

      assert {:ok, %{"session" => %{"id" => ^id}}} =
               Registry.dispatch("omp.sessions.get", %{"id" => id}, ctx(@content_auth))

      read = ctx(@read)

      assert {:ok, _} = list = Registry.dispatch("omp.sessions.list", %{}, read)
      refute_content(list)
      assert {:ok, %{"sessions" => sessions, "contentWithheld" => true}} = list
      session = Enum.find(sessions, &(&1["id"] == id))
      assert session["cwd"] == workspace
      assert is_binary(session["status"])
      assert is_map(session["usage"])
      assert session["title"] == nil

      assert {:ok, _} = get = Registry.dispatch("omp.sessions.get", %{"id" => id}, read)
      refute_content(get)

      assert {:ok,
              %{
                "session" => %{"id" => ^id, "cwd" => ^workspace},
                "summary" => nil,
                "contentWithheld" => true
              }} = get

      assert {:ok, _} =
               sub =
               Registry.dispatch(
                 "omp.sessions.subagent",
                 %{"id" => id, "subagentId" => "child"},
                 read
               )

      refute inspect(sub) =~ "child done"

      assert {:ok,
              %{
                "contentWithheld" => true,
                "transcript" => %{"nextByte" => 42, "messages" => [%{"role" => "assistant"}]}
              }} = sub

      assert {:ok, _} =
               full =
               Registry.dispatch("omp.sessions.get", %{"id" => id}, ctx(@content_auth))

      assert full |> elem(1) |> get_in(["session", "title"]) =~ @unlabelled
      assert {:ok, %{"contentWithheld" => false, "summary" => summary}} = full
      assert summary =~ @unlabelled

      assert {:ok, %{"transcript" => %{"messages" => [%{"text" => "child done"}]}}} =
               Registry.dispatch(
                 "omp.sessions.subagent",
                 %{"id" => id, "subagentId" => "child"},
                 ctx(@content_auth)
               )

      omp_id = "01a137c9-4e60-73f4-a776-ece03008a9fe"
      write_session_file(agent_dir, workspace, omp_id)

      assert {:ok, _} =
               discovered =
               Registry.dispatch("omp.sessions.discover", %{"cwd" => workspace}, read)

      refute_content(discovered)

      assert {:ok,
              %{
                "sessions" => [%{"ompSessionId" => ^omp_id, "cwd" => ^workspace}],
                "contentWithheld" => true
              }} = discovered

      assert {:ok, %{"sessions" => [%{"title" => title}], "contentWithheld" => false}} =
               Registry.dispatch(
                 "omp.sessions.discover",
                 %{"cwd" => workspace},
                 ctx(@content_auth)
               )

      assert title =~ @unlabelled
    end
  end

  describe "profile memory" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      state = Path.join(tmp_dir, "state")
      File.mkdir_p!(state)
      previous_paths = Application.get_env(:lemon_core, :paths)

      Application.put_env(:lemon_core, :paths,
        home_state_dir: state,
        global_config: Path.join(state, "config.toml")
      )

      store = String.to_atom("content_scope_memory_#{System.unique_integer([:positive])}")
      start_supervised!({LemonMemory.Store, name: store, path: Path.join(tmp_dir, "memory")})
      if Process.whereis(NodeRegistry) == nil, do: start_supervised!(NodeRegistry)

      on_exit(fn ->
        if previous_paths,
          do: Application.put_env(:lemon_core, :paths, previous_paths),
          else: Application.delete_env(:lemon_core, :paths)
      end)

      {:ok, _} = ProfileStore.create(%{"id" => "memory-content"})
      {:ok, extra: %{memory_opts: [store: store]}}
    end

    test "list, get and search withhold memory bodies", %{extra: extra} do
      admin = ctx(%{role: :operator, scopes: [:admin, :content]}, extra)

      assert {:ok, %{"item" => %{"id" => id}}} =
               MemoryAdd.handle(%{"profileId" => "memory-content", "text" => @content}, admin)

      read = ctx(@read, extra)
      full = ctx(@content_auth, extra)
      base = %{"profileId" => "memory-content"}

      assert {:ok, _} = list = Registry.dispatch("memory.list", base, read)
      refute_content(list)

      assert {:ok,
              %{
                "items" => [%{"id" => ^id, "kind" => "memory", "textBytes" => bytes} = item],
                "contentWithheld" => true
              }} = list

      assert bytes > 0
      refute Map.has_key?(item, "text")

      assert {:ok, _} = get = Registry.dispatch("memory.get", Map.put(base, "id", id), read)
      refute_content(get)
      assert {:ok, %{"item" => %{"id" => ^id}, "contentWithheld" => true}} = get

      search = Map.put(base, "query", "merger")
      assert {:ok, _} = searched = Registry.dispatch("memory.search", search, read)
      refute_content(searched)
      assert {:ok, %{"items" => [], "contentWithheld" => true}} = searched

      assert {:ok, %{"items" => [%{"text" => text}], "contentWithheld" => false}} =
               Registry.dispatch("memory.list", base, full)

      assert text =~ @unlabelled

      assert {:ok, %{"item" => %{"text" => _}}} =
               Registry.dispatch("memory.get", Map.put(base, "id", id), full)

      assert {:ok, %{"items" => [%{"id" => ^id}]}} =
               Registry.dispatch("memory.search", search, full)
    end
  end

  describe "named agents" do
    test "identity labels and message answers need content" do
      tag = Integer.to_string(System.unique_integer([:positive]))
      scope = "bot:content-test:#{tag}"
      source = "bot://content-test/source-#{tag}"
      target = "bot://content-test/target-#{tag}"
      target_pid = spawn(fn -> Process.sleep(:infinity) end)
      admin = fn pid -> %{auth: %{role: :operator, scopes: [:admin]}, conn_pid: pid} end

      on_exit(fn ->
        Process.exit(target_pid, :kill)
        LemonCore.AgentIdentity.remove(scope, source)
        LemonCore.AgentIdentity.remove(scope, target)
      end)

      for {id, pid, name} <- [{source, self(), "alice#{tag}"}, {target, target_pid, "bob#{tag}"}] do
        assert {:ok, _} =
                 AgentIdentityRegister.handle(
                   %{
                     "scope" => scope,
                     "id" => id,
                     "name" => name,
                     "label" => @content,
                     "metadata" => %{"botId" => name}
                   },
                   admin.(pid)
                 )
      end

      message_id = "content-#{tag}"

      assert {:ok, %{"status" => "accepted"}} =
               AgentMessageSend.handle(
                 %{
                   "scope" => scope,
                   "sourceId" => source,
                   "target" => "@bob#{tag}",
                   "text" => "question",
                   "messageId" => message_id
                 },
                 admin.(self())
               )

      assert {:ok, _} =
               AgentMessageComplete.handle(
                 %{"messageId" => message_id, "status" => "completed", "response" => @content},
                 admin.(target_pid)
               )

      # Private scopes need admin; admin alone still lacks content.
      read = ctx(%{role: :operator, scopes: [:read, :admin]})
      full = ctx(%{role: :operator, scopes: [:read, :admin, :content]})
      get = %{"scope" => scope, "sourceId" => source, "messageId" => message_id}

      assert {:ok, _} =
               listed = Registry.dispatch("agent.identity.list", %{"scope" => scope}, read)

      refute_content(listed)
      assert {:ok, %{"agents" => [_, _] = agents, "contentWithheld" => true}} = listed
      assert Enum.all?(agents, &(is_binary(&1["id"]) and is_binary(&1["name"])))

      assert {:ok, _} = message = Registry.dispatch("agent.message.get", get, read)
      refute_content(message)

      assert {:ok,
              %{"messageId" => ^message_id, "status" => "completed", "contentWithheld" => true}} =
               message

      assert {:ok, %{"agents" => [%{"label" => @content} | _], "contentWithheld" => false}} =
               Registry.dispatch("agent.identity.list", %{"scope" => scope}, full)

      assert {:ok, %{"response" => @content, "contentWithheld" => false}} =
               Registry.dispatch("agent.message.get", get, full)
    end
  end

  describe "agent directory" do
    test "read-only callers get session identity metadata and contentWithheld" do
      agent_id = "content_dir_#{System.unique_integer([:positive])}"

      session_key =
        LemonCore.SessionKey.channel_peer(%{
          agent_id: agent_id,
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "4455"
        })

      :ok =
        Store.put(:sessions_index, session_key, %{
          session_key: session_key,
          agent_id: agent_id,
          origin: :channel,
          run_count: 1,
          peer_label: "Ops room",
          topic_name: "Deploys",
          created_at_ms: 1_000,
          updated_at_ms: 2_000
        })

      on_exit(fn -> Store.delete(:sessions_index, session_key) end)
      params = %{"agentId" => agent_id, "includeSessions" => true}

      for method <- ["agent.directory.list", "agents.list"] do
        assert {:ok, _} = result = Registry.dispatch(method, params, ctx(@read))
        refute_content(result)
        assert {:ok, %{"contentWithheld" => true}} = result

        assert {:ok, %{"contentWithheld" => false}} =
                 Registry.dispatch(method, params, ctx(@content_auth))
      end

      assert {:ok, %{"sessions" => [session]}} =
               Registry.dispatch("agent.directory.list", params, ctx(@read))

      assert session["sessionKey"] == session_key
      assert session["runCount"] == 1
      # Peer labels and topic names identify sessions, as in sessions.list.
      assert session["peerLabel"] == "Ops room"
      assert session["topicName"] == "Deploys"
    end
  end

  describe "learning timeline" do
    setup do
      previous = Application.fetch_env(:lemon_control_plane, :learning_timeline_fun)

      Application.put_env(:lemon_control_plane, :learning_timeline_fun, fn _profile, _opts ->
        {:ok,
         %{
           "items" => [
             %{
               "at" => 10,
               "kind" => "memory",
               "action" => "added",
               "id" => "mem-1",
               "title" => String.slice(@content, 0, 80),
               "preview" => @content
             }
           ],
           "limit" => 50,
           "history" => "current_state"
         }}
      end)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:lemon_control_plane, :learning_timeline_fun, value)
          :error -> Application.delete_env(:lemon_control_plane, :learning_timeline_fun)
        end
      end)
    end

    test "titles and previews need content" do
      assert {:ok, _} = result = Registry.dispatch("learning.timeline", %{}, ctx(@read))
      refute_content(result)

      assert {:ok,
              %{
                "items" => [
                  %{"id" => "mem-1", "kind" => "memory", "action" => "added", "at" => 10}
                ],
                "limit" => 50,
                "history" => "current_state",
                "contentWithheld" => true
              }} = result

      assert {:ok, %{"items" => [%{"preview" => @content}], "contentWithheld" => false}} =
               Registry.dispatch("learning.timeline", %{}, ctx(@content_auth))
    end
  end

  defp write_session_file(agent_dir, cwd, omp_session_id) do
    encoded = "--" <> (cwd |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    dir = Path.join([agent_dir, "sessions", encoded])
    File.mkdir_p!(dir)

    lines = [
      %{"type" => "title", "v" => 1, "title" => @content},
      %{
        "type" => "session",
        "id" => omp_session_id,
        "cwd" => cwd,
        "timestamp" => "2026-10-13T00:00:00.000Z"
      },
      %{
        "type" => "message",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => @content}]}
      }
    ]

    File.write!(
      Path.join(dir, "2026-10-13T00-00-00-000Z_#{omp_session_id}.jsonl"),
      Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    )
  end
end
