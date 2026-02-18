defmodule CodingAgent.Wasm.Policy do
  @moduledoc """
  WASM-specific policy helpers.
  """

  alias CodingAgent.ToolPolicy

  @doc """
  Apply capability-based default approval for WASM tools.

  Defaults to requiring approval for tools that declare HTTP or tool-invoke
  capabilities unless the policy explicitly sets approvals.<tool> = never.
  """
  @spec requires_approval?(map() | nil, String.t(), map()) :: boolean()
  def requires_approval?(policy, tool_name, wasm_metadata)
      when is_binary(tool_name) and is_map(wasm_metadata) do
    explicit_mode = ToolPolicy.approval_mode(policy || %{}, tool_name)

    default_required =
      wasm_metadata
      |> Map.get(:capabilities, Map.get(wasm_metadata, "capabilities", %{}))
      |> capability_requires_approval?()

    cond do
      explicit_mode == :always -> true
      explicit_mode == :never -> false
      true -> default_required
    end
  end

  def requires_approval?(_policy, _tool_name, _wasm_metadata), do: false

  @spec capability_requires_approval?(map() | nil) :: boolean()
  def capability_requires_approval?(capabilities) when is_map(capabilities) do
    http = Map.get(capabilities, :http, Map.get(capabilities, "http", false))

    tool_invoke =
      Map.get(capabilities, :tool_invoke, Map.get(capabilities, "tool_invoke", false))

    http or tool_invoke
  end

  def capability_requires_approval?(_), do: false
end
