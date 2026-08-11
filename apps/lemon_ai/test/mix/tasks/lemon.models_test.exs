defmodule Mix.Tasks.Lemon.ModelsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Models

  test "lists known models without credential fields" do
    output =
      capture_io(fn ->
        Models.run(["--provider", "anthropic", "--limit", "2"])
      end)

    assert output =~ "Lemon Models"
    assert output =~ "Source: ai_models"
    assert output =~ "Includes credentials: false"
    assert output =~ "Includes secret values: false"
    assert output =~ "anthropic:"
    refute output =~ "api_key"
  end

  test "emits JSON with summaries and filters" do
    output =
      capture_io(fn ->
        Models.run(["--provider", "anthropic", "--thinking", "--limit", "3", "--json"])
      end)

    decoded = Jason.decode!(output)

    assert decoded["summary"]["source"] == "ai_models"
    assert decoded["summary"]["includes_credentials"] == false
    assert decoded["summary"]["includes_secret_values"] == false
    assert decoded["summary"]["total"] <= 3
    assert decoded["summary"]["thinking_model_count"] == decoded["summary"]["total"]
    assert Enum.all?(decoded["models"], &(&1["provider"] == "anthropic"))
    assert Enum.all?(decoded["models"], &(&1["supports_thinking"] == true))
  end
end
