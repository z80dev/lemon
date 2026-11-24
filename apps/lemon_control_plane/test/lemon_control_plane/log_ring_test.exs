defmodule LemonControlPlane.LogRingTest do
  use ExUnit.Case, async: false

  @operator_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  import ExUnit.CaptureLog

  require Logger

  alias LemonControlPlane.LogRing
  alias LemonControlPlane.Methods.LogsTail

  test "the application captures logger events for logs.tail" do
    marker = "log-ring-#{System.unique_integer([:positive])}"

    capture_log(fn ->
      Logger.error("#{marker} failed api_key=sk-ring-secret")
      Logger.warning("#{marker} warned")
    end)

    assert {:ok, all} = LogRing.get_logs(1_000, nil)
    entries = Enum.filter(all, &(&1["message"] =~ marker))
    assert [%{"level" => "error"} = error, %{"level" => "warning"}] = entries
    assert is_integer(error["timestampMs"])
    assert error["module"] == "LemonControlPlane.LogRingTest"

    assert {:ok, error_entries} = LogRing.get_logs(1_000, "error")
    errors = Enum.filter(error_entries, &(&1["message"] =~ marker))
    assert [%{"level" => "error"}] = errors

    assert {:ok, result} =
             LogsTail.handle(%{"limit" => 1_000, "level" => "warning"}, @operator_ctx)

    tailed = Enum.filter(result["logs"], &(&1["message"] =~ marker))
    assert length(tailed) == 2
    refute inspect(tailed) =~ "sk-ring-secret"
  end

  test "keeps a bounded tail and truncates large messages" do
    marker = "log-ring-bound-#{System.unique_integer([:positive])}"

    capture_log(fn ->
      for i <- 1..1_050, do: Logger.error("#{marker} #{i}")
      Logger.error("#{marker} big " <> String.duplicate("x", 5_000))
    end)

    assert {:ok, entries} = LogRing.get_logs(5_000, nil)
    assert length(entries) <= 1_000
    big = Enum.find(entries, &(&1["message"] =~ "#{marker} big"))
    assert byte_size(big["message"]) <= 2_048 + 3
    assert List.last(entries)["message"] =~ "#{marker} big"
    assert {:ok, [_, _, _]} = LogRing.get_logs(3, nil)
  end
end
