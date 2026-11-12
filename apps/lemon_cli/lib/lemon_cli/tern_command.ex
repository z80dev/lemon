defmodule LemonCli.TernCommand do
  @moduledoc """
  Installs Lemon's Tern palette plugin and registers the invoking launcher as a
  custom stdio ACP agent. With `--agent-block`, also selects Lemon's TUI for new
  agent blocks. Unrelated preferences, agents and plugin files are preserved.
  """

  @plugin_assets ["plugin.toml", "window.luau"]
  @plugin_receipt ".lemon-install.json"

  def run(["install" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [config_dir: :string, agent_block: :boolean])

    if rest != [] or invalid != [] do
      usage()
    else
      with {:ok, directory} <- config_directory(opts),
           {:ok, launcher} <- launcher(),
           :ok <- install(directory, launcher, opts) do
        IO.puts(
          "Installed Lemon's Tern plugin and ACP agent. Run `tern plugin reload` (or restart Tern), then type `lemon` in a Tern pane or choose `Lemon: New session in split` in the palette. For Tern's native ACP chat, run `tern acp lemon`."
        )

        if opts[:agent_block] do
          IO.puts(
            "Set Tern's agent_command to Lemon's TUI launcher for new agent blocks. Revert in Tern Settings → Agents, or remove agent_command from settings.json."
          )
        end

        0
      else
        {:error, message} ->
          IO.puts(:stderr, "Error: " <> message)
          1
      end
    end
  end

  def run(_args), do: usage()

  @doc false
  def install(directory, launcher, opts \\ []) do
    path = Path.join(directory, "settings.json")

    launcher = Path.expand(launcher)
    command = "'" <> String.replace(launcher, "'", "'\\''") <> "' tui"

    with {:ok, settings} <- settings(path),
         {:ok, settings} <- register(settings, launcher),
         {:ok, settings} <- agent_block(settings, command, Keyword.get(opts, :agent_block, false)),
         {:ok, assets} <- plugin_assets(launcher, command),
         :ok <- plugin_destination(directory, assets),
         :ok <- File.mkdir_p(directory) do
      temporary = path <> ".lemon-" <> Integer.to_string(System.unique_integer([:positive]))

      try do
        with :ok <-
               File.write(temporary, Jason.encode!(settings, pretty: true) <> "\n", [:exclusive]),
             :ok <- install_plugin(directory, assets),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          {:error, message} when is_binary(message) ->
            {:error, message}

          _ ->
            {:error,
             "Could not write Tern settings; check the configuration directory permissions."}
        end
      after
        File.rm(temporary)
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not create the Tern configuration directory."}
    end
  end

  defp register(settings, launcher) do
    # The shell-launched TUI stays distinct from this ACP agent (`tern acp lemon`).
    # Tern's `auto_acp` shell wrapping only affects its built-in agent CLIs, so it
    # is the user's preference and is left untouched.
    agents = Map.get(settings, "agents", %{})
    custom = if is_map(agents), do: Map.get(agents, "custom", []), else: nil

    if is_list(custom) and Enum.all?(custom, &is_map/1) do
      lemon = %{
        "id" => "lemon",
        "name" => "Lemon",
        "command" => launcher,
        "args" => ["acp"],
        "env" => %{}
      }

      custom = Enum.reject(custom, &(&1["id"] == "lemon")) ++ [lemon]

      {:ok, Map.put(settings, "agents", Map.put(agents, "custom", custom))}
    else
      {:error, "Tern agents.custom must be an array; settings were not changed."}
    end
  end

  defp agent_block(settings, _command, false), do: {:ok, settings}

  defp agent_block(settings, command, true) do
    if not Map.has_key?(settings, "agent_command") or is_binary(settings["agent_command"]) do
      {:ok, Map.put(settings, "agent_command", command)}
    else
      {:error, "Tern agent_command must be a string; settings were not changed."}
    end
  end

  defp plugin_assets(launcher, command) do
    source = Application.app_dir(:lemon_cli, "priv/tern")

    Enum.reduce_while(@plugin_assets, {:ok, %{}}, fn name, {:ok, assets} ->
      case File.read(Path.join(source, name)) do
        {:ok, bytes} ->
          {:cont, {:ok, Map.put(assets, name, bytes)}}

        {:error, _} ->
          {:halt, {:error, "Lemon's bundled Tern plugin is missing; reinstall Lemon."}}
      end
    end)
    |> case do
      {:ok, assets} ->
        config = Jason.encode!(%{"launcher" => launcher, "command" => command}, pretty: true)
        {:ok, Map.put(assets, "launcher.json", config <> "\n")}

      error ->
        error
    end
  end

  defp plugin_destination(directory, assets) do
    plugin = Path.join([directory, "plugins", "lemon"])
    link = Path.join([directory, "plugins", "lemon.path"])

    case File.lstat(link) do
      {:error, :enoent} ->
        case File.lstat(plugin) do
          {:error, :enoent} ->
            :ok

          {:ok, %{type: :directory}} ->
            owned_plugin(plugin, assets)

          _ ->
            plugin_conflict()
        end

      _ ->
        plugin_conflict()
    end
  end

  defp owned_plugin(plugin, assets) do
    with {:ok, %{type: :regular}} <- File.lstat(Path.join(plugin, @plugin_receipt)),
         {:ok, encoded} <- File.read(Path.join(plugin, @plugin_receipt)),
         {:ok, %{"owner" => "lemon tern install", "files" => files}} when is_map(files) <-
           Jason.decode(encoded),
         true <-
           Enum.all?(assets, fn {name, bytes} ->
             path = Path.join(plugin, name)

             with {:ok, %{type: :regular}} <- File.lstat(path),
                  {:ok, existing} <- File.read(path) do
               digest(existing) in [files[name], digest(bytes)]
             else
               _ -> false
             end
           end) do
      :ok
    else
      _ -> plugin_conflict()
    end
  end

  defp plugin_conflict do
    {:error,
     "Tern plugins/lemon is unmanaged or modified, or lemon.path is linked. Move it aside before retrying; no settings or plugin files were changed."}
  end

  defp install_plugin(directory, assets) do
    plugins = Path.join(directory, "plugins")
    plugin = Path.join(plugins, "lemon")
    stage = Path.join(plugins, ".lemon-" <> Integer.to_string(System.unique_integer([:positive])))

    receipt = %{
      "owner" => "lemon tern install",
      "files" => Map.new(assets, fn {name, bytes} -> {name, digest(bytes)} end)
    }

    assets = Map.put(assets, @plugin_receipt, Jason.encode!(receipt, pretty: true) <> "\n")

    try do
      with :ok <- File.mkdir_p(plugins),
           :ok <- File.mkdir(stage),
           :ok <-
             Enum.reduce_while(assets, :ok, fn {name, bytes}, :ok ->
               case File.write(Path.join(stage, name), bytes, [:exclusive]) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end) do
        if File.exists?(plugin) do
          # Publish each owned file by rename; never replace the directory or touch
          # extra user files. The receipt goes last. Preflight also accepts desired
          # bytes, so an interrupted publication can be retried safely.
          Enum.reduce_while(
            ["launcher.json", "window.luau", "plugin.toml", @plugin_receipt],
            :ok,
            fn name, :ok ->
              case File.rename(Path.join(stage, name), Path.join(plugin, name)) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end
          )
        else
          File.rename(stage, plugin)
        end
      end
    after
      File.rm_rf(stage)
    end
    |> case do
      :ok ->
        :ok

      _ ->
        {:error,
         "Could not publish Tern's Lemon plugin; check plugins directory permissions and retry."}
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp settings(path) do
    case File.read(path) do
      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:error, "Tern settings.json is not a JSON object; settings were not changed."}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _reason} ->
        {:error, "Could not read Tern settings.json; settings were not changed."}
    end
  end

  defp config_directory(opts) do
    case Keyword.get(opts, :config_dir) || System.get_env("TERN_CONFIG_DIR") do
      directory when is_binary(directory) and directory != "" ->
        {:ok, Path.expand(directory)}

      _ ->
        case System.find_executable("tern") do
          nil ->
            {:error, "Tern is not on PATH. Install Tern or pass --config-dir PATH."}

          tern ->
            case System.cmd(tern, ["plugin", "dir"], stderr_to_stdout: true) do
              {directory, 0} -> {:ok, directory |> String.trim() |> Path.dirname()}
              _ -> {:error, "Could not locate Tern configuration; pass --config-dir PATH."}
            end
        end
    end
  end

  defp launcher do
    case System.get_env("LEMON_LAUNCHER") || System.find_executable("lemon") do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, "Run install through the Lemon launcher (`lemon tern install`)."}
    end
  end

  defp usage do
    IO.puts(:stderr, "usage: lemon tern install [--config-dir PATH] [--agent-block]")
    2
  end
end
