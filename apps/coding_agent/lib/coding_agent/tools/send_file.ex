defmodule CodingAgent.Tools.SendFile do
  @moduledoc """
  `send_file` tool: queue an existing file for delivery to the active chat.

  Offered only to Telegram and Discord channel sessions; the channel comes from
  the session key, never from tool parameters. Telegram accepts images only.

  A path resolves against the run cwd and profile workspace (relative,
  `workspace/...`-prefixed or absolute). Both the lexical path and its real path
  after symlink resolution must lie inside one of those roots; anything else is
  a policy error, whether or not the target exists. A run with no root can send
  nothing.

  The resolved file is then read through `LemonCore.FileAccess.read_file/4`
  beneath its physical root (no-follow walk, built-in secret denies plus
  `[gateway.<channel>.files] deny_globs`, bounded by `max_download_bytes`), and
  a private copy of those validated bytes (`LemonCore.FileAccess.retain_copy/2`)
  is queued, never the source path, so a later change to the source cannot alter
  what is delivered.
  """

  alias CodingAgent.WorkspaceReads
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.FileAccess

  @channels %{
    "telegram" => %{label: "Telegram", config: :telegram, default_max_bytes: 50 * 1024 * 1024},
    "discord" => %{label: "Discord", config: :discord, default_max_bytes: 25 * 1024 * 1024}
  }

  @workspace_prefixes ["workspace/", "./workspace/", ".lemon/agent/workspace/"]
  @policy_error "Path must stay within the active workspace/project roots."

  @doc "The delivery channel for `session_key` (`\"telegram\"`/`\"discord\"`), or nil."
  @spec channel(term()) :: String.t() | nil
  def channel(session_key) when is_binary(session_key) and session_key != "" do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when is_map_key(@channels, channel_id) ->
        channel_id

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def channel(_session_key), do: nil

  @spec tool(String.t() | nil, keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    roots = Enum.flat_map([cwd, Keyword.get(opts, :workspace_dir)], &root/1) |> Enum.uniq()
    workspace_dir = opts |> Keyword.get(:workspace_dir) |> root() |> List.first()
    channel = channel(Keyword.get(opts, :session_key))

    %AgentTool{
      name: "send_file",
      description:
        "Queue a file from the current project or workspace for delivery to the active chat " <>
          "(Telegram: images only).",
      label: "Send File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "File path inside the project or workspace: relative (artifacts/img.png), " <>
                "workspace-prefixed (workspace/img.png) or absolute."
          },
          "filename" => %{
            "type" => "string",
            "description" => "Optional filename to show in the chat."
          },
          "caption" => %{
            "type" => "string",
            "description" => "Optional caption to include with the file."
          }
        },
        "required" => ["path"]
      },
      execute: &execute(&1, &2, &3, &4, channel, roots, workspace_dir)
    }
  end

  @doc false
  def execute(_tool_call_id, params, _signal, _on_update, channel, roots, workspace_dir) do
    with {:ok, spec} <- channel_spec(channel),
         {:ok, path} <- fetch_path(params),
         {:ok, resolved} <- resolve(path, roots, workspace_dir),
         :ok <- ensure_type(resolved, channel, spec),
         {:ok, name, bytes} <- read_confined(resolved, roots, spec),
         {:ok, filename} <- optional_string(params, "filename"),
         {:ok, caption} <- optional_string(params, "caption"),
         {:ok, copy} <- FileAccess.retain_copy(name, bytes) do
      filename = if filename, do: Path.basename(filename), else: name

      %AgentToolResult{
        content: [%TextContent{text: "Queued file for #{spec.label} delivery: #{filename}"}],
        details: %{auto_send_files: [%{path: copy, filename: filename, caption: caption}]}
      }
    else
      {:error, message} ->
        %AgentToolResult{content: [%TextContent{text: message}], details: %{error: true}}
    end
  end

  defp channel_spec(channel) do
    case Map.fetch(@channels, channel) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, "send_file is only available for Telegram and Discord channel sessions."}
    end
  end

  defp fetch_path(params) when is_map(params) do
    case Map.get(params, "path") do
      path when is_binary(path) ->
        if String.trim(path) == "",
          do: {:error, "Missing required parameter: path"},
          else: {:ok, String.trim(path)}

      _ ->
        {:error, "Missing required parameter: path"}
    end
  end

  defp fetch_path(_params), do: {:error, "Missing required parameter: path"}

  # Each candidate must be inside a root lexically and, once it exists, by real
  # path. A candidate that escapes is a policy error even when nothing is there.
  defp resolve(_path, [], _workspace_dir), do: {:error, @policy_error}

  defp resolve(path, roots, workspace_dir) do
    path = expand_home(path)

    candidates =
      if Path.type(path) == :absolute do
        [Path.expand(path)]
      else
        workspace_candidates(path, workspace_dir) ++
          Enum.map(roots, &Path.expand(path, &1.lexical))
      end

    if Enum.all?(candidates, &within_any?(&1, roots, :lexical)) do
      find_existing(Enum.uniq(candidates), roots)
    else
      {:error, @policy_error}
    end
  end

  defp find_existing(candidates, roots) do
    Enum.reduce_while(candidates, {:error, "File not found."}, fn candidate, acc ->
      case WorkspaceReads.realpath(candidate) do
        {:ok, real} ->
          if within_any?(real, roots, :real),
            do: {:halt, {:ok, real}},
            else: {:halt, {:error, @policy_error}}

        {:error, _} ->
          {:cont, acc}
      end
    end)
  end

  defp workspace_candidates(path, %{lexical: workspace}) do
    for prefix <- @workspace_prefixes, String.starts_with?(path, prefix) do
      Path.expand(String.replace_prefix(path, prefix, ""), workspace)
    end
  end

  defp workspace_candidates(_path, _workspace), do: []

  defp ensure_type(path, "telegram", _spec) do
    cond do
      not File.regular?(path) -> {:error, "Not a regular file: #{Path.basename(path)}"}
      LemonCore.MediaFiles.image_path?(path) -> :ok
      true -> {:error, "Telegram send_file accepts images only (#{Path.extname(path)})."}
    end
  end

  defp ensure_type(path, _channel, _spec) do
    if File.regular?(path), do: :ok, else: {:error, "Not a regular file: #{Path.basename(path)}"}
  end

  # `resolved` is a real path inside a root's real path; re-read it from that
  # physical root without following links, under the channel's deny rules.
  defp read_confined(resolved, roots, spec) do
    files = files_config(spec)
    max_bytes = max_bytes(files, spec)

    case Enum.find(roots, &within?(resolved, &1.real)) do
      nil ->
        {:error, @policy_error}

      root ->
        case FileAccess.read_file(
               root.real,
               Path.relative_to(resolved, root.real),
               deny_globs(files),
               max_bytes
             ) do
          {:ok, _name, _bytes} = ok ->
            ok

          {:error, "File is too large."} ->
            {:error, "File is too large. Max allowed is #{max_bytes} bytes."}

          {:error, "Not found."} ->
            {:error, "File not found."}

          {:error, _message} = error ->
            error
        end
    end
  end

  defp files_config(%{config: key}) do
    files =
      case LemonGateway.Config.get_or_env(key, %{}) do
        cfg when is_map(cfg) or is_list(cfg) -> setting(cfg, :files)
        _ -> nil
      end

    if is_map(files) or is_list(files), do: files, else: %{}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp deny_globs(files), do: setting(files, :deny_globs)

  defp max_bytes(files, %{default_max_bytes: default}) do
    case setting(files, :max_download_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp setting(cfg, key) when is_map(cfg),
    do: Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))

  defp setting(cfg, key) when is_list(cfg), do: if(Keyword.keyword?(cfg), do: cfg[key])

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, if(String.trim(value) == "", do: nil, else: String.trim(value))}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  defp root(dir) when is_binary(dir) do
    case String.trim(dir) do
      "" ->
        []

      trimmed ->
        lexical = Path.expand(trimmed)

        case WorkspaceReads.realpath(lexical) do
          {:ok, real} -> [%{lexical: lexical, real: real}]
          {:error, _} -> []
        end
    end
  end

  defp root(_dir), do: []

  defp within_any?(path, roots, :lexical),
    do: Enum.any?(roots, &(within?(path, &1.lexical) or within?(path, &1.real)))

  defp within_any?(path, roots, :real), do: Enum.any?(roots, &within?(path, &1.real))

  defp within?(path, root) do
    case Path.relative_to(path, root) do
      ^path -> path == root
      "." -> true
      rel -> Path.type(rel) == :relative and rel != ".." and not String.starts_with?(rel, "../")
    end
  end

  defp expand_home("~"), do: System.user_home() || "~"

  defp expand_home("~/" <> rest) do
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, rest)
      _ -> "~/" <> rest
    end
  end

  defp expand_home(path), do: path
end
