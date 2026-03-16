defmodule LemonCore.Doctor.Checks.NodeTools do
  @moduledoc "Checks that required system binaries are available on PATH."

  alias LemonCore.Doctor.Check

  # Binaries that Lemon requires for full operation.
  # Each entry is {binary, description, :required | :optional}.
  @tools [
    {"git", "version control", :required},
    {"node", "JavaScript runtime (TUI)", :optional},
    {"npm", "npm package manager (TUI deps)", :optional}
  ]

  @doc """
  Returns a list of Check results, one per tool.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    Enum.map(@tools, fn {bin, desc, importance} ->
      check_binary(bin, desc, importance)
    end)
  end

  defp check_binary(binary, description, importance) do
    name = "node_tools.#{binary}"

    case System.find_executable(binary) do
      nil when importance == :required ->
        Check.fail(
          name,
          "#{binary} (#{description}) not found on PATH.",
          "Install #{binary} and ensure it is on your PATH."
        )

      nil ->
        Check.warn(
          name,
          "#{binary} (#{description}) not found — some features may be unavailable.",
          "Install #{binary} if you need TUI or related functionality."
        )

      path ->
        Check.pass(name, "#{binary} found: #{path}")
    end
  end
end
