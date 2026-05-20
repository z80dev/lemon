defmodule Mix.Tasks.Lemon.UsageTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.{Store, UsageStore}
  alias Mix.Tasks.Lemon.Usage

  setup do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.start")

    today = Date.to_iso8601(Date.utc_today())
    previous_summary = UsageStore.get_summary(:current)
    previous_today = UsageStore.get_record(today)

    UsageStore.put_summary(:current, %{
      total_cost: 0.42,
      total_requests: 3,
      total_tokens: %{input: 1_000, output: 500},
      breakdown: %{"openai" => 0.42},
      requests: %{"openai" => 3},
      tokens: %{"openai" => %{input: 1_000, output: 500}},
      prompt: "private usage task prompt",
      response: "private usage task response",
      api_key: "usage-task-secret-key"
    })

    UsageStore.put_record(today, %{
      date: today,
      total_cost: 0.42,
      requests: %{"openai" => 3},
      message_body: "private usage task message"
    })

    on_exit(fn ->
      if previous_summary do
        UsageStore.put_summary(:current, previous_summary)
      else
        Store.delete(:usage_data, :current)
      end

      if previous_today do
        UsageStore.put_record(today, previous_today)
      else
        Store.delete(:usage_records, today)
      end
    end)

    :ok
  end

  test "prints redacted usage diagnostics" do
    output =
      capture_io(fn ->
        Usage.run([])
      end)

    assert output =~ "Lemon Usage"
    assert output =~ "Requests: 3"
    assert output =~ "Tokens total: 1500"
    assert output =~ "openai: requests=3"
    assert output =~ "Includes prompts: false"
    assert output =~ "Includes responses: false"
    assert output =~ "Includes credentials: false"
    refute output =~ "private usage task prompt"
    refute output =~ "private usage task response"
    refute output =~ "private usage task message"
    refute output =~ "usage-task-secret-key"
  end

  test "emits redacted JSON" do
    output =
      capture_io(fn ->
        Usage.run(["--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["total_requests"] == 3
    assert decoded["total_tokens"]["total"] == 1_500
    assert decoded["cleanup"]["includes_prompts"] == false
    refute output =~ "private usage task prompt"
    refute output =~ "private usage task response"
    refute output =~ "private usage task message"
    refute output =~ "usage-task-secret-key"
  end
end
