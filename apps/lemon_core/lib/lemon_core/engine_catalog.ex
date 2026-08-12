defmodule LemonCore.EngineCatalog do
  @moduledoc """
  Shared engine identifier catalog for validation and normalization.

  Runtime resume parsing for custom engines may still defer to gateway engine
  modules, but router/channels validation should use this catalog.

  ## Where the list comes from

  Two independent inputs, and they are not peers:

    * `config :lemon_core, :known_engines` is the *operator's* list. When it is
      set it is the whole answer — a ceiling, not a seed — so narrowing it is
      how an operator disables an engine the build happens to ship.
    * `:lemon_core, :registered_engines` is what installed packages announced at
      boot (see `LemonCore.SubagentRegistry`). It extends the built-in defaults,
      and only when the operator has not spoken.
  """

  @default_ids ["lemon", "echo", "codex", "claude", "opencode", "pi", "kimi"]

  @doc """
  Engine ids router/channels validation accepts.

  The operator's `:known_engines` wins outright when configured; otherwise the
  built-in defaults plus whatever registered itself at boot.
  """
  @spec list_ids() :: [String.t()]
  def list_ids do
    case Application.fetch_env(:lemon_core, :known_engines) do
      {:ok, ids} when is_list(ids) -> normalize_ids(ids)
      _ -> normalize_ids(@default_ids ++ registered_ids())
    end
  end

  @doc "The ids this module knows without any configuration or registration."
  @spec default_ids() :: [String.t()]
  def default_ids, do: @default_ids

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

  defp registered_ids do
    :lemon_core
    |> Application.get_env(:registered_engines, [])
    |> List.wrap()
  end

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
