defmodule LemonCli.OperatorCommandsTestClient do
  def request(method, params) do
    send(self(), {:operator_request, method, params})
    Process.get(:operator_response).(method, params)
  end
end

defmodule LemonCli.OperatorCommandsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCli.LogsCommand
  alias LemonCli.RunsCommand

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous = Application.get_env(:lemon_cli, :control_plane_client)
    Application.put_env(:lemon_cli, :control_plane_client, LemonCli.OperatorCommandsTestClient)

    names =
      ~w(HOME LEMON_CLI_LAUNCHER LEMON_RUNTIME_LOG_FILE LEMON_RUNTIME_LOG_DIR LEMON_CONTROL_PLANE_PORT)

    environment = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    System.put_env("HOME", directory)
    System.put_env("LEMON_CLI_LAUNCHER", "source")
    System.put_env("LEMON_CONTROL_PLANE_PORT", "49941")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous),
        else: Application.delete_env(:lemon_cli, :control_plane_client)

      Enum.each(environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, directory: directory}
  end

  test "cron status prints failing jobs and preserves the JSON status projection" do
    status = %{"jobCount" => 4, "activeJobs" => 3, "failingJobs" => 2}
    Process.put(:operator_response, fn "cron.status", %{} -> {:ok, status} end)
    output = capture_io(fn -> assert CLI.run(~w(cron status)) == 0 end)
    assert output =~ "Cron jobs: 4, enabled: 3, failing: 2"
    assert_received {:operator_request, "cron.status", %{}}

    assert capture_io(fn -> assert CLI.run(~w(cron status --json)) == 0 end) |> Jason.decode!() ==
             status
  end

  test "since parses exact relative minutes, hours and days" do
    now = 1_000_000_000
    assert RunsCommand.since_ms("30m", now) == {:ok, now - 1_800_000}
    assert RunsCommand.since_ms("1h", now) == {:ok, now - 3_600_000}
    assert RunsCommand.since_ms("2d", now) == {:ok, now - 172_800_000}
    assert RunsCommand.since_ms(nil, now) == {:ok, nil}
    assert RunsCommand.since_ms("999999999999d", now) == {:ok, 0}

    for value <- ["", "0h", "-1h", "1.5h", "1s", "1hmore", "2D", "1", " 1h"] do
      assert {:invalid, _} = RunsCommand.since_ms(value, now)
    end
  end

  test "invalid options fail before querying the runtime" do
    Process.put(:operator_response, fn _, _ -> flunk("invalid arguments reached runtime") end)

    for args <- [
          ~w(runs --since 0h),
          ~w(runs --status failed),
          ~w(runs --limit 0),
          ~w(runs --limit 201),
          ~w(runs --limit nope),
          ~w(runs wat),
          ~w(runs show),
          ~w(runs show one two),
          ~w(runs show one --limit 5),
          ~w(runs active --since 1h),
          ~w(cron list --unknown),
          ~w(cron runs --status error),
          ~w(cron runs --since 1s),
          ~w(cron status --job id),
          ~w(cron status extra),
          ~w(logs -n 0),
          ~w(logs -n 1001),
          ~w(logs --level debug),
          ~w(logs --unknown),
          ~w(logs extra)
        ] do
      assert capture_io(:stderr, fn -> assert CLI.run(args) == 2 end) != ""
    end
  end

  test "runs show renders relative timeline times, durations, outcomes and truncation" do
    timeline = %{
      "runId" => "run-detail",
      "entries" => [
        %{"atMs" => 1000, "label" => "run started", "ok" => nil, "status" => "active"},
        %{
          "atMs" => 2500,
          "label" => "read",
          "durationMs" => 250,
          "ok" => true,
          "status" => "completed"
        },
        %{
          "atMs" => 3000,
          "label" => "bash",
          "durationMs" => 500,
          "ok" => false,
          "status" => "error"
        },
        %{"atMs" => 4000, "label" => "task", "ok" => nil, "status" => "pending"}
      ],
      "truncated" => true,
      "usage" => %{"tokens" => %{"total" => 5}, "costUsd" => 0.0, "model" => "fixture"}
    }

    Process.put(:operator_response, fn "runs.timeline.get", %{"runId" => "run-detail"} ->
      {:ok, timeline}
    end)

    output = capture_io(fn -> assert CLI.run(~w(runs show run-detail)) == 0 end)
    assert output =~ "+1.5s [ok] read · completed · 0.3s"
    assert output =~ "+2.0s [fail] bash"
    assert output =~ "[pending] task"
    assert output =~ "Timeline truncated"
    assert output =~ "5 tokens"
    assert_received {:operator_request, "runs.timeline.get", %{"runId" => "run-detail"}}

    assert capture_io(fn -> assert CLI.run(~w(runs show run-detail --json)) == 0 end)
           |> Jason.decode!() == timeline
  end

  test "runs show surfaces not-found and unavailable runtime as failures" do
    for reason <- [{:not_found, "Run not found", nil}, {:control_plane_unavailable, :offline}] do
      Process.put(:operator_response, fn _, _ -> {:error, reason} end)
      assert capture_io(:stderr, fn -> assert CLI.run(~w(runs show absent)) == 1 end) != ""
    end
  end

  test "recent list passes filters and renders pre-usage rows" do
    row = row()
    Process.put(:operator_response, fn "runs.recent.list", _ -> {:ok, %{"runs" => [row]}} end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ~w(runs list --agent operator --session agent:operator:main --status completed)
               ) == 0
      end)

    assert output =~ "completed"
    assert output =~ "1.5s"
    assert output =~ "run_123456789"
    assert output =~ "MODEL"

    assert_received {:operator_request, "runs.recent.list",
                     %{
                       "agentId" => "operator",
                       "sessionKey" => "agent:operator:main",
                       "status" => "completed",
                       "limit" => 200
                     }}
  end

  test "new crash, error, model, tokens and cost fields render when present" do
    row =
      Map.merge(row(), %{
        "status" => "crashed",
        "model" => "test-model",
        "costUsd" => 0.0123,
        "tokens" => %{"total" => 123},
        "error" => "worker_exit"
      })

    Process.put(:operator_response, fn _, _ -> {:ok, %{"runs" => [row]}} end)
    output = capture_io(fn -> assert CLI.run(["runs"]) == 0 end)
    for value <- ~w(crashed test-model 0.0123 123 worker_exit), do: assert(output =~ value)

    json = capture_io(fn -> assert CLI.run(~w(runs --json)) == 0 end) |> Jason.decode!()
    assert [%{"tokens" => %{"total" => 123}, "costUsd" => 0.0123}] = json["runs"]
  end

  test "recent since is applied before the requested output limit" do
    recent = row()
    old = Map.put(recent, "startedAtMs", 1)
    Process.put(:operator_response, fn _, _ -> {:ok, %{"runs" => [old, recent]}} end)

    result =
      capture_io(fn -> assert CLI.run(~w(runs --since 1h --limit 1 --json)) == 0 end)
      |> Jason.decode!()

    assert result["runs"] == [recent]
  end

  test "active adapts in-flight sessions and applies exact session filtering" do
    Process.put(:operator_response, fn "sessions.active.list", _ ->
      {:ok, %{"sessions" => [row(), Map.put(row(), "sessionKey", "other")]}}
    end)

    result =
      capture_io(fn ->
        assert CLI.run(~w(runs active --session agent:operator:main --json)) == 0
      end)
      |> Jason.decode!()

    assert [%{"status" => "running", "sessionKey" => "agent:operator:main"}] = result["runs"]
    assert_received {:operator_request, "sessions.active.list", _}
  end

  test "cron without a job aggregates jobs, bounds rows and omits output and metadata" do
    Process.put(:operator_response, fn
      "cron.list", _ ->
        {:ok, %{"jobs" => [%{"id" => "one"}, %{"id" => "two"}]}}

      "cron.runs", %{"id" => id} ->
        {:ok,
         %{
           "runs" => [
             Map.merge(row(), %{
               "id" => id,
               "jobId" => id,
               "output" => "private output",
               "meta" => %{"prompt" => "private prompt"}
             })
           ]
         }}
    end)

    output =
      capture_io(fn ->
        assert CLI.run(~w(cron runs --status completed --since 2d --limit 1 --json)) == 0
      end)

    assert Jason.decode!(output)["total"] == 1
    refute output =~ "private"

    assert_received {:operator_request, "cron.runs",
                     %{
                       "id" => "one",
                       "status" => "completed",
                       "sinceMs" => since,
                       "includeMeta" => false
                     }}

    assert is_integer(since)
    assert_received {:operator_request, "cron.runs", %{"id" => "two"}}
  end

  test "explicit cron job does not require inventory access and failures are not empty" do
    Process.put(:operator_response, fn "cron.runs", %{"id" => "deleted-job"} ->
      {:error, {:control_plane, %{"message" => "private error"}}}
    end)

    output =
      capture_io(:stderr, fn -> assert CLI.run(~w(cron runs --job deleted-job --json)) == 1 end)

    assert Jason.decode!(output)["error"]
    refute output =~ "private error"
    refute_received {:operator_request, "cron.list", _}
  end

  test "run queries fail clearly when runtime is down" do
    Process.put(:operator_response, fn _, _ ->
      {:error, {:control_plane_unavailable, "sk-must-not-leak-12345678"}}
    end)

    for args <- [~w(runs), ~w(runs active), ~w(cron runs)] do
      output = capture_io(:stderr, fn -> assert CLI.run(args) == 1 end)
      assert output =~ "Runtime not running"
      assert output =~ "lemon daemon"
      refute output =~ "sk-must-not-leak"
      refute output =~ "No matching runs"
    end
  end

  test "malformed run and log responses are errors, not empty success" do
    Process.put(:operator_response, fn _, _ -> {:ok, %{}} end)

    for command <- ~w(runs logs) do
      assert capture_io(:stderr, fn -> assert CLI.run([command]) == 1 end) =~ "query failed"
    end
  end

  test "online logs use severity and line count and do not open files" do
    Process.put(:operator_response, fn "logs.tail", _ ->
      {:ok, %{"logs" => [%{"timestampMs" => 1, "level" => "warning", "message" => "ready"}]}}
    end)

    output =
      capture_io(fn -> assert CLI.run(~w(logs -n 5 --level warning --json)) == 0 end)
      |> Jason.decode!()

    assert output["source"] == "runtime logs.tail"
    assert [%{"message" => "ready"}] = output["logs"]
    assert_received {:operator_request, "logs.tail", %{"limit" => 5, "level" => "warning"}}
  end

  test "follow cursor deduplicates boundary entries but keeps new entries at the same millisecond" do
    first = %{"timestampMs" => 100, "message" => "one"}
    second = %{"timestampMs" => 100, "message" => "two"}
    third = %{"timestampMs" => 101, "message" => "three"}
    {fresh, cursor} = LogsCommand.advance([first, second], {100, MapSet.new([first])})
    assert fresh == [second]
    assert {[], ^cursor} = LogsCommand.advance([first, second], cursor)
    assert {[^third], {101, _}} = LogsCommand.advance([first, second, third], cursor)
  end

  test "follow consumes a stop message and returns without stopping runtime" do
    Process.put(:operator_response, fn _, _ ->
      send(self(), :lemon_logs_stop)
      {:ok, %{"logs" => []}}
    end)

    assert capture_io(fn -> assert CLI.run(~w(logs --follow)) == 0 end) =~ "runtime logs.tail"
  end

  test "follow polls the full bounded ring and prints only fresh entries" do
    first = %{"timestampMs" => 100, "message" => "first"}
    second = %{"timestampMs" => 100, "message" => "second"}
    Process.put(:operator_polls, 0)

    Process.put(:operator_response, fn "logs.tail", _ ->
      case Process.get(:operator_polls) do
        0 ->
          Process.put(:operator_polls, 1)
          {:ok, %{"logs" => [first]}}

        1 ->
          send(self(), :lemon_logs_stop)
          {:ok, %{"logs" => [first, second]}}
      end
    end)

    output = capture_io(fn -> assert CLI.run(~w(logs -n 1 --follow --json)) == 0 end)
    documents = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [%{"logs" => [^first]}, %{"logs" => [^second]}] = documents
    assert_received {:operator_request, "logs.tail", %{"limit" => 1}}
    assert_received {:operator_request, "logs.tail", %{"limit" => 1_000}}
  end

  test "noninteractive follow exits on SIGINT without opening the VM break menu" do
    source = """
    defmodule OperatorSignalClient do
      def request("logs.tail", _params), do: {:ok, %{"logs" => []}}
    end
    Application.put_env(:lemon_cli, :control_plane_client, OperatorSignalClient)
    LemonCli.CLI.main(["logs", "--follow"])
    """

    root = Path.expand("../../../..", __DIR__)
    executable = System.find_executable("elixir") |> String.to_charlist()

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--erl",
          "+S2:2 +Bd",
          "-pa",
          Path.join(root, "_build/test/lib/*/ebin"),
          "-e",
          source
        ],
        env: [{~c"ERL_FLAGS", ~c"+S2:2"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert_receive {^port, {:data, output}}, 10_000
    assert output =~ "runtime logs.tail"
    assert {_, 0} = System.cmd("kill", ["-INT", Integer.to_string(pid)])
    assert_receive {^port, {:exit_status, 130}}, 10_000
    refute output =~ "BREAK"
  end

  test "bounded file reader includes partial last line, handles empty files and redacts", %{
    directory: directory
  } do
    path = Path.join(directory, "tail.log")
    File.write!(path, "first\n[info] ready\n[error] token=sk-fake-log-token-12345678")
    assert {:ok, ["[info] ready", redacted]} = LogsCommand.tail_file(path, 2)
    assert redacted =~ "[REDACTED]"
    refute redacted =~ "sk-fake"
    File.write!(path, "")
    assert LogsCommand.tail_file(path, 50) == {:ok, []}
    File.write!(path, "one\ntwo\n")
    assert LogsCommand.tail_file(path, 1) == {:ok, ["two"]}
    File.write!(path, String.duplicate("x", 2_000_000) <> "\nlast\n")
    assert LogsCommand.tail_file(path, 50) == {:ok, ["last"]}
  end

  test "offline logs use selected launcher port, redact JSON and filter levels", %{
    directory: directory
  } do
    Process.put(:operator_response, fn _, _ -> {:error, {:control_plane_unavailable, :closed}} end)

    log = Path.join([directory, ".lemon", "run", "lemon-49941.log"])
    File.mkdir_p!(Path.dirname(log))

    File.write!(
      log,
      "[info] ready\nno level\n[warning] token=sk-fake-offline-12345678\n[error] failed"
    )

    output = capture_io(fn -> assert CLI.run(~w(logs --level warning --json)) == 0 end)

    assert [%{"message" => warning}, %{"message" => "[error] failed"}] =
             Jason.decode!(output)["logs"]

    assert warning =~ "[REDACTED]"
    refute output =~ "sk-fake"
    refute output =~ directory
    assert capture_io(fn -> assert CLI.run(["logs"]) == 0 end) =~ "launcher lemon-49941.log"
  end

  test "offline packaged logs use newest release file and explicit overrides", %{
    directory: directory
  } do
    Process.put(:operator_response, fn _, _ -> {:error, {:control_plane_unavailable, :closed}} end)

    System.put_env("LEMON_CLI_LAUNCHER", "release")
    System.put_env("LEMON_RUNTIME_LOG_DIR", directory)
    old = Path.join(directory, "erlang.log.1")
    new = Path.join(directory, "erlang.log.2")
    File.write!(old, "old")
    File.touch!(old, 1)
    File.write!(new, "new")
    assert capture_io(fn -> assert CLI.run(["logs"]) == 0 end) =~ "new"
    System.put_env("LEMON_RUNTIME_LOG_FILE", old)
    assert capture_io(fn -> assert CLI.run(["logs"]) == 0 end) =~ "old"
  end

  test "missing offline file and connected authorization errors fail safely" do
    Process.put(:operator_response, fn _, _ -> {:error, {:control_plane_unavailable, :closed}} end)

    assert capture_io(:stderr, fn -> assert CLI.run(["logs"]) == 1 end) =~
             "launcher log is unavailable"

    Process.put(:operator_response, fn _, _ ->
      {:error, {:control_plane, %{"message" => "token=private"}}}
    end)

    output = capture_io(:stderr, fn -> assert CLI.run(~w(logs --json)) == 1 end)
    assert Jason.decode!(output)["error"]
    refute output =~ "private"
    refute output =~ "launcher log"
  end

  test "help and registry-driven completion include operator commands" do
    output = capture_io(fn -> assert CLI.run(["help"]) == 0 end)
    for command <- ~w(runs cron logs), do: assert(output =~ command)

    for shell <- ~w(bash zsh fish) do
      output = capture_io(fn -> assert CLI.run(["completion", shell]) == 0 end)
      for command <- ~w(runs cron logs), do: assert(output =~ command)
    end
  end

  defp row do
    %{
      "runId" => "run_123456789abcdef",
      "status" => "completed",
      "startedAtMs" => System.system_time(:millisecond) - 1_500,
      "durationMs" => 1_500,
      "sessionKey" => "agent:operator:main",
      "agentId" => "operator"
    }
  end
end
