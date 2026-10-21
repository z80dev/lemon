defmodule LemonCore.Usage.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Usage.CLI
  alias LemonCore.{UsageLedger, UsageStore}

  setup do
    dates = ["2001-02-01", "2001-02-02", "2001-02-03"]
    previous = Map.new(dates, &{&1, UsageStore.get_record(&1)})

    for {date, i} <- Enum.with_index(dates, 1) do
      record =
        UsageLedger.add_to_record(
          %{},
          %{
            session_key: "session-#{i}",
            provider: "test",
            model: "model-#{i}",
            input: i * 10,
            output: i,
            cost: 0.25,
            price_known: true
          },
          date,
          i
        )

      UsageStore.put_record(date, Map.put(record, :sessions_omitted, i))
    end

    on_exit(fn ->
      for {date, record} <- previous do
        if record,
          do: UsageStore.put_record(date, record),
          else: LemonCore.Store.delete(:usage_records, date)
      end
    end)

    :ok
  end

  test "days defaults to today and counts inclusive UTC dates" do
    {_, params} = CLI.parse_args!([])
    assert params["startDate"] == Date.to_iso8601(Date.utc_today())
    assert params["endDate"] == params["startDate"]
    {_, params} = CLI.parse_args!(["--days", "7", "--by", "model"])
    assert params["startDate"] == Date.to_iso8601(Date.add(Date.utc_today(), -6))
    assert params["groupBy"] == "model"
  end

  test "rejects invalid arguments and conflicting or oversized ranges" do
    for args <- [
          ["--days", "0"],
          ["--days", "367"],
          ["--days", "wat"],
          ["--by", "wat"],
          ["--since", "bad"],
          ["--since", "2001-02-03", "--until", "2001-02-01"],
          ["--since", "2000-01-01", "--until", "2002-01-01"],
          ["--days", "7", "--since", "2001-02-01"],
          ["extra"],
          ["--wat"]
        ] do
      assert_raise LemonCore.CLI.Error, fn -> CLI.parse_args!(args) end
    end
  end

  test "seeded ledger renders each grouping and inclusive boundaries" do
    for {by, label} <- [
          {"day", "2001-02-01"},
          {"provider", "test"},
          {"model", "test:model-1"},
          {"session", "session-1"}
        ] do
      output =
        capture_io(fn ->
          CLI.run(["--since", "2001-02-01", "--until", "2001-02-02", "--by", by])
        end)

      assert output =~ label
      assert output =~ "Requests: 2"
      assert output =~ "Incomplete: false"
      assert output =~ "Sessions omitted: 3"
      refute output =~ "model-3"
    end
  end

  test "JSON returns shared report and preserves unknown pricing as incomplete" do
    record = UsageStore.get_record("2001-02-01")
    UsageStore.put_record("2001-02-01", Map.put(record, :unknown_cost_records, 1))
    args = ["--since", "2001-02-01", "--until", "2001-02-01", "--by", "model"]
    text = capture_io(fn -> CLI.run(args) end)
    assert text =~ "unknown pricing"
    assert text =~ "Incomplete: true"
    json = capture_io(fn -> CLI.run(args ++ ["--json"]) end) |> Jason.decode!()
    assert json["incomplete"]
    assert json["sessionsOmitted"] == 1
    assert json["totalRequests"] == 1
    assert [%{"model" => "model-1"}] = json["models"]
  end

  test "report preserves unknown counters and cost across every projection" do
    record = UsageStore.get_record("2001-02-01")
    unknown = %{cost: nil, requests: 1, input: nil, output: 4}

    UsageStore.put_record("2001-02-01", %{
      record
      | total_cost: nil,
        breakdown: %{"test" => nil},
        tokens: %{"test" => %{input: nil, output: 4}},
        models: %{"test:model-1" => Map.merge(unknown, %{provider: "test", model: "model-1"})},
        sessions: %{"session-1" => unknown}
    })

    assert {:ok, report} =
             LemonCore.UsageReport.query(%{
               "startDate" => "2001-02-01",
               "endDate" => "2001-02-02"
             })

    assert is_nil(report["totalCost"])
    assert is_nil(report["totalTokens"][:input])
    assert report["totalTokens"][:output] == 6
    assert [%{"cost" => nil, "inputTokens" => nil}] = report["providers"]
    assert Enum.any?(report["models"], &is_nil(&1["inputTokens"]))
    assert Enum.any?(report["sessions"], &is_nil(&1["cost"]))
    assert Enum.any?(report["dailyUsage"], &is_nil(&1["inputTokens"]))

    for by <- ["day", "provider", "model", "session"] do
      output =
        capture_io(fn ->
          CLI.run(["--since", "2001-02-01", "--until", "2001-02-01", "--by", by])
        end)

      assert output =~ "Known cost subtotal: unknown USD"
      assert output =~ "input_tokens=unknown output_tokens=4"
      refute output =~ "cost=0.0000"
    end
  end

  test "current diagnostics text and JSON preserve explicit unknown values" do
    previous = UsageStore.get_summary(:current)

    on_exit(fn ->
      if previous,
        do: UsageStore.put_summary(:current, previous),
        else: LemonCore.Store.delete(:usage_data, :current)
    end)

    UsageStore.put_summary(:current, %{
      total_cost: nil,
      total_requests: 1,
      total_tokens: %{input: nil, output: 0},
      breakdown: %{"test" => nil},
      requests: %{"test" => 1},
      tokens: %{"test" => %{input: nil, output: 0}}
    })

    output = capture_io(fn -> CLI.run([]) end)
    assert output =~ "Cost: unknown"
    assert output =~ "Tokens input: unknown"
    assert output =~ "Tokens output: 0"
    assert output =~ "Tokens total: unknown"
    assert output =~ "cost=unknown input_tokens=unknown output_tokens=0"

    json = capture_io(fn -> CLI.run(["--json"]) end) |> Jason.decode!()
    assert is_nil(json["total_cost"])
    assert json["total_tokens"] == %{"input" => nil, "output" => 0, "total" => nil}
  end
end
