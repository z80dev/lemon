defmodule Mix.Tasks.Lemon.PolicyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route
  alias Mix.Tasks.Lemon.Policy

  setup do
    Mix.Task.run("loadpaths")

    ModelPolicy.list()
    |> Enum.each(fn {route, _policy} -> ModelPolicy.clear(route) end)

    :ok
  end

  test "thinking-only policies do not render the placeholder model" do
    peer_id = Integer.to_string(System.unique_integer([:positive]))

    capture_io(fn ->
      Policy.run([
        "set",
        "telegram",
        "--account",
        "default",
        "--peer",
        peer_id,
        "--thinking",
        "high"
      ])
    end)

    output =
      capture_io(fn ->
        Policy.run([
          "get",
          "telegram",
          "--account",
          "default",
          "--peer",
          peer_id
        ])
      end)

    assert output =~ "Model:    (none)"
    assert output =~ "Thinking: high"
    refute output =~ "_thinking_only"
  end

  test "setting a model preserves an existing thinking override" do
    peer_id = Integer.to_string(System.unique_integer([:positive]))
    route = Route.new("telegram", "default", peer_id, nil)

    capture_io(fn ->
      Policy.run([
        "set",
        "telegram",
        "--account",
        "default",
        "--peer",
        peer_id,
        "--thinking",
        "high"
      ])
    end)

    capture_io(fn ->
      Policy.run([
        "set",
        "telegram",
        "--account",
        "default",
        "--peer",
        peer_id,
        "--model",
        "openai:gpt-5"
      ])
    end)

    assert %{model_id: "openai:gpt-5", thinking_level: :high} = ModelPolicy.get(route)
  end
end
