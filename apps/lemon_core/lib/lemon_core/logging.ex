defmodule LemonCore.Logging do
  @moduledoc """
  Runtime logging setup for Lemon.

  Today this supports an optional log-to-file handler configured via:

      [logging]
      file = "/path/to/lemon.log"
      level = "debug" # optional; defaults to "all"
  """

  require Logger

  @default_handler_id :lemon_file

  @spec maybe_add_file_handler(keyword()) :: :ok | :skipped | {:error, term()}
  def maybe_add_file_handler(opts \\ []) do
    force? = Keyword.get(opts, :force?, false)

    if test_env?() and not force? do
      :skipped
    else
      cfg = LemonCore.Config.load(nil, cache: false)
      maybe_add_file_handler(cfg, opts)
    end
  end

  @spec maybe_add_file_handler(LemonCore.Config.t(), keyword()) :: :ok | :skipped | {:error, term()}
  def maybe_add_file_handler(%LemonCore.Config{} = cfg, opts) do
    handler_id = Keyword.get(opts, :handler_id, @default_handler_id)

    file =
      case cfg.logging do
        %{file: file} -> file
        %{"file" => file} -> file
        _ -> nil
      end

    if not (is_binary(file) and file != "") do
      :skipped
    else
      expanded = Path.expand(file)

      with :ok <- ensure_log_dir(expanded),
           :ok <- add_handler(handler_id, expanded, cfg.logging) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_log_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp add_handler(handler_id, expanded_path, logging_cfg) do
    desired_file = to_charlist(expanded_path)

    case :logger.get_handler_config(handler_id) do
      {:ok, %{config: %{file: existing_file}}} when existing_file == desired_file ->
        :ok

      {:ok, _existing} ->
        # File/type cannot be changed at runtime for logger_std_h.
        Logger.warning(
          "Log-to-file handler #{inspect(handler_id)} already exists; restart Lemon to apply new [logging] settings"
        )

        :ok

      {:error, _} ->
        base = default_handler_base_config()

        handler_cfg =
          base
          |> Map.put(:level, logging_level(logging_cfg))
          |> Map.put(:config, handler_file_config(desired_file, logging_cfg))

        case :logger.add_handler(handler_id, :logger_std_h, handler_cfg) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, {:add_handler_failed, handler_id, reason}}
        end
    end
  end

  defp default_handler_base_config do
    # Reuse formatter + filters from the default Elixir handler so file logs
    # match stdout formatting.
    case :logger.get_handler_config(:default) do
      {:ok, cfg} ->
        Map.take(cfg, [:filters, :filter_default, :formatter])

      _ ->
        %{}
    end
  end

  defp handler_file_config(file, logging_cfg) do
    cfg0 = %{
      type: :file,
      file: file
    }

    cfg0
    |> maybe_put_handler_opt(:max_no_bytes, logging_cfg)
    |> maybe_put_handler_opt(:max_no_files, logging_cfg)
    |> maybe_put_handler_opt(:compress_on_rotate, logging_cfg)
    |> maybe_put_handler_opt(:filesync_repeat_interval, logging_cfg)
  end

  defp maybe_put_handler_opt(cfg, key, logging_cfg) do
    value =
      case logging_cfg do
        %{^key => v} -> v
        %{} -> Map.get(logging_cfg, Atom.to_string(key))
        _ -> nil
      end

    if is_nil(value), do: cfg, else: Map.put(cfg, key, value)
  end

  defp logging_level(logging_cfg) do
    case logging_cfg do
      %{level: level} when is_atom(level) -> level
      %{"level" => level} when is_atom(level) -> level
      _ -> :all
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end

