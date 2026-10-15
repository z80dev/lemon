defmodule LemonControlPlane.Methods.NativeSessionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize

  alias LemonControlPlane.Methods.{
    Registry,
    SessionsFork,
    SessionsLabel,
    SessionsList,
    SessionsMetadataPatch,
    SessionsNavigate,
    SessionsRewind,
    SessionsTree
  }

  alias LemonCore.{RunStore, SessionKey, SessionLifecycle, SessionMetadataStore}

  defmodule Provider do
    @behaviour LemonCore.AgentRuntime.Provider

    @impl true
    def session_create(key, cwd) do
      send(self(), {:create, key, cwd})
      Process.get(:create_result)
    end

    @impl true
    def session_tree(key, cwd, opts) do
      send(self(), {:tree, key, cwd, opts})
      Process.get(:tree_result)
    end

    @impl true
    def session_navigate(key, cwd, entry, opts) do
      send(self(), {:navigate, key, cwd, entry, opts})
      mutation_result(:navigate_result, {:navigate, key, entry})
    end

    @impl true
    def session_label(key, cwd, entry, label) do
      send(self(), {:label, key, cwd, entry, label})
      mutation_result(:label_result, {:label, key, entry, label})
    end

    @impl true
    def session_rewind(key, cwd, entry, opts) do
      send(self(), {:rewind, key, cwd, entry, opts})
      mutation_result(:rewind_result, {:rewind, key, entry})
    end

    defp mutation_result(key, mutation) do
      case Process.get(key) do
        {:committed, failure} ->
          Process.put(:committed_mutation, mutation)

          case failure do
            :exit -> exit(:receipt_lost)
            :raise -> raise "receipt lost"
            :invalid -> :invalid_receipt
          end

        result ->
          result
      end
    end

    @impl true
    def session_fork(key, cwd, destination) do
      send(self(), {:fork, key, cwd, destination})
      Process.get(:fork_result, :ok)
    end

    @impl true
    def session_history(key, cwd) do
      send(self(), {:history, key, cwd})
      Process.get(:history_result, {:error, :session_not_found})
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Provider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    :ok
  end

  test "explicit creation validates identity and scope before returning a bound native receipt" do
    Process.put(
      :create_result,
      {:ok, %{"sessionId" => "native", "created" => true, "private" => "hidden"}}
    )

    assert {:ok,
            %{
              "sessionKey" => "agent:native_methods:main",
              "sessionId" => "native",
              "created" => true
            } = receipt} =
             Registry.dispatch("sessions.create", target(), ctx([:write]))

    assert_receive {:create, "agent:native_methods:main", "/workspace"}
    refute Map.has_key?(receipt, "private")
    assert {:error, _} = Registry.dispatch("sessions.create", target(), ctx([:read]))

    assert {:error, _} =
             Registry.dispatch(
               "sessions.create",
               Map.put(target(), "sessionKey", "legacy-unknown"),
               ctx([:write])
             )

    assert {:error, _} =
             Registry.dispatch("sessions.create", Map.delete(target(), "cwd"), ctx([:write]))

    refute_receive {:create, _, _}
  end

  test "registered tree delegates pagination and projects only native tree fields" do
    entry = %{
      "id" => "u1",
      "parentId" => nil,
      "type" => "message",
      "role" => "user",
      "text" => "hello",
      "timestamp" => 1,
      "isActive" => true,
      "isLeaf" => true,
      "rewindable" => true,
      "raw" => "private"
    }

    Process.put(
      :tree_result,
      {:ok,
       %{
         "sessionId" => "native",
         "leafId" => "u1",
         "entries" => [entry],
         "branches" => [%{"leafId" => "u1", "active" => true}],
         "totalEntries" => 1,
         "offset" => 0,
         "hasMore" => false,
         "private" => "hidden"
       }}
    )

    assert {:ok, tree} = Registry.dispatch("sessions.tree", target(), ctx([:read]))
    assert_receive {:tree, "agent:native_methods:main", "/workspace", [limit: 100, offset: 0]}
    assert tree["entries"] == [Map.delete(entry, "raw")]
    assert tree["sessionKey"] == target()["sessionKey"]
    refute Map.has_key?(tree, "private")
    assert tree["branches"] == [%{"leafId" => "u1", "active" => true}]

    assert {:ok, _} =
             SessionsTree.handle(Map.merge(target(), %{"limit" => 5, "offset" => 9}), %{})

    assert_receive {:tree, _, _, [limit: 5, offset: 9]}
  end

  test "tree and rewind reject unbounded or malformed parameters before delegation" do
    for {field, value} <- [
          {"sessionKey", String.duplicate("x", 1025)},
          {"cwd", ""},
          {"cwd", String.duplicate("x", 4097)},
          {"limit", 501},
          {"offset", -1}
        ] do
      assert {:error, {:invalid_params, _, nil}} =
               SessionsTree.handle(Map.put(target(), field, value), %{})
    end

    for {field, value} <- [
          {"entryId", String.duplicate("x", 257)},
          {"restoreFiles", "false"},
          {"allowPartialRestore", "yes"},
          {"dryRun", nil},
          {"confirmationToken", ""},
          {"confirmationToken", String.duplicate("x", 257)}
        ] do
      assert {:error, {:invalid_params, _, nil}} =
               SessionsRewind.handle(Map.put(rewind_target(), field, value), %{})
    end

    refute_received {:tree, _, _, _}
    refute_received {:rewind, _, _, _, _}
  end

  @tag :tmp_dir
  test "real stopped journal previews preserve media safety through the method boundary", %{
    tmp_dir: cwd
  } do
    alias CodingAgent.SessionManager
    Application.put_env(:lemon_core, :agent_runtime_provider, CodingAgent.ControlPlaneProvider)
    key = "agent:native_methods:media-#{LemonCore.Id.uuid()}"

    image = %{
      "type" => "image",
      "data" => Base.encode64("original bytes"),
      "mime_type" => "image/png"
    }

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(key)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    for {content, images, contains_non_text} <- [
          {"text-only prompt", [], false},
          {[%{"type" => "text", "text" => "same text"}, image], [], true},
          {"same text", [image], true},
          {[%{"type" => "text", "text" => "same text"}, %{"type" => "future_media"}], [], true}
        ] do
      target =
        SessionManager.new(cwd)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => content,
          "images" => images
        })

      full =
        SessionManager.append_message(target, %{"role" => "assistant", "content" => "failed"})

      path = CodingAgent.Session.Presentation.session_file_path(full.header.id, cwd)
      :ok = SessionManager.save_to_file(path, full)

      :ok =
        LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: full.header.id
        })

      params = %{"sessionKey" => key, "cwd" => cwd, "entryId" => target.leaf_id}
      before = File.read!(path)
      assert {:ok, preview} = SessionsRewind.handle(params, %{})
      assert preview["promptContainsNonText"] == contains_non_text
      assert File.read!(path) == before
      assert {:ok, resumed} = SessionManager.load_from_file(path)
      assert resumed.leaf_id == full.leaf_id

      assert SessionManager.get_entry(resumed, target.leaf_id).message == %{
               "role" => "user",
               "content" => content,
               "images" => images
             }

      if contains_non_text do
        changed =
          resumed
          |> Map.put(:file_path, path)
          |> SessionManager.append_message(%{"role" => "user", "content" => "later turn"})

        assert {:error, {:conflict, _, %{"reason" => "stale_confirmation"}}} =
                 SessionsRewind.handle(
                   Map.merge(params, %{
                     "dryRun" => false,
                     "confirmationToken" => preview["confirmationToken"]
                   }),
                   %{}
                 )

        assert {:ok, still_changed} = SessionManager.load_from_file(path)
        assert still_changed.leaf_id == changed.leaf_id
      else
        assert {:ok, result} =
                 SessionsRewind.handle(
                   Map.merge(params, %{
                     "dryRun" => false,
                     "confirmationToken" => preview["confirmationToken"]
                   }),
                   %{}
                 )

        assert result["prompt"] == content
        assert {:ok, rewound} = SessionManager.load_from_file(path)
        assert rewound.leaf_id == nil
      end

      LemonCore.Store.delete(:session_rewinds, full.header.id)
    end
  end

  test "rewind defaults to preview and requires a bounded confirmation for execution" do
    preview = %{
      "confirmationToken" => "preview-token",
      "prompt" => "edit this",
      "promptContainsNonText" => true,
      "discardedMessages" => 2,
      "restorePaths" => [],
      "unrestorableTools" => [],
      "entryId" => "u1",
      "sessionId" => "native"
    }

    Process.put(:rewind_result, {:ok, Map.put(preview, "private", "hidden")})

    preview = Map.put(preview, "sessionKey", target()["sessionKey"])
    assert {:ok, ^preview} = Registry.dispatch("sessions.rewind", rewind_target(), ctx([:write]))

    assert_receive {:rewind, _, _, "u1",
                    [
                      restore_files: false,
                      allow_partial_restore: false,
                      dry_run: true,
                      confirmation_token: nil
                    ]}

    execute = Map.put(rewind_target(), "dryRun", false)

    assert {:error, {:conflict, _, %{"reason" => "confirmation_required"}}} =
             SessionsRewind.handle(execute, %{})

    refute_received {:rewind, _, _, _, _}

    Process.put(:rewind_result, {:error, :stale_confirmation})

    assert {:error, {:conflict, _, %{"reason" => "stale_confirmation"}}} =
             SessionsRewind.handle(Map.put(execute, "confirmationToken", "stale"), %{})

    assert_receive {:rewind, _, _, "u1",
                    [
                      restore_files: false,
                      allow_partial_restore: false,
                      dry_run: false,
                      confirmation_token: "stale"
                    ]}

    result = %{
      "prompt" => "edit this",
      "leafId" => "previous",
      "restoredPaths" => ["a.txt"],
      "entryId" => "u1",
      "sessionId" => "native"
    }

    Process.put(:rewind_result, {:ok, result})
    result = Map.put(result, "sessionKey", target()["sessionKey"])

    assert {:ok, ^result} =
             SessionsRewind.handle(
               Map.merge(
                 execute,
                 %{"confirmationToken" => "preview-token", "restoreFiles" => true}
               ),
               %{}
             )

    assert_receive {:rewind, _, _, _,
                    [
                      restore_files: true,
                      allow_partial_restore: false,
                      dry_run: false,
                      confirmation_token: "preview-token"
                    ]}
  end

  test "partial file restore requires explicit valid intent and preserves the bound receipt" do
    assert {:error, {:invalid_params, _, _}} =
             SessionsRewind.handle(Map.put(rewind_target(), "allowPartialRestore", true), %{})

    receipt = %{
      "confirmationToken" => "partial-token",
      "sessionId" => "native",
      "entryId" => "u1",
      "prompt" => "edit this",
      "restoredPaths" => ["/workspace/file.ex"],
      "restoreFiles" => true,
      "allowPartialRestore" => true,
      "partialRestore" => true,
      "unrestorableTools" => ["bash"],
      "unrestorableCommands" => ["mix test test/file_test.exs"],
      "unrestorableCommandCount" => 1,
      "canAllowPartialRestore" => true
    }

    Process.put(:rewind_result, {:ok, receipt})

    params =
      Map.merge(rewind_target(), %{
        "dryRun" => false,
        "restoreFiles" => true,
        "allowPartialRestore" => true,
        "confirmationToken" => "partial-token"
      })

    assert {:ok, result} = SessionsRewind.handle(params, %{})
    assert Map.delete(result, "sessionKey") == receipt
    assert_receive {:rewind, _, _, _, opts}
    assert opts[:allow_partial_restore] == true
    assert opts[:restore_files] == true
    assert opts[:confirmation_token] == "partial-token"
  end

  test "read scope cannot mutate native sessions and errors never echo arbitrary reasons" do
    assert Authorize.required_scopes("sessions.tree") == [:read]
    assert Authorize.required_scopes("sessions.rewind") == [:write]
    assert Authorize.required_scopes("sessions.fork") == [:write]

    for {method, params} <- [{"sessions.rewind", rewind_target()}, {"sessions.fork", target()}] do
      assert {:error, {:forbidden, _}} = Registry.dispatch(method, params, ctx([:read]))
    end

    Process.put(:tree_result, {:error, {:file_error, "/private/token=secret"}})
    assert {:error, {:internal_error, _, nil}} = SessionsTree.handle(target(), %{})
    Process.put(:rewind_result, {:error, :checkpoint_scope_mismatch})

    assert {:error, {:conflict, _, %{"reason" => "checkpoint_scope_mismatch"}}} =
             SessionsRewind.handle(rewind_target(), %{})
  end

  test "fork creates an independent discoverable zero-run child supporting existing naming and search" do
    assert {:ok, %{"sessionKey" => child, "sourceSessionKey" => source}} =
             Registry.dispatch("sessions.fork", target(), ctx([:write]))

    on_exit(fn -> SessionLifecycle.delete(child) end)

    assert source == target()["sessionKey"]
    assert_receive {:fork, ^source, "/workspace", ^child}
    assert child != source
    assert SessionKey.valid?(child)
    assert SessionKey.agent_id(child) == "native_methods"
    assert SessionMetadataStore.fetch(child).title == nil
    assert RunStore.history(child) == []

    assert {:ok, listed} = SessionsList.handle(%{"query" => child}, %{})
    assert [%{"sessionKey" => ^child, "runCount" => 0}] = listed["sessions"]

    title = "Fork naming #{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, _} =
             SessionsMetadataPatch.handle(%{"sessionKey" => child, "title" => title}, %{})

    assert {:ok, named} = SessionsList.handle(%{"query" => String.upcase(title)}, %{})
    assert [%{"sessionKey" => ^child, "title" => ^title}] = named["sessions"]

    assert {:ok, _} = SessionsMetadataPatch.handle(%{"sessionKey" => child, "title" => nil}, %{})
    assert {:ok, cleared} = SessionsList.handle(%{"query" => title}, %{})
    assert cleared["sessions"] == []
  end

  test "plain TUI session keys fork with their durable source agent identity" do
    source = "tui-#{System.unique_integer([:positive])}"
    assert :ok = RunStore.create_session_index(source, "native_methods", :tui)
    on_exit(fn -> SessionLifecycle.delete(source) end)

    assert {:ok, %{"sessionKey" => child, "sourceSessionKey" => ^source}} =
             SessionsFork.handle(Map.put(target(), "sessionKey", source), %{})

    on_exit(fn -> SessionLifecycle.delete(child) end)
    assert_receive {:fork, ^source, "/workspace", ^child}
    assert SessionKey.agent_id(child) == "native_methods"
    assert SessionLifecycle.get(child).agent_id == "native_methods"
  end

  test "unknown plain keys do not fork under a guessed default agent" do
    assert {:error, {:not_found, _, %{"reason" => "session_not_found"}}} =
             SessionsFork.handle(Map.put(target(), "sessionKey", "tui-unknown-source"), %{})

    refute_received {:fork, _, _, _}
  end

  test "uncertain forks retain their generated identity and disallow automatic retries" do
    Process.put(:fork_result, {:error, :outcome_unknown})

    assert {:error, {:unavailable, _, %{"sessionKey" => child, "retrySafe" => false}}} =
             SessionsFork.handle(target(), %{})

    assert_receive {:fork, _, _, ^child}
    assert SessionKey.valid?(child)
    assert SessionLifecycle.get(child) == nil
  end

  test "navigate needs write scope, validates input and maps runtime refusals" do
    assert {:error, {:forbidden, _}} =
             Registry.dispatch("sessions.navigate", navigate_target(), ctx([:read]))

    receipt = %{
      "sessionId" => "native",
      "entryId" => "e2",
      "leafId" => "e1",
      "prompt" => "edit me",
      "summarizing" => false
    }

    Process.put(:navigate_result, {:ok, Map.put(receipt, "private", "hidden")})

    assert {:ok, result} =
             Registry.dispatch("sessions.navigate", navigate_target(), ctx([:write]))

    assert result == Map.put(receipt, "sessionKey", target()["sessionKey"])
    assert_receive {:navigate, _, _, "e2", _}

    for params <- [
          Map.put(navigate_target(), "entryId", ""),
          Map.put(navigate_target(), "entryId", String.duplicate("x", 257)),
          Map.put(navigate_target(), "summarize", "yes"),
          Map.delete(navigate_target(), "entryId")
        ] do
      assert {:error, {:invalid_params, _, nil}} = SessionsNavigate.handle(params, %{})
    end

    refute_received {:navigate, _, _, _, _}

    Process.put(:navigate_result, {:error, :busy})

    assert {:error, {:conflict, _, %{"reason" => "busy"}}} =
             SessionsNavigate.handle(navigate_target(), %{})

    Process.put(:navigate_result, {:error, :entry_not_found})

    assert {:error, {:not_found, _, %{"reason" => "entry_not_found"}}} =
             SessionsNavigate.handle(navigate_target(), %{})

    Process.put(:navigate_result, {:error, {:file_error, "/private/secret"}})
    assert {:error, {:internal_error, _, nil}} = SessionsNavigate.handle(navigate_target(), %{})
  end

  test "label needs write scope, sanitizes and bounds text, and clears on empty" do
    assert {:error, {:forbidden, _}} =
             Registry.dispatch("sessions.label", label_target("x"), ctx([:read]))

    Process.put(:label_result, {:ok, %{"sessionId" => "native", "entryId" => "e2"}})
    assert {:ok, _} = SessionsLabel.handle(label_target("  keep\u0000\n this\tone \u202E "), %{})
    assert_receive {:label, _, "/workspace", "e2", "keep this one"}

    for cleared <- [nil, "", "   ", "\n\t"] do
      assert {:ok, _} = SessionsLabel.handle(label_target(cleared), %{})
      assert_receive {:label, _, _, "e2", nil}
    end

    for bad <- [String.duplicate("x", 121), 7, %{}, <<255>>] do
      assert {:error, {:invalid_params, _, nil}} = SessionsLabel.handle(label_target(bad), %{})
    end

    assert {:error, {:invalid_params, _, nil}} =
             SessionsLabel.handle(Map.delete(label_target("x"), "label"), %{})

    refute_received {:label, _, _, _, _}

    Process.put(:label_result, {:error, :entry_not_found})

    assert {:error, {:not_found, _, %{"reason" => "entry_not_found"}}} =
             SessionsLabel.handle(label_target("x"), %{})
  end

  test "lost or invalid navigate and label receipts are uncertain after a committed mutation" do
    for failure <- [:exit, :raise, :invalid] do
      Process.put(:navigate_result, {:committed, failure})

      assert {:error, {:unavailable, _, %{"reason" => "outcome_unknown", "retrySafe" => false}}} =
               SessionsNavigate.handle(navigate_target(), %{})

      assert Process.get(:committed_mutation) ==
               {:navigate, target()["sessionKey"], "e2"}

      Process.put(:label_result, {:committed, failure})

      assert {:error, {:unavailable, _, %{"reason" => "outcome_unknown", "retrySafe" => false}}} =
               SessionsLabel.handle(label_target("accepted label"), %{})

      assert Process.get(:committed_mutation) ==
               {:label, target()["sessionKey"], "e2", "accepted label"}
    end
  end

  test "lost confirmed rewind receipts are uncertain while preview failures remain definite" do
    Process.put(:rewind_result, {:committed, :exit})
    params = target() |> Map.put("entryId", "e2") |> Map.put("dryRun", false)
    params = Map.put(params, "confirmationToken", "confirmed")

    assert {:error, {:unavailable, _, %{"reason" => "outcome_unknown", "retrySafe" => false}}} =
             SessionsRewind.handle(params, %{})

    assert Process.get(:committed_mutation) == {:rewind, target()["sessionKey"], "e2"}

    assert {:error, {:unavailable, _, %{"reason" => "unavailable"} = data}} =
             SessionsRewind.handle(Map.put(params, "dryRun", true), %{})

    refute Map.has_key?(data, "retrySafe")
  end

  test "native history is authoritative after rewind, including an empty active branch" do
    key = "agent:history_rewind_#{System.unique_integer([:positive])}:main"
    params = Map.put(target(), "sessionKey", key)
    on_exit(fn -> SessionLifecycle.delete(key) end)

    assert :ok =
             RunStore.finalize("history-run-#{key}", %{
               session_key: key,
               agent_id: SessionKey.agent_id(key),
               origin: :control_plane,
               prompt: "abandoned prompt",
               completed: %{ok: true, answer: "abandoned answer"}
             })

    assert eventually(fn -> RunStore.history(key, limit: 1) != [] end)

    entries = [
      %{type: :model_change, id: "model", timestamp: 1},
      %{
        type: :message,
        id: "u1",
        timestamp: 2,
        message: %{"role" => "user", "content" => "retained prompt"}
      },
      %{
        type: :message,
        id: "a1",
        timestamp: 3,
        message: %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "private thought"},
            %{"type" => "text", "text" => "retained answer"},
            %{
              "type" => "tool_call",
              "id" => "read-1",
              "name" => "read",
              "arguments" => %{"path" => "README.md"}
            }
          ]
        }
      },
      %{
        type: :message,
        id: "tool",
        timestamp: 4,
        message: %{
          "role" => "tool_result",
          "tool_call_id" => "read-1",
          "tool_name" => "read",
          "content" => [%{"type" => "text", "text" => "retained tool output"}],
          "is_error" => false
        }
      }
    ]

    Process.put(:history_result, {:ok, entries})
    assert {:ok, before_rewind} = Registry.dispatch("chat.history", params, ctx([:read]))

    assert [
             %{"id" => "u1", "content" => "retained prompt"},
             %{"id" => "a1", "content" => "retained answer"},
             %{"role" => "tool_use", "toolCallId" => "read-1"} = call,
             %{
               "id" => "tool",
               "role" => "tool_result",
               "toolCallId" => "read-1",
               "content" => "retained tool output"
             } = result
           ] = before_rewind["messages"]

    assert call["arguments"] == %{"path" => "README.md"}
    assert result["arguments"] == call["arguments"]

    refute inspect(before_rewind) =~ "private"
    refute inspect(before_rewind) =~ "abandoned"
    assert_receive {:history, ^key, "/workspace"}

    assert {:ok, page} =
             Registry.dispatch("chat.history", Map.put(params, "limit", 1), ctx([:read]))

    assert [%{"id" => "tool", "timestampMs" => 4, "toolCallId" => "read-1"}] = page["messages"]

    assert {:ok, after_user} =
             Registry.dispatch("chat.history", Map.put(params, "beforeId", "u1"), ctx([:read]))

    assert Enum.map(after_user["messages"], & &1["role"]) ==
             ["assistant", "tool_use", "tool_result"]

    Process.put(
      :rewind_result,
      {:ok,
       %{
         "prompt" => "retained prompt",
         "leafId" => nil,
         "restoredPaths" => [],
         "entryId" => "u1",
         "sessionId" => "native"
       }}
    )

    assert {:ok, _} =
             SessionsRewind.handle(
               Map.merge(
                 params,
                 %{"entryId" => "u1", "dryRun" => false, "confirmationToken" => "valid"}
               ),
               %{}
             )

    Process.put(:history_result, {:ok, []})
    assert {:ok, rewound} = Registry.dispatch("chat.history", params, ctx([:read]))
    assert rewound["messages"] == []

    Process.put(:history_result, {:error, :session_store_unavailable})

    assert {:error, {:unavailable, _, _}} =
             Registry.dispatch("chat.history", params, ctx([:read]))

    Process.put(:history_result, {:error, :session_not_found})
    assert {:ok, legacy} = Registry.dispatch("chat.history", params, ctx([:read]))
    assert Enum.any?(legacy["messages"], &(&1["content"] == "abandoned prompt"))
  end

  test "native history previews redact text without exposing thought or tool blocks" do
    content = "api_key=history-secret " <> String.duplicate("x", 600)

    Process.put(
      :history_result,
      {:ok,
       [
         %{
           type: :message,
           id: "u",
           timestamp: 1,
           message: %{"role" => "user", "content" => content}
         }
       ]}
    )

    assert {:ok, history} =
             Registry.dispatch(
               "chat.history",
               Map.put(target(), "includeFullText", false),
               ctx([:read])
             )

    assert [%{"truncated" => true, "content" => preview}] = history["messages"]
    refute preview =~ "history-secret"
    assert String.length(preview) <= 503
  end

  defp eventually(fun, attempts \\ 300)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp target, do: %{"sessionKey" => "agent:native_methods:main", "cwd" => "/workspace"}
  defp rewind_target, do: Map.put(target(), "entryId", "u1")
  defp navigate_target, do: Map.put(target(), "entryId", "e2")

  defp label_target(label),
    do: target() |> Map.put("entryId", "e2") |> Map.put("label", label)

  defp ctx(scopes), do: %{auth: %{role: :operator, scopes: scopes}}
end
