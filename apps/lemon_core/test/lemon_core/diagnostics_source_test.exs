defmodule LemonCore.DiagnosticsSourceTest do
  use ExUnit.Case, async: true

  test "production diagnostics never inspect another process's private state" do
    root = Path.expand("../../../..", __DIR__)

    offenders =
      root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        Regex.match?(~r/:sys\s*\.\s*get_state\s*\(/, File.read!(path))
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    assert offenders == []
  end
end
