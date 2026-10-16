defmodule LemonCli.CronCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defmodule Client do
    def request(method, params) do
      send(self(), {:request, method, params})

      case method do
        "cron.list" -> {:ok, %{"jobs" => Process.get(:cron_jobs, [])}}
        "cron.run" -> {:ok, %{"runId" => "r1"}}
        "cron.pause" when is_map_key(params, "all") -> all_reply(%{"paused" => true})
        "cron.resume" when is_map_key(params, "all") -> all_reply(resumed_receipt())
        _ -> {:ok, %{}}
      end
    end

    defp all_reply(receipt) do
      if Process.get(:cron_all_failure),
        do: {:error, :unavailable},
        else: {:ok, Map.put(receipt, "all", true)}
    end

    defp resumed_receipt do
      Process.get(:cron_all_resume, %{
        "resumed" => true,
        "skippedJobCount" => 2,
        "skippedRetryCount" => 1
      })
    end
  end

  setup do
    previous = Application.get_env(:lemon_cli, :control_plane_client)
    Application.put_env(:lemon_cli, :control_plane_client, Client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous),
        else: Application.delete_env(:lemon_cli, :control_plane_client)
    end)

    Process.put(:cron_jobs, [
      %{
        "id" => "j1",
        "name" => "Morning",
        "failureStreak" => 2,
        "lastStatus" => "failed",
        "enabled" => false,
        "schedule" => "daily"
      }
    ])

    :ok
  end

  test "list renders health and filters JSON" do
    assert capture_io(fn -> assert LemonCli.RunsCommand.run_cron(["list"]) == 0 end) =~
             "Morning | daily | false"

    output =
      capture_io(fn ->
        assert LemonCli.RunsCommand.run_cron(["list", "--failing", "--json"]) == 0
      end)

    assert %{"total" => 1, "jobs" => [%{"failureStreak" => 2}]} = Jason.decode!(output)
  end

  test "mutations resolve case insensitive names and call server validation" do
    for action <- ~w(pause resume run) do
      capture_io(fn -> assert LemonCli.RunsCommand.run_cron([action, "MORNING"]) == 0 end)
      method = "cron.#{action}"
      assert_received {:request, ^method, %{"id" => "j1"}}
    end
  end

  test "pause and resume --all use the one global switch without touching jobs" do
    output = capture_io(fn -> assert LemonCli.RunsCommand.run_cron(["pause", "--all"]) == 0 end)
    assert output =~ "All cron jobs paused"
    assert output =~ "lemon cron resume --all"
    assert_received {:request, "cron.pause", %{"all" => true} = params}
    refute Map.has_key?(params, "id")

    output = capture_io(fn -> assert LemonCli.RunsCommand.run_cron(["resume", "--all"]) == 0 end)
    assert output =~ "All cron jobs resumed; skipped 2 missed slot(s) and 1 retry(ies)"
    assert_received {:request, "cron.resume", %{"all" => true}}
    refute_received {:request, "cron.list", _}

    Process.put(:cron_all_resume, %{"resumed" => false})
    output = capture_io(fn -> assert LemonCli.RunsCommand.run_cron(["resume", "--all"]) == 0 end)
    assert output =~ "were not paused"
  end

  test "--all failures and malformed receipts exit nonzero; extra arguments are usage errors" do
    Process.put(:cron_all_failure, true)

    output =
      capture_io(:stderr, fn -> assert LemonCli.RunsCommand.run_cron(["pause", "--all"]) == 1 end)

    assert output =~ "Cron operation failed"
    Process.delete(:cron_all_failure)

    Process.put(:cron_all_resume, %{"unexpected" => true})

    capture_io(:stderr, fn -> assert LemonCli.RunsCommand.run_cron(["resume", "--all"]) == 1 end)

    for args <- [["pause", "--all", "j1"], ["run", "--all"], ["remove", "--all"]] do
      output = capture_io(:stderr, fn -> assert LemonCli.RunsCommand.run_cron(args) == 2 end)
      assert output =~ "pause|resume --all"
    end
  end

  test "ambiguous names refuse with candidates but exact IDs win" do
    Process.put(:cron_jobs, [%{"id" => "j1", "name" => "same"}, %{"id" => "j2", "name" => "SAME"}])

    output =
      capture_io(:stderr, fn -> assert LemonCli.RunsCommand.run_cron(["pause", "Same"]) == 1 end)

    assert output =~ "j1, j2"
    refute_received {:request, "cron.pause", _}
    capture_io(fn -> assert LemonCli.RunsCommand.run_cron(["pause", "j2"]) == 0 end)
    assert_received {:request, "cron.pause", %{"id" => "j2"}}
  end

  test "remove refuses noninteractive input unless yes is explicit" do
    capture_io(:stderr, fn -> assert LemonCli.RunsCommand.run_cron(["remove", "j1"]) == 1 end)
    refute_received {:request, "cron.remove", _}

    capture_io(fn ->
      assert LemonCli.RunsCommand.run_cron(["remove", "Morning", "--yes"]) == 0
    end)

    assert_received {:request, "cron.remove", %{"id" => "j1"}}
  end

  test "interactive removal prompts and respects both answers" do
    for {answer, expected} <- [{"no\n", 1}, {"yes\n", 0}] do
      capture_io(:stderr, fn ->
        output =
          capture_io([input: answer], fn ->
            original = Process.group_leader()
            terminal = spawn(fn -> terminal_loop(original) end)
            Process.group_leader(self(), terminal)

            try do
              assert LemonCli.RunsCommand.run_cron(["remove", "Morning"]) == expected
            after
              Process.group_leader(self(), original)
              Process.exit(terminal, :kill)
            end
          end)

        assert output =~ "Remove cron Morning (j1)?"
      end)

      if expected == 0 do
        assert_received {:request, "cron.remove", %{"id" => "j1"}}
      else
        refute_received {:request, "cron.remove", _}
      end
    end
  end

  defp terminal_loop(original) do
    receive do
      {:io_request, from, reply_as, {:get_geometry, :columns}} ->
        send(from, {:io_reply, reply_as, 80})
        terminal_loop(original)

      request ->
        send(original, request)
        terminal_loop(original)
    end
  end

  test "invalid arguments never query" do
    capture_io(:stderr, fn ->
      assert LemonCli.RunsCommand.run_cron(["pause", "j1", "--yes"]) == 2
    end)

    refute_received {:request, _, _}
  end
end
