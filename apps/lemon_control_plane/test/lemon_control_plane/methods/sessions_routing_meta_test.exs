defmodule LemonControlPlane.Methods.SessionsRoutingMetaTest do
  @moduledoc """
  The read side of a session's routing: what model it will run on, and where that came from.

  `sessions.list` answers cheaply (the override only) and `session.detail` answers fully
  (resolved model, provider, window); these tests pin that split so a later change cannot
  quietly make the listing do per-row model resolution. `session.detail` stays a routing
  projection: it never reads run history or returns run content.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SessionDetail, SessionsList}
  alias LemonControlPlane.TestSupport.SessionCleanup
  alias LemonCore.RunStore

  @content_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}
  @prompt "PROMPT_TEXT_9Z4K"
  @answer "ANSWER_TEXT_9Z4K"
  @exception "EXCEPTION_TEXT_9Z4K"
  @tool_detail "TOOL_DETAIL_9Z4K"

  defp fresh_key, do: "session_routing_#{System.unique_integer([:positive])}"

  describe "sessions.list" do
    test "every row carries a model key" do
      {:ok, result} = SessionsList.handle(%{}, %{})

      for row <- result["sessions"] do
        assert Map.has_key?(row, "model"),
               "sessions.list row is missing the model key: #{inspect(row)}"
      end
    end

    test "a row shows the session's override once one is pinned" do
      key = fresh_key()
      now = System.system_time(:millisecond)

      LemonCore.Store.put(:sessions_index, key, %{
        session_key: key,
        agent_id: "default",
        origin: :control_plane,
        created_at_ms: now,
        updated_at_ms: now,
        run_count: 1
      })

      LemonCore.PolicyStore.put_session(key, %{model: "gpt-5.4"})

      {:ok, result} = SessionsList.handle(%{"limit" => 500}, %{})
      row = Enum.find(result["sessions"], &(&1["sessionKey"] == key))

      assert row, "seeded session did not appear in sessions.list"
      assert row["model"] == "gpt-5.4"

      LemonCore.PolicyStore.delete_session(key)
      LemonCore.RunStore.delete_session_index(key)
    end
  end

  describe "session.detail" do
    test "resolves the model, its provider and its context window" do
      key = fresh_key()
      LemonCore.PolicyStore.put_session(key, %{model: "claude-sonnet-4-20250514"})

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})
      session = result["session"]

      assert session["model"] == "claude-sonnet-4-20250514"
      assert session["provider"] == "anthropic"
      assert session["modelSource"] == "session"
      assert session["modelOverride"] == "claude-sonnet-4-20250514"
      assert is_integer(session["contextWindow"]) and session["contextWindow"] > 0

      LemonCore.PolicyStore.delete_session(key)
    end

    test "reports thinking level with fixed native provenance" do
      key = fresh_key()

      LemonCore.PolicyStore.put_session(key, %{
        model: "gpt-5.4",
        thinking_level: "high"
      })

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})

      assert result["session"]["thinkingLevel"] == "high"
      assert result["session"]["engine"] == "lemon"
      refute Map.has_key?(result["session"], "preferredEngine")

      LemonCore.PolicyStore.delete_session(key)
    end

    test "an unpinned session reports a null override, not a null session" do
      key = fresh_key()

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, %{})
      session = result["session"]

      assert session["sessionKey"] == key
      assert session["modelOverride"] == nil
      refute session["modelSource"] == "session"
    end

    test "still requires a session key" do
      assert {:error, error} = SessionDetail.handle(%{}, %{})
      assert inspect(error) =~ "sessionKey"
    end

    test "projects the durable lifecycle row and routing the status bar reads" do
      %{key: key, agent: agent} = durable_session_with_run()
      {:ok, _} = LemonCore.SessionLifecycle.patch(key, %{title: "Release prep", pinned: true})

      LemonCore.PolicyStore.put_session(key, %{
        model: "claude-sonnet-4-20250514",
        thinking_level: "high"
      })

      on_exit(fn -> LemonCore.PolicyStore.delete_session(key) end)

      {:ok, result} = SessionDetail.handle(%{"sessionKey" => key}, @content_ctx)

      assert result |> Map.keys() |> Enum.sort() == ["session", "sessionKey"]
      session = result["session"]
      assert session["sessionKey"] == key
      assert session["agentId"] == agent
      assert session["origin"] == "tui"
      assert session["title"] == "Release prep"
      assert session["pinned"] == true
      assert session["archived"] == false
      assert is_integer(session["runCount"])
      assert is_integer(session["createdAtMs"])
      assert session["model"] == "claude-sonnet-4-20250514"
      assert session["provider"] == "anthropic"
      assert is_integer(session["contextWindow"]) and session["contextWindow"] > 0
      assert session["thinkingLevel"] == "high"
    end

    test "reads only this session's point rows, never run history or run records" do
      %{key: key} = durable_session_with_run()
      test_pid = self()

      observers =
        for name <- [LemonCore.RunHistoryStore, LemonCore.Store] do
          observer = fn
            acc, {:in, {:"$gen_call", {^test_pid, _tag}, request}}, _state ->
              send(test_pid, {:observed_call, name, request})
              acc

            acc, _event, _state ->
              acc
          end

          :ok = :sys.install(name, {observer, nil})
          {name, observer}
        end

      try do
        assert {:ok, _result} = SessionDetail.handle(%{"sessionKey" => key}, @content_ctx)
      after
        for {name, observer} <- observers, do: :sys.remove(name, observer)
      end

      calls = observed_calls()
      assert for({LemonCore.RunHistoryStore, request} <- calls, do: request) == []

      store_requests = for {LemonCore.Store, request} <- calls, do: request
      assert length(store_requests) <= 4

      for request <- store_requests do
        assert match?({op, _table, ^key} when op in [:generic_fetch, :generic_get], request),
               "unexpected store read #{inspect(request)}"
      end
    end

    test "never projects prompts, answers, failures or inspected terms" do
      %{key: key} = durable_session_with_run()

      legacy_flags = %{
        "sessionKey" => key,
        "includeFullText" => true,
        "includeRawEvents" => true,
        "includeRunRecord" => true
      }

      assert {:ok, result} = Registry.dispatch("session.detail", legacy_flags, @content_ctx)

      encoded = Jason.encode!(result)

      for text <- [@prompt, @answer, @exception, @tool_detail, "%{", "%RuntimeError", "#PID<"] do
        refute encoded =~ text
      end

      assert Enum.all?(Map.values(result["session"]), &scalar?/1)
    end
  end

  defp durable_session_with_run do
    token = System.unique_integer([:positive])
    key = "agent:session_detail_#{token}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    run_id = "session-detail-run-#{token}"
    :ok = RunStore.create_session_index(key, agent, :tui)

    on_exit(fn ->
      LemonCore.Store.delete(:runs, run_id)
      SessionCleanup.delete(key)
    end)

    :ok =
      RunStore.append_event(run_id, %{
        __event__: :action_event,
        action: %{title: "run", kind: :tool, detail: @tool_detail},
        ok: false
      })

    :ok =
      RunStore.finalize(run_id, %{
        session_key: key,
        agent_id: agent,
        origin: :tui,
        prompt: @prompt,
        completed: %{ok: false, answer: @answer, error: %RuntimeError{message: @exception}}
      })

    assert eventually(fn -> match?({:ok, [_ | _]}, RunStore.fetch_history(key, limit: 5)) end)
    %{key: key, agent: agent}
  end

  defp observed_calls do
    receive do
      {:observed_call, name, request} -> [{name, request} | observed_calls()]
    after
      0 -> []
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp scalar?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)
end
