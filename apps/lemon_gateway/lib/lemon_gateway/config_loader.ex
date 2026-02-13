defmodule LemonGateway.ConfigLoader do
  @moduledoc """
  Loads gateway configuration from the canonical Lemon TOML config.
  """

  alias LemonGateway.{Binding, Project}
  alias LemonCore.Config, as: LemonConfig

  @spec load() :: map()
  def load do
    case override_config() do
      {:ok, config} ->
        parse_gateway(config)

      :error ->
        gateway = load_from_path() || (LemonConfig.load().gateway || %{})
        parse_gateway(gateway)
    end
  end

  defp override_config do
    case Application.get_env(:lemon_gateway, LemonGateway.Config) do
      nil ->
        :error

      config when is_map(config) ->
        {:ok, config}

      config when is_list(config) ->
        if Keyword.keyword?(config) do
          {:ok, Enum.into(config, %{})}
        else
          {:ok, %{bindings: config}}
        end

      _ ->
        :error
    end
  end

  defp load_from_path do
    case Application.get_env(:lemon_gateway, :config_path) do
      path when is_binary(path) and path != "" ->
        if File.exists?(path) do
          LemonConfig.load_file(path) |> Map.get("gateway")
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp parse_gateway(gateway) when is_map(gateway) do
    projects = parse_projects(fetch(gateway, :projects) || %{})
    bindings = parse_bindings(fetch(gateway, :bindings) || [])

    queue =
      gateway
      |> fetch(:queue)
      |> parse_queue()

    telegram =
      gateway
      |> fetch(:telegram)
      |> parse_telegram()

    engines =
      gateway
      |> fetch(:engines)
      |> parse_engines()

    %{
      max_concurrent_runs: fetch(gateway, :max_concurrent_runs),
      default_engine: fetch(gateway, :default_engine),
      auto_resume: fetch(gateway, :auto_resume),
      enable_telegram: fetch(gateway, :enable_telegram),
      require_engine_lock: fetch(gateway, :require_engine_lock),
      engine_lock_timeout_ms: fetch(gateway, :engine_lock_timeout_ms)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:projects, projects)
    |> Map.put(:bindings, bindings)
    |> Map.put(:queue, queue)
    |> Map.put(:telegram, telegram)
    |> Map.put(:engines, engines)
  end

  defp parse_gateway(_), do: %{}

  defp parse_projects(projects) when is_map(projects) do
    for {name, config} <- projects, into: %{} do
      project = %Project{
        id: to_string(name),
        root: fetch(config, :root),
        default_engine: fetch(config, :default_engine)
      }

      validate_project_root(project)
      {to_string(name), project}
    end
  end

  defp parse_projects(_), do: %{}

  defp parse_bindings(bindings) when is_list(bindings) do
    Enum.map(bindings, fn b ->
      %Binding{
        transport: parse_transport(fetch(b, :transport)),
        chat_id: fetch(b, :chat_id),
        topic_id: fetch(b, :topic_id),
        project: fetch(b, :project),
        agent_id: fetch(b, :agent_id),
        default_engine: fetch(b, :default_engine),
        queue_mode: parse_queue_mode(fetch(b, :queue_mode))
      }
    end)
  end

  defp parse_bindings(_), do: []

  defp parse_queue(queue) when is_map(queue) do
    %{
      mode: parse_queue_mode(fetch(queue, :mode)),
      cap: fetch(queue, :cap),
      drop: parse_drop_policy(fetch(queue, :drop))
    }
  end

  defp parse_queue(_), do: %{mode: nil, cap: nil, drop: nil}

  defp parse_telegram(telegram) when is_map(telegram) do
    %{
      bot_token: fetch(telegram, :bot_token),
      bot_id: fetch(telegram, :bot_id),
      bot_username: fetch(telegram, :bot_username),
      allowed_chat_ids: fetch(telegram, :allowed_chat_ids),
      deny_unbound_chats: fetch(telegram, :deny_unbound_chats),
      poll_interval_ms: fetch(telegram, :poll_interval_ms),
      edit_throttle_ms: fetch(telegram, :edit_throttle_ms),
      debounce_ms: fetch(telegram, :debounce_ms),
      # When enabled, append a short "resume" line to final answers.
      show_resume_line: fetch(telegram, :show_resume_line),
      # When enabled, outgoing text is treated as markdown and rendered using Telegram entities.
      use_markdown: fetch(telegram, :use_markdown),
      allow_queue_override: fetch(telegram, :allow_queue_override),
      account_id: fetch(telegram, :account_id),
      offset: fetch(telegram, :offset),
      drop_pending_updates: fetch(telegram, :drop_pending_updates),
      voice_transcription: fetch(telegram, :voice_transcription),
      voice_transcription_model: fetch(telegram, :voice_transcription_model),
      voice_transcription_base_url: fetch(telegram, :voice_transcription_base_url),
      voice_transcription_api_key: fetch(telegram, :voice_transcription_api_key),
      voice_max_bytes: fetch(telegram, :voice_max_bytes),
      files: parse_telegram_files(fetch(telegram, :files))
    }
  end

  defp parse_telegram(_), do: %{}

  defp parse_telegram_files(files) when is_map(files) do
    %{
      enabled: fetch(files, :enabled),
      auto_put: fetch(files, :auto_put),
      auto_put_mode: fetch(files, :auto_put_mode),
      auto_send_generated_images: fetch(files, :auto_send_generated_images),
      auto_send_generated_max_files: fetch(files, :auto_send_generated_max_files),
      uploads_dir: fetch(files, :uploads_dir),
      allowed_user_ids: fetch(files, :allowed_user_ids),
      deny_globs: fetch(files, :deny_globs),
      max_upload_bytes: fetch(files, :max_upload_bytes),
      max_download_bytes: fetch(files, :max_download_bytes),
      media_group_debounce_ms: fetch(files, :media_group_debounce_ms)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_telegram_files(_), do: %{}

  defp parse_engines(engines) when is_map(engines) do
    for {name, config} <- engines, into: %{} do
      engine = %{
        cli_path: fetch(config, :cli_path),
        enabled: fetch(config, :enabled)
      }

      {String.to_atom(to_string(name)), engine}
    end
  end

  defp parse_engines(_), do: %{}

  defp parse_transport(nil), do: nil
  defp parse_transport("telegram"), do: :telegram
  defp parse_transport(:telegram), do: :telegram
  defp parse_transport(other) when is_binary(other), do: String.to_atom(other)
  defp parse_transport(other) when is_atom(other), do: other

  defp parse_queue_mode(nil), do: nil
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode

  defp parse_drop_policy(nil), do: nil
  defp parse_drop_policy("oldest"), do: :oldest
  defp parse_drop_policy("newest"), do: :newest
  defp parse_drop_policy(policy) when is_atom(policy), do: policy

  defp validate_project_root(%Project{id: id, root: root}) when is_binary(root) do
    expanded = Path.expand(root)

    unless File.dir?(expanded) do
      require Logger
      Logger.warning("Project '#{id}' root directory does not exist: #{expanded}")
    end
  end

  defp validate_project_root(_), do: :ok

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end
end
