defmodule CodingAgent.Tools.ReportIssueTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ToolPolicy, ToolRegistry}
  alias CodingAgent.Tools.ReportIssue
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    owner = "report-#{System.unique_integer([:positive])}"
    directory = Path.join(cwd, owner)
    opts = [session_id: owner, context_guardrails: [spill_dir: directory]]
    {:ok, cwd: cwd, opts: opts, path: Path.join(directory, "tool-issues.jsonl")}
  end

  test "appends private timestamped JSONL records with session and optional tool", %{
    cwd: cwd,
    opts: opts,
    path: path
  } do
    assert %AgentToolResult{} =
             report(%{"note" => "Read returned wrong lines", "tool" => "read"}, cwd, opts)

    assert %AgentToolResult{} = report(%{"note" => "Plain note\nwith a second line"}, cwd, opts)
    [first, second] = records(path)
    assert first["session_id"] == opts[:session_id]
    assert first["tool"] == "read"
    assert first["note"] == "Read returned wrong lines"
    assert {:ok, _, _} = DateTime.from_iso8601(first["timestamp"])
    assert second["tool"] == nil
    assert second["note"] == "Plain note\nwith a second line"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "retains newest complete JSON records within a fixed byte budget", %{
    cwd: cwd,
    opts: opts,
    path: path
  } do
    opts = Keyword.put(opts, :report_issue_max_bytes, 512)

    for number <- 1..30 do
      assert %AgentToolResult{} = report(%{"note" => "issue #{number}"}, cwd, opts)
      assert File.stat!(path).size <= 512
      assert records(path) != []
    end

    retained = records(path)
    assert List.last(retained)["note"] == "issue 30"
    refute Enum.any?(retained, &(&1["note"] == "issue 1"))

    File.write!(path, String.duplicate("old\n", 1000))
    assert %AgentToolResult{} = report(%{"note" => "after oversize"}, cwd, opts)
    assert File.stat!(path).size <= 512

    assert List.last(String.split(File.read!(path), "\n", trim: true))
           |> Jason.decode!()
           |> Map.fetch!("note") == "after oversize"
  end

  test "concurrent reports stay complete and session logs remain separate", %{
    cwd: cwd,
    opts: opts,
    path: path
  } do
    results =
      1..20
      |> Task.async_stream(fn n -> report(%{"note" => "issue #{n}"}, cwd, opts) end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, %AgentToolResult{}}, &1))
    assert length(records(path)) == 20
    other = [session_id: "other", context_guardrails: [spill_dir: Path.join(cwd, "other")]]
    assert %AgentToolResult{} = report(%{"note" => "foreign"}, cwd, other)
    refute Enum.any?(records(path), &(&1["note"] == "foreign"))
  end

  test "validation, missing session, abort and write errors never claim success", %{
    cwd: cwd,
    opts: opts,
    path: path
  } do
    for params <- [
          %{},
          %{"note" => " "},
          %{"note" => String.duplicate("x", 4097)},
          %{"note" => "valid", "tool" => 7}
        ] do
      assert {:error, _} = report(params, cwd, opts)
    end

    assert {:error, _} = report(%{"note" => "no session"}, cwd, [])
    signal = LemonAgent.AbortSignal.new()
    LemonAgent.AbortSignal.abort(signal)

    assert {:error, :aborted} =
             ReportIssue.execute("abort", %{"note" => "ignored"}, signal, nil, cwd, opts)

    LemonAgent.AbortSignal.clear(signal)
    refute File.exists?(path)
    File.mkdir_p!(path)
    assert {:error, _} = report(%{"note" => "cannot write directory"}, cwd, opts)
  end

  test "registry defaults to no approval but explicit and inherited requirements win", %{
    cwd: cwd,
    opts: opts,
    path: path
  } do
    base =
      opts ++
        [
          include_extensions: false,
          include_mcp: false,
          approval_request_fun: fn _ -> flunk("default approval must be never") end
        ]

    for mode <- [:ask, :write, :yolo] do
      {:ok, tool} =
        ToolRegistry.get_tool(
          cwd,
          "report_issue",
          Keyword.put(base, :tool_policy, ToolPolicy.custom(approval_mode: mode))
        )

      assert %AgentToolResult{is_error: false} =
               tool.execute.("report", %{"note" => "default #{mode}"}, nil, nil)
    end

    assert LemonCore.ToolPolicy.tier("report_issue") == :read
    parent = ToolPolicy.custom(require_approval: ["report_issue"])

    assert {:ok, policy} =
             ToolPolicy.restrict(
               parent,
               ToolPolicy.custom(approvals: %{"report_issue" => :never})
             )

    assert ToolPolicy.requires_approval?(policy, "report_issue")

    {:ok, tool} =
      ToolRegistry.get_tool(
        cwd,
        "report_issue",
        Keyword.merge(base,
          tool_policy: ToolPolicy.custom(approvals: %{"report_issue" => :always}),
          approval_request_fun: fn _ -> {:ok, :denied} end
        )
      )

    assert tool.execute.("denied", %{"note" => "not recorded"}, nil, nil).is_error
    assert length(records(path)) == 3
  end

  defp report(params, cwd, opts), do: ReportIssue.execute("report", params, nil, nil, cwd, opts)

  defp records(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
