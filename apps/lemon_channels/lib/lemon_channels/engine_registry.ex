defmodule LemonChannels.EngineRegistry do
  @moduledoc """
  Channel-local engine configuration.

  Validates engine IDs against the configured list of known engines.
  Resume token extraction and formatting have been canonicalized in
  `LemonCore.ResumeToken` (ARCH-013).
  """

  @default_engines ~w(lemon echo codex claude opencode pi kimi)

  @spec get_engine(String.t()) :: String.t() | nil
  def get_engine(engine_id) when is_binary(engine_id) do
    id = String.downcase(String.trim(engine_id))
    if engine_known?(id), do: id, else: nil
  end

  def get_engine(_), do: nil

  @spec engine_known?(String.t()) :: boolean()
  def engine_known?(engine_id) when is_binary(engine_id) do
    known = configured_engine_ids()
    String.downcase(engine_id) in known
  end

  def engine_known?(_), do: false

  defp configured_engine_ids do
    env = Application.get_env(:lemon_channels, :engines)

    case env do
      list when is_list(list) and list != [] ->
        list
        |> Enum.map(&normalize_engine_id/1)
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      _ ->
        @default_engines
    end
  rescue
    _ -> @default_engines
  end

  defp normalize_engine_id(%{id: id}) when is_binary(id), do: String.downcase(id)

  defp normalize_engine_id(mod) when is_atom(mod) do
    cond do
      function_exported?(mod, :id, 0) ->
        mod.id() |> to_string() |> String.downcase()

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp normalize_engine_id(id) when is_binary(id), do: String.downcase(String.trim(id))
  defp normalize_engine_id(_), do: nil
end
