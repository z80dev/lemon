defmodule LemonEvals.ReportTest do
  use ExUnit.Case, async: true

  alias LemonEvals.Report

  @revision String.duplicate("a", 40)
  @private "private-eval-payload-that-must-not-be-exported"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-eval-report-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "projects only stable check identities and status with explicit provenance" do
    raw = %{
      summary: %{passed: 99, failed: 0},
      secret: @private,
      results: [
        %{name: "tool_contract", status: :pass, details: %{prompt: @private}},
        %{name: "memory_contract", status: :fail, details: %{error: @private}}
      ]
    }

    report =
      Report.build(raw,
        revision: @revision,
        iterations: 3,
        live_model: true,
        live_timeout_ms: 1000,
        duration_ms: 42,
        api_key: @private,
        cwd: @private
      )

    assert report.schema_version == 1
    assert report.suite == "lemon_contracts"
    assert report.revision == @revision
    assert report.summary == %{passed: 1, failed: 1}
    assert report.duration_ms == 42
    assert report.configuration == %{iterations: 3, live_model: true, live_timeout_ms: 1000}
    assert report.runtime.elixir == System.version()
    assert report.runtime.otp == System.otp_release()
    assert {:ok, _, 0} = DateTime.from_iso8601(report.recorded_at)

    assert report.results == [
             %{name: "tool_contract", status: "pass"},
             %{name: "memory_contract", status: "fail"}
           ]

    refute Jason.encode!(report) =~ @private
  end

  test "missing revision stays unknown and empty suites do not invent successes" do
    report = Report.build(%{results: []})

    assert report.revision == nil
    assert report.summary == %{passed: 0, failed: 0}
    refute report.configuration.live_model
  end

  test "validates revision without reflecting malformed values" do
    assert Report.valid_revision?(@revision)
    assert Report.valid_revision?(String.upcase(@revision))
    assert Report.valid_revision?(nil)

    for revision <- ["main", "123abcd", @private, 123] do
      refute Report.valid_revision?(revision)

      error =
        assert_raise ArgumentError, fn ->
          Report.build(%{results: []}, revision: revision)
        end

      refute Exception.message(error) =~ @private
    end
  end

  test "invalid result shapes and identifiers fail rather than being counted as passes" do
    for result <- [
          %{name: "check", status: :unknown},
          %{name: "../private-path", status: :pass},
          %{status: :pass}
        ] do
      assert_raise ArgumentError, fn -> Report.build(%{results: [result]}) end
    end
  end

  test "failed checks are retained in the written artifact", %{dir: dir} do
    path = Path.join([dir, "reports", "failed.json"])
    report = Report.build(%{results: [%{name: "repair", status: :fail, details: @private}]})

    assert :ok = Report.write(path, report)
    contents = File.read!(path)
    decoded = Jason.decode!(contents)

    assert decoded["summary"] == %{"passed" => 0, "failed" => 1}
    assert decoded["results"] == [%{"name" => "repair", "status" => "fail"}]
    refute contents =~ @private
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "a completed report replaces the prior file without leaving a sibling", %{dir: dir} do
    path = Path.join(dir, "report.json")
    first = Report.build(%{results: []})
    second = Report.build(%{results: [%{name: "repair", status: :pass}]})

    assert :ok = Report.write(path, first)
    assert :ok = Report.write(path, second)
    assert Jason.decode!(File.read!(path))["summary"]["passed"] == 1
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "a destination error is returned and the temporary file is cleaned", %{dir: dir} do
    destination = Path.join(dir, "existing-directory")
    File.mkdir_p!(destination)

    assert {:error, _reason} = Report.write(destination, Report.build(%{results: []}))
    assert File.dir?(destination)
    assert Path.wildcard(destination <> ".tmp-*") == []
  end

  test "invalid CLI metadata is rejected before starting the harness" do
    assert_raise Mix.Error, "--revision must be a full 40-character Git commit SHA", fn ->
      Mix.Tasks.Lemon.Eval.run(["--revision", "not-a-sha"])
    end

    assert_raise Mix.Error, "--live-timeout-ms must be a positive integer", fn ->
      Mix.Tasks.Lemon.Eval.run(["--live-timeout-ms", "0"])
    end
  end
end
