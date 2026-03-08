defmodule LemonCore.EngineCatalog do
  @moduledoc """
  Shared engine identifier catalog for validation and normalization.

  Runtime resume parsing for custom engines may still defer to gateway engine
  modules, but router/channels validation should use this catalog.
  """

  @default_ids ["lemon", "echo", "codex", "claude", "opencode", "pi", "kimi"]

  @spec list_ids() :: [String.t()]
  def list_ids do
    :lemon_core
    |> Application.get_env(:known_engines, @default_ids)
    |> normalize_ids()
  end

  @spec normalize(String.t() | term()) :: String.t() | nil
  def normalize(engine_id) when is_binary(engine_id) do
    normalized =
      engine_id
      |> String.trim()
      |> String.downcase()

    if normalized != "" and normalized in list_ids(), do: normalized, else: nil
  end

  def normalize(_), do: nil

  @spec known?(String.t() | term()) :: boolean()
  def known?(engine_id), do: not is_nil(normalize(engine_id))

  defp normalize_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(fn
      id when is_binary(id) -> id |> String.trim() |> String.downcase()
      _ -> nil
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize_ids(_), do: @default_ids
end
