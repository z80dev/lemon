defmodule LemonCore.RoutingFeedbackReportTest do
  use ExUnit.Case, async: false

  alias LemonCore.{RoutingFeedbackReport, RoutingFeedbackStore}

  # Start a fresh store registered under the canonical module name for each test.
  # async: false ensures no naming conflicts between tests.
  # Note: min_sample_size/0 reads from Application config (default 5), not GenServer state.
  setup do
    dir = System.tmp_dir!() |> Path.join("rfr_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, pid} =
      GenServer.start_link(RoutingFeedbackStore, [path: dir],
        name: RoutingFeedbackStore
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{pid: pid}
  end

  defp record(pid, key, outcome, duration_ms \\ nil) do
    GenServer.cast(pid, {:record, key, Atom.to_string(outcome), duration_ms})
    Process.sleep(20)
  end

  # ── parse_key/1 ───────────────────────────────────────────────────────────────

  describe "parse_key/1" do
    test "parses a full key" do
      result = RoutingFeedbackReport.parse_key("code|bash|/my/proj|anthropic|opus")

      assert result == %{
               family: "code",
               toolset: "bash",
               workspace: "/my/proj",
               provider: "anthropic",
               model: "opus"
             }
    end

    test "converts dash segments to nil" do
      result = RoutingFeedbackReport.parse_key("query|-|-|-|-")

      assert result.family == "query"
      assert result.toolset == nil
      assert result.workspace == nil
      assert result.provider == nil
      assert result.model == nil
    end

    test "handles partial keys gracefully" do
      result = RoutingFeedbackReport.parse_key("code")
      assert result.family == "code"
      assert result.toolset == nil
    end
  end

  # ── list_all/1 ────────────────────────────────────────────────────────────────

  describe "list_all/1" do
    test "returns empty list when no data", _ctx do
      assert {:ok, []} = RoutingFeedbackReport.list_all()
    end

    test "annotates confidence as :insufficient below min_sample_size", %{pid: pid} do
      key = "code|bash|-|-|-"
      # Record fewer than default min_sample_size (5)
      record(pid, key, :success)
      record(pid, key, :success)

      {:ok, [entry]} = RoutingFeedbackReport.list_all()
      assert entry.fingerprint_key == key
      assert entry.confidence == :insufficient
    end

    test "annotates confidence as :high for high success rate", %{pid: pid} do
      key = "code|bash|-|-|-"
      # success_rate = 1.0, total = 5 >= min_sample_size
      for _ <- 1..5, do: record(pid, key, :success)

      {:ok, [entry]} = RoutingFeedbackReport.list_all()
      assert entry.confidence == :high
      assert entry.success_rate == 1.0
    end

    test "annotates confidence as :medium for moderate success rate", %{pid: pid} do
      key = "code|bash|-|-|-"
      # success_rate = 0.6, total = 5 >= min_sample_size
      record(pid, key, :success)
      record(pid, key, :success)
      record(pid, key, :success)
      record(pid, key, :failure)
      record(pid, key, :failure)

      {:ok, [entry]} = RoutingFeedbackReport.list_all()
      assert entry.confidence == :medium
      assert entry.success_rate > 0.5
    end

    test "annotates confidence as :low when success_rate < 0.5", %{pid: pid} do
      key = "code|bash|-|-|-"
      # success_rate = 0.0, total = 5 >= min_sample_size
      for _ <- 1..5, do: record(pid, key, :failure)

      {:ok, [entry]} = RoutingFeedbackReport.list_all()
      assert entry.confidence == :low
      assert entry.success_rate == 0.0
    end

    test "filters by since_ms", %{pid: pid} do
      key = "code|bash|-|-|-"
      for _ <- 1..5, do: record(pid, key, :success)

      future_ms = System.system_time(:millisecond) + 60_000

      {:ok, entries} = RoutingFeedbackReport.list_all(since_ms: future_ms)
      assert entries == []

      {:ok, entries} = RoutingFeedbackReport.list_all(since_ms: 0)
      assert length(entries) == 1
    end
  end

  # ── by_workspace/2 ────────────────────────────────────────────────────────────

  describe "by_workspace/2" do
    test "returns only entries matching the workspace", %{pid: pid} do
      for _ <- 1..5, do: record(pid, "code|bash|/proj-a|-|-", :success)
      for _ <- 1..5, do: record(pid, "code|bash|/proj-b|-|-", :success)

      {:ok, entries} = RoutingFeedbackReport.by_workspace("/proj-a")
      assert length(entries) == 1
      assert hd(entries).fingerprint_key == "code|bash|/proj-a|-|-"
    end

    test "returns empty list when workspace not found", %{pid: pid} do
      for _ <- 1..5, do: record(pid, "code|bash|/proj|-|-", :success)

      assert {:ok, []} = RoutingFeedbackReport.by_workspace("/unknown")
    end
  end

  # ── by_family/2 ───────────────────────────────────────────────────────────────

  describe "by_family/2" do
    test "filters by family atom", %{pid: pid} do
      for _ <- 1..5, do: record(pid, "code|bash|-|-|-", :success)
      for _ <- 1..5, do: record(pid, "query|read|-|-|-", :success)

      {:ok, entries} = RoutingFeedbackReport.by_family(:code)
      assert Enum.all?(entries, fn e -> String.starts_with?(e.fingerprint_key, "code|") end)
      assert length(entries) == 1
    end

    test "filters by family string", %{pid: pid} do
      for _ <- 1..5, do: record(pid, "chat|-|-|-|-", :success)
      for _ <- 1..5, do: record(pid, "code|bash|-|-|-", :success)

      {:ok, entries} = RoutingFeedbackReport.by_family("chat")
      assert length(entries) == 1
      assert hd(entries).fingerprint_key == "chat|-|-|-|-"
    end
  end

  # ── format/1 ─────────────────────────────────────────────────────────────────

  describe "format/1" do
    test "returns a no-data message for empty list" do
      assert RoutingFeedbackReport.format([]) =~ "No routing feedback"
    end

    test "includes fingerprint key, confidence, and success_rate" do
      entry = %{
        fingerprint_key: "code|bash|/proj|anthropic|opus",
        total: 10,
        success_count: 9,
        avg_duration_ms: 1500,
        last_seen_ms: System.system_time(:millisecond),
        success_rate: 0.9,
        confidence: :high
      }

      output = RoutingFeedbackReport.format([entry])
      assert output =~ "code|bash|/proj|anthropic|opus"
      assert output =~ "HIGH"
      assert output =~ "90.0%"
      assert output =~ "samples=10"
    end

    test "formats multiple entries separated by blank lines" do
      entries = [
        %{
          fingerprint_key: "code|bash|-|-|-",
          total: 5,
          success_count: 5,
          avg_duration_ms: nil,
          last_seen_ms: 0,
          success_rate: 1.0,
          confidence: :high
        },
        %{
          fingerprint_key: "query|read|-|-|-",
          total: 2,
          success_count: 1,
          avg_duration_ms: nil,
          last_seen_ms: 0,
          success_rate: 0.5,
          confidence: :insufficient
        }
      ]

      output = RoutingFeedbackReport.format(entries)
      assert output =~ "code|bash"
      assert output =~ "query|read"
      assert output =~ "\n\n"
    end
  end
end
