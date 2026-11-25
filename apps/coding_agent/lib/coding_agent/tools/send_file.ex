defmodule CodingAgent.Tools.SendFile do
  @moduledoc """
  `send_file` tool: queue an existing file for delivery to the active chat.

  Offered only to Telegram and Discord channel sessions; the channel comes from
  the session key, never from tool parameters. Telegram accepts images only.

  A path names a file beneath the run cwd or profile workspace: relative,
  `workspace/...`-prefixed or absolute under one of those roots. Any `..`
  component is refused before anything else; an absolute path outside every
  root is a policy error, whether or not the target exists. A run with no root
  can send nothing.

  Only the trusted roots are resolved to physical paths. The requested
  root-relative components are passed unchanged to
  `LemonCore.FileAccess.read_file/4`, which walks them without following any
  symlink below the root and applies the built-in secret denies plus
  `[gateway.<channel>.files] deny_globs` to the names as requested. The read is
  bounded by the strictest configured limit (`files.max_download_bytes`, the
  channel's `max_upload_bytes`, the channel default); integer or numeric-string
  values are accepted.

  A private copy of the validated bytes (`LemonCore.FileAccess.retain_copy/2`)
  is queued, never the source path, and registered for this session in
  `LemonCore.OutboundCopies`, so completion-time delivery can trust that copy
  and a later change to the source cannot alter what is delivered.
  """

  alias CodingAgent.WorkspaceReads
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.{FileAccess, OutboundCopies}

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
    session_key = Keyword.get(opts, :session_key)
    channel = channel(session_key)

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
      execute: &execute(&1, &2, &3, &4, {channel, session_key}, roots, workspace_dir)
    }
  end

  @doc false
  def execute(_tool_call_id, params, _signal, _on_update, {channel, session_key}, roots, ws) do
    with {:ok, spec} <- channel_spec(channel),
         {:ok, path} <- fetch_path(params),
         {:ok, candidates} <- candidates(path, roots, ws),
         :ok <- ensure_type(path, channel),
         {:ok, name, bytes} <- read_confined(candidates, spec),
         {:ok, filename} <- optional_string(params, "filename"),
         {:ok, caption} <- optional_string(params, "caption"),
         {:ok, copy} <- FileAccess.retain_copy(name, bytes),
         :ok <- OutboundCopies.register(session_key, copy) do
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

  # `{root, rel}` pairs to try in order: `rel` is the request's own components
  # beneath the physical `root`. Traversal is refused before any expansion.
  defp candidates(_path, [], _workspace_dir), do: {:error, @policy_error}

  defp candidates(path, roots, workspace_dir) do
    if ".." in String.split(path, "/") do
      {:error, @policy_error}
    else
      path = expand_home(path)

      if Path.type(path) == :absolute do
        absolute_candidates(Path.expand(path), roots)
      else
        {:ok, workspace_candidates(path, workspace_dir) ++ Enum.map(roots, &{&1.real, path})}
      end
    end
  end

  defp absolute_candidates(path, roots) do
    roots
    |> Enum.flat_map(fn root ->
      for prefix <- Enum.uniq([root.lexical, root.real]), within?(path, prefix) do
        {root.real, Path.relative_to(path, prefix)}
      end
    end)
    |> case do
      [] -> {:error, @policy_error}
      found -> {:ok, Enum.uniq(found)}
    end
  end

  defp workspace_candidates(path, %{real: workspace}) do
    for prefix <- @workspace_prefixes, String.starts_with?(path, prefix) do
      {workspace, String.replace_prefix(path, prefix, "")}
    end
  end

  defp workspace_candidates(_path, _workspace), do: []

  defp ensure_type(path, "telegram") do
    if LemonCore.MediaFiles.image_path?(path),
      do: :ok,
      else: {:error, "Telegram send_file accepts images only (#{Path.extname(path)})."}
  end

  defp ensure_type(_path, _channel), do: :ok

  # The first candidate that exists decides; FileAccess refuses symlinks,
  # denied names and non-regular files beneath the physical root.
  defp read_confined(candidates, spec) do
    cfg = channel_config(spec)
    files = files_config(cfg)
    max_bytes = max_bytes(cfg, files, spec)
    globs = setting(files, :deny_globs)

    Enum.reduce_while(candidates, {:error, "File not found."}, fn {root, rel}, acc ->
      case FileAccess.read_file(root, rel, globs, max_bytes) do
        {:ok, _name, _bytes} = ok -> {:halt, ok}
        {:error, "Not found."} -> {:cont, acc}
        {:error, "File is too large."} -> {:halt, too_large(max_bytes)}
        {:error, "Not a regular file."} -> {:halt, {:error, "Not a regular file: #{rel}"}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp too_large(max_bytes), do: {:error, "File is too large. Max allowed is #{max_bytes} bytes."}

  defp channel_config(%{config: key}) do
    case LemonCore.GatewayConfig.get(key, %{}) do
      cfg when is_map(cfg) or is_list(cfg) -> cfg
      _ -> %{}
    end
  end

  defp files_config(cfg) do
    files = setting(cfg, :files)
    if is_map(files) or is_list(files), do: files, else: %{}
  end

  # The strictest of the channel default, `files.max_download_bytes` and the
  # channel-level `max_upload_bytes`.
  defp max_bytes(cfg, files, %{default_max_bytes: default}) do
    [setting(files, :max_download_bytes), setting(cfg, :max_upload_bytes)]
    |> Enum.map(&positive_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> default end)
    |> min(default)
  end

  defp positive_int(n) when is_integer(n) and n > 0, do: n

  defp positive_int(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp positive_int(_n), do: nil

  defp setting(cfg, key) when is_map(cfg),
    do: Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))

  defp setting(cfg, key) when is_list(cfg), do: if(Keyword.keyword?(cfg), do: cfg[key])
  defp setting(_cfg, _key), do: nil

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
