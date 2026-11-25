defmodule LemonControlPlane.Methods.SessionsCompactTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SessionsCompact

  defmodule RecordingProvider do
    def compact_session(key, opts) do
      send(self(), {:compact_request, key, opts})

      case Process.get(:compaction_result, :ok) do
        {:raise, exception} -> raise exception
        result -> result
      end
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, RecordingProvider)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :agent_runtime_provider)
      else
        Application.put_env(:lemon_core, :agent_runtime_provider, original)
      end
    end)

    :ok
  end

  test "forwards cwd and focus, forces explicit manual compaction, and returns a redacted receipt" do
    focus = "Keep src/review.ex, failing tests, and the exact next step"

    assert {:ok, receipt} =
             SessionsCompact.handle(
               %{
                 "sessionKey" => "compact-focus",
                 "cwd" => "/workspace/private",
                 "focus" => focus
               },
               %{}
             )

    assert_received {:compact_request, "compact-focus", opts}
    assert opts[:cwd] == "/workspace/private"
    assert opts[:custom_instructions] == focus
    assert opts[:force] == true
    refute Keyword.has_key?(opts, :summary)
    assert receipt["success"] == true
    assert receipt["summary"]["force"] == true
    assert receipt["summary"]["focusProvided"] == true
    assert receipt["summary"]["customSummaryProvided"] == false
    assert receipt["tokensBefore"] == nil
    assert receipt["tokensAfter"] == nil
    refute receipt["summary"]["tokensBeforeReturned"]
    refute receipt["summary"]["tokensAfterReturned"]
    refute inspect(receipt) =~ focus
    refute inspect(receipt) =~ "/workspace/private"
  end

  test "keeps explicit force false and supplied summary distinct from focus" do
    summary = "## Durable context\nPrivate chosen design"

    assert {:ok, receipt} =
             SessionsCompact.handle(
               %{
                 "sessionKey" => "compact-summary",
                 "force" => false,
                 "summary" => summary,
                 "focus" => "Preserve failures"
               },
               %{}
             )

    assert_received {:compact_request, "compact-summary", opts}
    assert opts[:force] == false
    assert opts[:summary] == summary
    assert opts[:custom_instructions] == "Preserve failures"
    refute Keyword.has_key?(opts, :cwd)
    assert receipt["summary"]["customSummaryProvided"]
    refute receipt["summary"]["force"]
    refute inspect(receipt) =~ summary
  end

  test "rejects malformed and oversized parameters before invoking native compaction" do
    for params <- [nil, [], "compact"] do
      assert {:error, {:invalid_params, _, nil}} = SessionsCompact.handle(params, %{})
    end

    for {field, values} <- [
          {"sessionKey", [nil, "", " ", 1, <<255>>, "key\0", String.duplicate("k", 1025)]},
          {"cwd", [nil, "", " ", [], <<255>>, "/tmp\0", String.duplicate("p", 4097)]},
          {"focus", [nil, "", %{}, <<255>>, "focus\0", String.duplicate("f", 16_385)]},
          {"summary", [nil, "", false, <<255>>, "summary\0", String.duplicate("s", 131_073)]},
          {"force", [nil, 0, "true", []]}
        ],
        value <- values do
      params = Map.put(%{"sessionKey" => "compact-invalid"}, field, value)
      assert {:error, {:invalid_params, _, nil}} = SessionsCompact.handle(params, %{})
      refute_received {:compact_request, _, _}
    end
  end

  test "accepts the documented byte bounds without trimming summary content" do
    params = %{
      "sessionKey" => String.duplicate("k", 1024),
      "cwd" => "/" <> String.duplicate("p", 4095),
      "focus" => String.duplicate("f", 16_384),
      "summary" => String.duplicate("s", 131_071) <> "\n"
    }

    assert {:ok, _} = SessionsCompact.handle(params, %{})
    assert_received {:compact_request, key, opts}
    assert key == params["sessionKey"]
    assert opts[:cwd] == params["cwd"]
    assert opts[:custom_instructions] == params["focus"]
    assert opts[:summary] == params["summary"]
  end

  test "classifies native refusals and never leaks arbitrary runtime results or exceptions" do
    for {reason, code} <- [
          session_not_found: :not_found,
          busy: :conflict
        ] do
      Process.put(:compaction_result, {:error, reason})
      assert {:error, {^code, _, _}} = SessionsCompact.handle(%{"sessionKey" => "compact"}, %{})
    end

    for reason <- [:unavailable, :session_registry_not_available] do
      Process.put(:compaction_result, {:error, reason})

      assert SessionsCompact.handle(%{"sessionKey" => "compact"}, %{}) ==
               {:error,
                {:unavailable, "Native session runtime unavailable", %{"reason" => "unavailable"}}}
    end

    for result <- [
          {:error, {:provider_failure, "Bearer PRIVATE_TOKEN", "/secret/summary"}},
          {:error, RuntimeError.exception("private exception and summary")}
        ] do
      Process.put(:compaction_result, result)

      assert {:error, {:internal_error, "Native session operation failed", nil}} =
               SessionsCompact.handle(%{"sessionKey" => "compact"}, %{})
    end

    for result <- [
          {:ok, %{summary: "PRIVATE_SUMMARY", tokens_before: "PRIVATE_TOKEN"}},
          "unexpected private return",
          {:raise, RuntimeError.exception("private raised exception")}
        ] do
      Process.put(:compaction_result, result)

      assert SessionsCompact.handle(%{"sessionKey" => "compact"}, %{}) ==
               {:error,
                {:unavailable,
                 "Native session mutation outcome is unknown; reconcile before retrying",
                 %{"reason" => "outcome_unknown", "retrySafe" => false}}}
    end
  end

  test "compacts a stopped durable native session using cwd and the real :ok return contract" do
    alias CodingAgent.SessionManager

    Application.put_env(
      :lemon_core,
      :agent_runtime_provider,
      CodingAgent.ControlPlaneProvider
    )

    cwd = Path.join(System.tmp_dir!(), "compact-rpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    key = "compact-durable-#{LemonCore.Id.uuid()}"

    session =
      SessionManager.new(cwd)
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.model_change("openai-codex", "gpt-6.1-sol")
      )
      |> SessionManager.append_message(%{
        "role" => "user",
        "content" => "Keep exact revision approval"
      })
      |> SessionManager.append_message(%{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Changes made; tests not run"}]
      })
      |> SessionManager.append_message(%{
        "role" => "user",
        "content" => "Continue with pending tests"
      })

    path = CodingAgent.Session.Presentation.session_file_path(session.header.id, cwd)
    :ok = SessionManager.save_to_file(path, session)

    :ok =
      LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: session.header.id
      })

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(key)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
      File.rm_rf!(cwd)
    end)

    summary = "Keep exact revision approval. TODO run pending tests; no pass observed."

    assert {:ok, receipt} =
             SessionsCompact.handle(
               %{"sessionKey" => key, "cwd" => cwd, "summary" => summary},
               %{}
             )

    assert receipt["success"]
    assert receipt["summary"]["force"]
    assert {:ok, compacted} = SessionManager.load_from_file(path)
    entry = Enum.find(SessionManager.get_branch(compacted), &(&1.type == :compaction))
    assert entry
    assert entry.summary == summary
    refute inspect(receipt) =~ summary
  end
end
