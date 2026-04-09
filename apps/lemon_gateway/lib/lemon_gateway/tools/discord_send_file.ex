defmodule LemonGateway.Tools.DiscordSendFile do
  @moduledoc """
  AgentCore tool definition for sending files to Discord.

  Resolves the file path relative to the project or workspace root, validates
  the file size, and queues it for delivery to the active Discord channel or
  thread as an attachment with an optional caption.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_max_bytes 25 * 1024 * 1024

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    root = normalize_dir(cwd)
    workspace_dir = normalize_dir(Keyword.get(opts, :workspace_dir))
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "discord_send_file",
      description:
        "Queue a file from the current workspace for delivery to the active Discord conversation.",
      label: "Send Discord File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "File path. Supports absolute paths and relative paths from project/workspace."
          },
          "filename" => %{
            "type" => "string",
            "description" => "Optional filename to show in Discord."
          },
          "caption" => %{
            "type" => "string",
            "description" => "Optional caption to include with the attachment."
          }
        },
        "required" => ["path"]
      },
      execute: &execute(&1, &2, &3, &4, root, workspace_dir, session_key)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, root, workspace_dir, session_key) do
    with :ok <- require_discord_session(session_key),
         {:ok, path} <- fetch_path(params),
         {:ok, resolved_path} <- resolve_path(path, root, workspace_dir),
         :ok <- ensure_file_size_within_limit(resolved_path),
         {:ok, filename} <- normalize_filename(params, resolved_path),
         {:ok, caption} <- normalize_caption(params) do
      send_file_result(resolved_path, filename, caption)
    else
      {:error, message} ->
        error_result(message)
    end
  end

  defp require_discord_session(session_key) when is_binary(session_key) and session_key != "" do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: "discord"} ->
        :ok

      _ ->
        {:error, "discord_send_file is only available for Discord channel sessions."}
    end
  rescue
    _ -> {:error, "discord_send_file is only available for Discord channel sessions."}
  end

  defp require_discord_session(_),
    do: {:error, "discord_send_file is only available for Discord channel sessions."}

  defp fetch_path(params) when is_map(params) do
    path = Map.get(params, "path") || Map.get(params, :path)

    if is_binary(path) and String.trim(path) != "" do
      {:ok, String.trim(path)}
    else
      {:error, "Missing required parameter: path"}
    end
  end

  defp fetch_path(_), do: {:error, "Missing required parameter: path"}

  defp normalize_filename(params, resolved_path) when is_map(params) do
    filename = Map.get(params, "filename") || Map.get(params, :filename)

    cond do
      is_nil(filename) ->
        {:ok, Path.basename(resolved_path)}

      is_binary(filename) ->
        value = String.trim(filename)
        {:ok, if(value == "", do: Path.basename(resolved_path), else: value)}

      true ->
        {:error, "filename must be a string"}
    end
  end

  defp normalize_filename(_params, resolved_path), do: {:ok, Path.basename(resolved_path)}

  defp normalize_caption(params) when is_map(params) do
    caption = Map.get(params, "caption") || Map.get(params, :caption)

    cond do
      is_nil(caption) ->
        {:ok, nil}

      is_binary(caption) ->
        value = String.trim(caption)
        {:ok, if(value == "", do: nil, else: value)}

      true ->
        {:error, "caption must be a string"}
    end
  end

  defp normalize_caption(_), do: {:ok, nil}

  defp resolve_path(path, root, workspace_dir) do
    roots =
      [root, workspace_dir]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    path = expand_user_home(path)

    cond do
      Path.type(path) == :absolute ->
        absolute = Path.expand(path)

        if path_within_any_root?(absolute, roots) do
          if File.regular?(absolute) do
            {:ok, absolute}
          else
            {:error, "File not found: #{path}"}
          end
        else
          {:error, "Path must stay within the active workspace/project roots."}
        end

      true ->
        candidates =
          (workspace_prefixed_candidates(path, workspace_dir) ++
             Enum.map(roots, &Path.expand(path, &1)))
          |> Enum.uniq()

        case Enum.find(candidates, &File.regular?/1) do
          nil ->
            {:error, "File not found: #{path}"}

          resolved ->
            {:ok, resolved}
        end
    end
  end

  defp workspace_prefixed_candidates(path, workspace_dir)
       when is_binary(path) and is_binary(workspace_dir) do
    prefixes = ["workspace/", "./workspace/", ".lemon/agent/workspace/"]

    prefixes
    |> Enum.map(fn prefix ->
      if String.starts_with?(path, prefix) do
        suffix = String.replace_prefix(path, prefix, "")
        Path.expand(suffix, workspace_dir)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp workspace_prefixed_candidates(_path, _workspace_dir), do: []

  defp ensure_file_size_within_limit(path) do
    max_bytes = max_upload_bytes_limit()

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size <= max_bytes do
      :ok
    else
      {:ok, %File.Stat{size: size}} ->
        {:error, "File is too large (#{size} bytes). Max allowed is #{max_bytes} bytes."}

      _ ->
        {:error, "Failed to stat file: #{path}"}
    end
  end

  defp send_file_result(path, filename, caption) do
    %AgentToolResult{
      content: [
        %TextContent{
          text: "Queued file for Discord delivery: #{filename}"
        }
      ],
      details: %{
        auto_send_files: [
          %{
            path: path,
            filename: filename,
            caption: caption
          }
        ]
      }
    }
  end

  defp error_result(message) do
    %AgentToolResult{
      content: [%TextContent{text: message}],
      details: %{error: true}
    }
  end

  defp path_within_any_root?(_path, []), do: false

  defp path_within_any_root?(path, roots) do
    Enum.any?(roots, fn root -> path_within_root?(path, root) end)
  end

  defp path_within_root?(path, root) when is_binary(path) and is_binary(root) do
    rel = Path.relative_to(path, root)
    rel == "." or not String.starts_with?(rel, "..")
  end

  defp path_within_root?(_, _), do: false

  defp normalize_dir(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: Path.expand(trimmed)
  end

  defp normalize_dir(_), do: nil

  defp expand_user_home(path) when is_binary(path) do
    home = System.user_home()

    cond do
      is_binary(home) and String.starts_with?(path, "~/") ->
        Path.join(home, String.replace_prefix(path, "~/", ""))

      is_binary(home) and path == "~" ->
        home

      true ->
        path
    end
  end

  defp expand_user_home(path), do: path

  defp max_upload_bytes_limit do
    discord_cfg =
      if Process.whereis(LemonGateway.Config) do
        LemonGateway.Config.get(:discord) || %{}
      else
        []
      end

    case discord_cfg[:max_upload_bytes] || discord_cfg["max_upload_bytes"] do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_max_bytes
    end
  rescue
    _ -> @default_max_bytes
  end
end
