defmodule LemonCore.LoggerSetup do
  @moduledoc false

  # NOTE: We intentionally do not fail hard if file logging cannot be enabled.
  # When debugging dropped messages, the gateway must keep running.

  alias LemonCore.MapHelpers
  require Logger

  @handler_id :lemon_file

  @spec setup() :: :ok
  def setup do
    cwd =
      case File.cwd() do
        {:ok, dir} -> dir
        _ -> nil
      end

    cfg = LemonCore.Config.cached(cwd, cache: false)
    setup_from_config(cfg)
  end

  @spec setup_from_config(LemonCore.Config.t()) :: :ok
  def setup_from_config(%LemonCore.Config{} = cfg) do
    logging = Map.get(cfg, :logging) || %{}
    file_path = MapHelpers.get_key(logging, :file_path)
    level = MapHelpers.get_key(logging, :level)

    case normalize_path(file_path) do
      nil ->
        # Config missing/blank => no file handler.
        maybe_remove_handler()
        :ok

      path ->
        ensure_dir!(path)
        ensure_handler!(path)
        maybe_set_level(level)
        :ok
    end
  rescue
    e ->
      Logger.warning("Failed to enable Lemon file logging: #{Exception.message(e)}")
      :ok
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    p = String.trim(path)
    if p == "", do: nil, else: Path.expand(p)
  end

  defp normalize_path(_), do: nil

  defp ensure_dir!(path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
  end

  defp ensure_handler!(path) do
    file = path |> to_charlist()

    cfg = %{
      level: :debug,
      config: %{type: :file, file: file},
      formatter:
        Logger.Formatter.new(
          format: "$date $time $metadata[$level] $message\n",
          metadata: :all,
          colors: [enabled: false]
        )
    }

    case :logger.add_handler(@handler_id, :logger_std_h, cfg) do
      :ok ->
        :ok

      {:error, {:already_exist, _}} ->
        # logger_std_h treats type/file/modes as write-once. If the target file path
        # changes we must remove and re-add the handler.
        existing = :logger.get_handler_config(@handler_id)

        if existing_file_matches?(existing, file) do
          :ok = :logger.set_handler_config(@handler_id, cfg)
          :ok
        else
          _ = :logger.remove_handler(@handler_id)

          case :logger.add_handler(@handler_id, :logger_std_h, cfg) do
            :ok -> :ok
            {:error, reason} -> raise "logger add_handler failed after remove: #{inspect(reason)}"
          end
        end

      {:error, reason} ->
        raise "logger add_handler failed: #{inspect(reason)}"
    end
  end

  defp existing_file_matches?({:ok, %{config: %{file: file}}}, desired) when file == desired,
    do: true

  defp existing_file_matches?(%{config: %{file: file}}, desired) when file == desired, do: true
  defp existing_file_matches?(_, _), do: false

  defp maybe_set_level(nil), do: :ok

  defp maybe_set_level(level) when is_atom(level) do
    :logger.update_handler_config(@handler_id, %{level: level})
    :ok
  end

  defp maybe_set_level(level) when is_binary(level) do
    # LemonCore.Config already normalizes levels, but allow raw strings anyway.
    lvl =
      case String.downcase(String.trim(level)) do
        "debug" -> :debug
        "info" -> :info
        "notice" -> :notice
        "warning" -> :warning
        "warn" -> :warning
        "error" -> :error
        "critical" -> :critical
        "alert" -> :alert
        "emergency" -> :emergency
        _ -> nil
      end

    if is_atom(lvl), do: maybe_set_level(lvl), else: :ok
  end

  defp maybe_set_level(_), do: :ok

  defp maybe_remove_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end
end
