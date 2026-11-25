defmodule LemonControlPlane.Methods.ContentScopeTest do
  @moduledoc """
  `operator.read` is metadata-only. Transcript and content payloads (prompts,
  answers, reasoning, task results, run records, raw events, cron target text,
  background answers, exports and log messages) need `operator.content`, and
  include flags never widen a read-only response.

  The fixtures deliberately use ordinary confidential prose and an unlabelled
  secret: neither matches a credential pattern, so scrubbing alone cannot hide
  them.
  """
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}
  alias LemonControlPlane.ConfigStore
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.TestSupport.SessionCleanup
  alias LemonCore.{RunStore, Store}

  @prose "The merger closes Friday at 41 dollars per share"
  @unlabelled "PROMPT_SECRET_7Q2X9"
  @content "#{@prose}; reference #{@unlabelled}"

  defmodule FakeRuntime do
    @moduledoc false
    def list_tasks, do: :persistent_term.get({__MODULE__, :tasks}, [])

    def get_task(task_id) do
      case List.keyfind(list_tasks(), task_id, 0) do
        {_, record} -> {:ok, record, Map.get(record, :__events__, [])}
        nil -> {:error, :not_found}
      end
    end

    def background_result("bg_content"),
      do: {:ok, :persistent_term.get({__MODULE__, :answer})}
  end

  defmodule LogRing do
    @moduledoc false
    def get_logs(_limit, _level),
      do:
        {:ok,
         [
           %{
             level: "info",
             message: :persistent_term.get({__MODULE__, :message}),
             timestamp_ms: 1
           }
         ]}
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    original_ring = Application.get_env(:lemon_control_plane, :log_ring_module)
    Application.put_env(:lemon_core, :agent_runtime_provider, FakeRuntime)
    Application.put_env(:lemon_control_plane, :log_ring_module, LogRing)
    :persistent_term.put({FakeRuntime, :answer}, @content)
    :persistent_term.put({LogRing, :message}, "user said: #{@content}")

    on_exit(fn ->
      :persistent_term.erase({FakeRuntime, :tasks})
      :persistent_term.erase({FakeRuntime, :answer})
      :persistent_term.erase({LogRing, :message})

      if is_nil(original),
        do: Application.delete_env(:lemon_core, :agent_runtime_provider),
        else: Application.put_env(:lemon_core, :agent_runtime_provider, original)

      if is_nil(original_ring),
        do: Application.delete_env(:lemon_control_plane, :log_ring_module),
        else: Application.put_env(:lemon_control_plane, :log_ring_module, original_ring)
    end)

    token = System.unique_integer([:positive])
    %{token: token}
  end

  defp read_only, do: %{auth: %{role: :operator, scopes: [:read]}}
  defp with_content, do: %{auth: %{role: :operator, scopes: [:read, :content]}}

  defp dispatch(method, params, ctx) do
    assert {:ok, result} = Registry.dispatch(method, params, ctx)
    result
  end

  defp assert_withheld(payload) do
    encoded = Jason.encode!(payload)
    refute encoded =~ "merger closes Friday"
    refute encoded =~ @unlabelled
  end

  defp assert_content(payload) do
    encoded = Jason.encode!(payload)
    assert encoded =~ "merger closes Friday"
    assert encoded =~ @unlabelled
  end

  defp session(token) do
    key = "agent:content_scope_#{token}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    :ok = RunStore.create_session_index(key, agent, :tui)
    run_id = "content-run-#{token}"

    :ok =
      RunStore.append_event(run_id, %{
        type: :engine_action,
        action: %{id: "a1", kind: :command, title: "echo #{@content}", detail: %{args: @content}},
        phase: :completed,
        ok: true,
        message: @content
      })

    :ok =
      RunStore.finalize(run_id, %{
        session_key: key,
        agent_id: agent,
        origin: :tui,
        prompt: "Please summarise: #{@content}",
        completed: %{ok: false, answer: "Answer: #{@content}", error: "failed on #{@content}"}
      })

    on_exit(fn ->
      SessionCleanup.delete(key)
      Store.delete(:runs, run_id)
    end)

    {key, run_id}
  end

  describe "tasks.active.list / tasks.recent.list" do
    setup do
      record = %{
        status: :completed,
        run_id: "run-content",
        description: "Summarise #{@content}",
        prompt: @content,
        result: %{answer: @content},
        error: nil,
        __events__: [
          %{type: :output, text: @content},
          %{details: %{reasoning: %{text: "thinking about #{@content}", source: :model}}}
        ]
      }

      :persistent_term.put({FakeRuntime, :tasks}, [{"task-content", record}])
      :ok
    end

    test "read-only callers get metadata only, whatever the include flags" do
      params = %{"includeEvents" => true, "includeRecord" => true}
      result = dispatch("tasks.recent.list", params, read_only())

      assert [task] = result["tasks"]
      assert_withheld(result)
      assert task["taskId"] == "task-content"
      assert task["status"] == "completed"
      assert task["eventCount"] == 2
      refute Map.has_key?(task, "result")
      refute Map.has_key?(task, "events")
      refute Map.has_key?(task, "record")
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["filters"]["includeEvents"] == false
      assert result["filters"]["includeRecord"] == false
    end

    test "operator.content callers get task content" do
      params = %{"includeEvents" => true, "includeRecord" => true}
      result = dispatch("tasks.recent.list", params, with_content())
      assert_content(result)
      assert result["summary"]["cleanup"]["includesMessageBodies"] == true
    end
  end

  describe "session.detail" do
    test "is a routing projection with no run content for either scope", c do
      {key, _run_id} = session(c.token)

      params = %{
        "sessionKey" => key,
        "includeFullText" => true,
        "includeRawEvents" => true,
        "includeRunRecord" => true
      }

      for ctx <- [read_only(), with_content()] do
        detail = dispatch("session.detail", params, ctx)
        assert_withheld(detail)
        assert detail["session"]["sessionKey"] == key
        refute Map.has_key?(detail, "runs")
      end
    end
  end

  describe "chat.history" do
    test "read-only callers get message metadata without bodies", c do
      {key, _run_id} = session(c.token)
      result = dispatch("chat.history", %{"sessionKey" => key}, read_only())
      assert_withheld(result)
      assert Enum.any?(result["messages"], &(&1["role"] == "user"))
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
    end

    test "operator.content callers get bodies", c do
      {key, _run_id} = session(c.token)
      assert_content(dispatch("chat.history", %{"sessionKey" => key}, with_content()))
    end
  end

  describe "sessions.history / sessions.export" do
    test "read-only callers get run metadata and no export body", c do
      {key, run_id} = session(c.token)

      history = dispatch("sessions.history", %{"sessionKey" => key}, read_only())
      assert_withheld(history)
      assert [%{run_id: ^run_id, ok: false, tool_count: 1}] = history["history"]

      export = dispatch("sessions.export", %{"sessionKey" => key}, read_only())
      assert_withheld(export)
      refute Map.has_key?(export, "content")
      assert export["summary"]["runCount"] == 1
    end

    test "operator.content callers get history text and the export body", c do
      {key, _run_id} = session(c.token)
      assert_content(dispatch("sessions.history", %{"sessionKey" => key}, with_content()))
      assert_content(dispatch("sessions.export", %{"sessionKey" => key}, with_content()))
    end
  end

  describe "agent.wait" do
    test "read-only callers learn completion, not the answer or error text", c do
      {_key, run_id} = session(c.token)
      result = dispatch("agent.wait", %{"runId" => run_id, "timeoutMs" => 1_000}, read_only())
      assert_withheld(result)
      assert result["ok"] == false
      assert result["summary"]["hasError"] == true
    end

    test "operator.content callers get the answer", c do
      {_key, run_id} = session(c.token)
      params = %{"runId" => run_id, "timeoutMs" => 1_000}
      assert_content(dispatch("agent.wait", params, with_content()))
    end
  end

  describe "cron.runs / cron.list" do
    setup c do
      {:ok, job} =
        CronManager.add(%{
          name: "content-#{c.token}",
          schedule: "0 0 1 1 *",
          enabled: false,
          agent_id: "content_#{c.token}",
          session_key: "agent:content_#{c.token}:main",
          prompt: "Every year: #{@content}",
          timezone: "UTC",
          meta: %{"note" => @content}
        })

      run =
        job.id
        |> CronRun.new(:manual)
        |> Map.put(:meta, %{"note" => @content})
        |> CronRun.complete("Output: #{@content}")

      CronStore.put_run(run)

      on_exit(fn ->
        CronStore.delete_run(run.id)
        CronManager.remove(job.id)
      end)

      %{job: job}
    end

    test "read-only callers get run and job metadata only", c do
      params = %{
        "id" => c.job.id,
        "includeOutput" => true,
        "includeMeta" => true,
        "includeRunRecord" => true
      }

      runs = dispatch("cron.runs", params, read_only())
      assert_withheld(runs)
      assert [run] = runs["runs"]
      assert run["status"] == "completed"
      assert run["summary"]["outputBytes"] > 0

      list =
        dispatch(
          "cron.list",
          %{"agentId" => c.job.agent_id, "includeTargetText" => true},
          read_only()
        )

      assert_withheld(list)
      assert [job] = list["jobs"]
      assert job["promptBytes"] > 0
      assert list["summary"]["targetTextReturned"] == false
    end

    test "operator.content callers get output, meta and target text", c do
      params = %{"id" => c.job.id, "includeOutput" => true, "includeMeta" => true}
      assert_content(dispatch("cron.runs", params, with_content()))

      list_params = %{"agentId" => c.job.agent_id, "includeTargetText" => true}
      assert_content(dispatch("cron.list", list_params, with_content()))
    end
  end

  test "background.result withholds the answer without operator.content" do
    result = dispatch("background.result", %{"id" => "bg_content"}, read_only())
    assert_withheld(result)
    assert result["ready"] == true
    assert result["answerBytes"] == byte_size(@content)

    assert_content(dispatch("background.result", %{"id" => "bg_content"}, with_content()))
  end

  test "logs.tail returns levels and counts but no messages without operator.content" do
    result = dispatch("logs.tail", %{}, read_only())
    assert_withheld(result)
    assert [%{"level" => "info"}] = result["logs"]
    assert result["summary"]["cleanup"]["includesLogMessages"] == false

    assert_content(dispatch("logs.tail", %{}, with_content()))
  end

  describe "config.get" do
    setup c do
      nested = "contentScopeNested#{c.token}"
      text = "contentScopeText#{c.token}"
      credential = "sk-" <> String.duplicate("c", 40)

      :ok = ConfigStore.put(nested, [%{"api_key" => "private-value"}, %{"label" => @content}])
      :ok = ConfigStore.put(text, "OPENAI_API_KEY=#{credential} #{@unlabelled}")

      on_exit(fn ->
        Store.delete(:system_config, nested)
        Store.delete(:system_config, text)
      end)

      %{nested: nested, text: text, credential: credential}
    end

    test "read scope sees only explicitly public fields", c do
      all = dispatch("config.get", %{}, read_only())
      refute Map.has_key?(all, c.nested)
      refute Map.has_key?(all, c.text)
      refute Jason.encode!(all) =~ "private-value"
      assert_withheld(all)

      single = dispatch("config.get", %{"key" => c.nested}, read_only())
      assert single["value"] == nil
      assert single["summary"]["valueReturned"] == false
      refute Jason.encode!(single) =~ "private-value"

      assert %{"value" => _} = dispatch("config.get", %{"key" => "logLevel"}, read_only())
    end

    test "admin scope gets values through the shared projector", c do
      admin = %{auth: %{role: :operator, scopes: [:read, :admin]}}

      nested = dispatch("config.get", %{"key" => c.nested}, admin)
      assert [%{"api_key" => "[REDACTED]"}, %{"label" => @content}] = nested["value"]

      text = dispatch("config.get", %{"key" => c.text}, admin)
      refute text["value"] =~ c.credential
      assert text["value"] =~ "[REDACTED]"

      all = dispatch("config.get", %{}, admin)
      refute Jason.encode!(all) =~ "private-value"
      refute Jason.encode!(all) =~ c.credential
      assert all[c.nested] == nested["value"]
    end
  end
end
