defmodule LemonGateway.Tools.CronTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Tools.Cron

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    clear_cron_data()

    on_exit(fn ->
      clear_cron_data()
    end)

    :ok
  end

  test "add, list, update, and remove actions operate on Lemon internal cron" do
    session_key = LemonCore.SessionKey.main("default")
    tool = Cron.tool(".", session_key: session_key, agent_id: "default")

    add_result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Tool test job",
        "schedule" => "*/5 * * * *",
        "prompt" => "say hello"
      })

    assert %{"id" => job_id, "name" => "Tool test job"} = add_result.details
    assert is_binary(job_id)

    list_result = call_tool(tool, %{"action" => "list"})
    assert Enum.any?(list_result.details["jobs"], &(&1["id"] == job_id))

    update_result = call_tool(tool, %{"action" => "update", "id" => job_id, "enabled" => false})
    assert %{"id" => ^job_id, "updated" => true, "nextRunAtMs" => _} = update_result.details

    remove_result = call_tool(tool, %{"action" => "remove", "id" => job_id})
    assert %{"removed" => true, "id" => ^job_id} = remove_result.details
  end

  test "add defaults to current session and inferred agent id when omitted" do
    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "agent_x",
        channel_id: "telegram",
        account_id: "bot",
        peer_kind: :dm,
        peer_id: "42"
      })

    tool = Cron.tool(".", session_key: session_key)

    result =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "0 * * * *",
        "prompt" => "hourly check"
      })

    assert result.details["sessionKey"] == session_key
    assert result.details["agentId"] == "agent_x"
    assert is_binary(result.details["memoryFile"])
    assert String.ends_with?(result.details["memoryFile"], "#{result.details["id"]}.md")
  end

  test "add accepts memoryFile and list returns it" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    memory_file = Path.join(System.tmp_dir!(), "cron_tool_memory_test.md")

    add_result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Memory job",
        "schedule" => "*/15 * * * *",
        "prompt" => "remember progress",
        "memoryFile" => memory_file
      })

    assert add_result.details["memoryFile"] == Path.expand(memory_file)

    list_result = call_tool(tool, %{"action" => "list"})

    listed =
      Enum.find(list_result.details["jobs"], fn job ->
        job["id"] == add_result.details["id"]
      end)

    assert listed["memoryFile"] == Path.expand(memory_file)
  end

  test "returns an error when required add fields are missing" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))

    result =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "* * * * *"
      })

    assert %{error: true} = result.details
    assert AgentCore.get_text(result) =~ "prompt is required"
  end

  test "returns an error for unknown actions" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    result = call_tool(tool, %{"action" => "wat"})

    assert %{error: true} = result.details
    assert AgentCore.get_text(result) =~ "Unknown action"
  end

  defp call_tool(tool, params) do
    tool.execute.("call_1", params, nil, nil)
  end

  defp clear_cron_data do
    if Process.whereis(LemonAutomation.CronManager) do
      LemonAutomation.CronManager.list()
      |> Enum.each(fn job ->
        _ = LemonAutomation.CronManager.remove(job.id)
      end)
    end

    LemonCore.Store.list(:cron_jobs)
    |> Enum.each(fn {job_id, _} ->
      LemonCore.Store.delete(:cron_jobs, job_id)
    end)

    LemonCore.Store.list(:cron_runs)
    |> Enum.each(fn {run_id, _} ->
      LemonCore.Store.delete(:cron_runs, run_id)
    end)
  end
end
