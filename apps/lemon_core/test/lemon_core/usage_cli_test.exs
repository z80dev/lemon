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
end
