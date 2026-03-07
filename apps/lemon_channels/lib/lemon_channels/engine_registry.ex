defmodule LemonChannels.EngineRegistry do
  @moduledoc false

  alias LemonCore.ResumeToken

  @default_engines ~w(lemon echo codex claude opencode pi kimi)
  @gateway_engine_registry :"Elixir.LemonGateway.EngineRegistry"

  @spec extract_resume(String.t()) :: {:ok, ResumeToken.t()} | :none
  def extract_resume(text) when is_binary(text) do
    case safe_gateway_extract_resume(text) do
      {:ok, %ResumeToken{} = token} -> {:ok, token}
      _ -> parse_resume_line(text)
    end
  rescue
    _ -> :none
  end

  def extract_resume(_), do: :none

  @spec get_engine(String.t()) :: String.t() | nil
  def get_engine(engine_id) when is_binary(engine_id) do
    id = String.downcase(String.trim(engine_id))
    if engine_known?(id), do: id, else: nil
  end

  def get_engine(_), do: nil

  @spec format_resume(ResumeToken.t()) :: String.t()
  def format_resume(%ResumeToken{engine: engine, value: value})
      when is_binary(engine) and is_binary(value) do
    case String.downcase(engine) do
      "claude" -> "claude --resume #{value}"
      eng -> "#{eng} resume #{value}"
    end
  end

  @spec engine_known?(String.t()) :: boolean()
  def engine_known?(engine_id) when is_binary(engine_id) do
    known = configured_engine_ids()
    String.downcase(engine_id) in known
  end

  def engine_known?(_), do: false

  defp configured_engine_ids do
    case safe_gateway_list_engines() do
      [_ | _] = ids ->
        ids

      _ ->
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
    end
  rescue
    _ -> @default_engines
  end

  defp safe_gateway_list_engines do
    if (Code.ensure_loaded?(@gateway_engine_registry) and
          Process.whereis(@gateway_engine_registry)) &&
         function_exported?(@gateway_engine_registry, :list_engines, 0) do
      apply(@gateway_engine_registry, :list_engines, [])
    else
      []
    end
  rescue
    _ -> []
  end

  defp safe_gateway_extract_resume(text) do
    if (Code.ensure_loaded?(@gateway_engine_registry) and
          Process.whereis(@gateway_engine_registry)) &&
         function_exported?(@gateway_engine_registry, :extract_resume, 1) do
      apply(@gateway_engine_registry, :extract_resume, [text])
    else
      :none
    end
  rescue
    _ -> :none
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

  defp parse_resume_line(text) when is_binary(text) do
    stripped = text |> String.trim() |> String.trim("`")

    if stripped == "" do
      :none
    else
      lines = String.split(stripped, "\n", trim: true)

      Enum.find_value(lines, :none, fn line ->
        case parse_resume_regex(String.trim(line)) do
          {:ok, _} = ok -> ok
          _ -> nil
        end
      end) || :none
    end
  end

  defp parse_resume_regex(text) do
    cond do
      match = Regex.run(~r/^(?:claude)\s+--resume\s+([^\s`]+)$/i, text) ->
        [_, value] = match
        {:ok, %ResumeToken{engine: "claude", value: value}}

      match = Regex.run(~r/^([a-z0-9_-]+)\s+resume\s+([^\s`]+)$/i, text) ->
        [_, engine, value] = match
        engine = String.downcase(engine)

        if engine_known?(engine) do
          {:ok, %ResumeToken{engine: engine, value: value}}
        else
          :none
        end

      true ->
        :none
    end
  end
end
