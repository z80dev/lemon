defmodule LemonControlPlane.Methods.ManagementProjectionRedactionTest do
  @moduledoc """
  Management projections returned to `operator.content` callers (tasks, cron
  runs, session detail) pass every arbitrary term through the shared redacting
  projector. Read-only callers get metadata only; see ContentScopeTest.
  """
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.TestSupport.SessionCleanup
  alias LemonCore.RunStore

  @secret "sk-" <> String.duplicate("q", 48)
  @bearer "Bearer abcdefghijklmnop.qrstuvwx"

  defmodule FakeRuntime do
    @moduledoc false
    def list_tasks, do: :persistent_term.get({__MODULE__, :tasks}, [])

    def get_task(task_id) do
      case List.keyfind(list_tasks(), task_id, 0) do
        {_, record} -> {:ok, record, Map.get(record, :__events__, [])}
        nil -> {:error, :not_found}
      end
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, FakeRuntime)

    on_exit(fn ->
      :persistent_term.erase({FakeRuntime, :tasks})

      if is_nil(original),
        do: Application.delete_env(:lemon_core, :agent_runtime_provider),
        else: Application.put_env(:lemon_core, :agent_runtime_provider, original)
    end)

    :ok
  end

  defp shared_term do
    %{
      "note" => "subagent printed OPENAI_API_KEY=#{@secret}",
      :api_key => "plain-short",
      :nested => %{list: [1, :two, {"x", 3}, "auth: #{@bearer}"], ok: true, ratio: 1.5},
      "options" => [token: "kw-token-value", mode: :fast]
    }
  end

  defp put_tasks(tasks), do: :persistent_term.put({FakeRuntime, :tasks}, tasks)

  defp content_context, do: %{auth: %{role: :operator, scopes: [:read, :content]}}

  defp dispatch(method, params) do
    assert {:ok, result} = Registry.dispatch(method, params, content_context())
    result
  end

  defp assert_scrubbed(payload) do
    encoded = Jason.encode!(payload)
    refute encoded =~ @secret
    refute encoded =~ "abcdefghijklmnop"
    refute encoded =~ "plain-short"
    refute encoded =~ "kw-token-value"
    assert encoded =~ "[REDACTED]"
  end

  test "tasks.recent.list never returns task results, records or events with credentials" do
    record = %{
      status: :completed,
      run_id: "run-t16e",
      description: "deploy with API_KEY=#{@secret}",
      result: shared_term(),
      error: nil,
      prompt: "use password=hunter2-#{@secret}",
      __events__: [%{type: :output, text: "token=#{@secret}"}]
    }

    put_tasks([{"task-t16e", record}])

    result =
      dispatch("tasks.recent.list", %{"includeEvents" => true, "includeRecord" => true})

    assert [task] = result["tasks"]
    assert_scrubbed(result)
    refute Jason.encode!(result) =~ "hunter2"
    assert task["result"]["note"] == "subagent printed OPENAI_API_KEY=[REDACTED]"
    assert task["result"]["api_key"] == "[REDACTED]"

    cleanup = result["summary"]["cleanup"]
    assert cleanup["includesMessageBodies"] == true
    assert cleanup["includesTaskEvents"] == true
    assert cleanup["includesTaskRecords"] == true
    assert cleanup["includesCredentials"] == false
  end

  test "task summary flags are true only when content is included" do
    put_tasks([])

    result =
      dispatch("tasks.active.list", %{"includeEvents" => true, "includeRecord" => true})

    cleanup = result["summary"]["cleanup"]
    assert cleanup["includesMessageBodies"] == false
    assert cleanup["includesTaskEvents"] == false
    assert cleanup["includesTaskRecords"] == false
  end

  test "deep nesting and long collections are bounded through tasks.recent.list" do
    deep = Enum.reduce(1..50, "leaf token=#{@secret}", fn i, acc -> %{"l#{i}" => acc} end)
    wide = Enum.to_list(1..5_000)
    huge = String.duplicate("x", 100_000)

    put_tasks([
      {"task-deep", %{status: :completed, result: %{deep: deep, wide: wide, huge: huge}}}
    ])

    [task] = dispatch("tasks.recent.list", %{})["tasks"]
    projected = task["result"]

    assert length(projected["wide"]) <= 100
    assert byte_size(projected["huge"]) <= 4_096
    assert depth(projected["deep"]) <= 8
    assert Jason.encode!(projected) =~ "[max_depth]"
    refute Jason.encode!(projected) =~ @secret
  end

  test "the same term projects identically through task, cron and session methods" do
    term = shared_term()
    put_tasks([{"task-parity", %{status: :completed, result: term}}])
    [task] = dispatch("tasks.recent.list", %{})["tasks"]

    # cron.runs meta
    token = System.unique_integer([:positive])

    {:ok, job} =
      CronManager.add(%{
        name: "t16e-#{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "t16e_#{token}",
        session_key: "agent:t16e_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    run = job.id |> CronRun.new(:manual) |> Map.put(:meta, term) |> CronRun.complete("done")
    CronStore.put_run(run)

    on_exit(fn ->
      CronStore.delete_run(run.id)
      CronManager.remove(job.id)
    end)

    %{"runs" => [cron_run]} = dispatch("cron.runs", %{"id" => job.id, "includeMeta" => true})

    # session.detail completed error
    key = "agent:t16e_detail_#{token}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    :ok = RunStore.create_session_index(key, agent, :tui)
    on_exit(fn -> SessionCleanup.delete(key) end)

    :ok =
      RunStore.finalize("t16e-run-#{token}", %{
        session_key: key,
        agent_id: agent,
        origin: :tui,
        prompt: "hello",
        completed: %{ok: false, error: term}
      })

    detail = dispatch("session.detail", %{"sessionKey" => key})
    [detail_run] = detail["runs"]

    assert_scrubbed(task["result"])
    assert task["result"] == cron_run["meta"]
    assert task["result"] == detail_run["error"]
  end

  test "session.detail includeFullText for a content token still redacts credentials" do
    token = System.unique_integer([:positive])
    key = "agent:t16e_full_#{token}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    :ok = RunStore.create_session_index(key, agent, :tui)
    on_exit(fn -> SessionCleanup.delete(key) end)

    :ok =
      RunStore.finalize("t16e-full-#{token}", %{
        session_key: key,
        agent_id: agent,
        origin: :tui,
        prompt: "api_key=#{@secret}",
        completed: %{ok: true, answer: "here: #{@bearer}"}
      })

    detail = dispatch("session.detail", %{"sessionKey" => key, "includeFullText" => true})
    encoded = Jason.encode!(detail)
    refute encoded =~ @secret
    refute encoded =~ "abcdefghijklmnop"
    assert detail["summary"]["cleanup"]["includesSecretValues"] == false
  end

  defp depth(value) when is_map(value),
    do: 1 + (value |> Map.values() |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  defp depth(value) when is_list(value),
    do: 1 + (value |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  defp depth(_), do: 0
end
