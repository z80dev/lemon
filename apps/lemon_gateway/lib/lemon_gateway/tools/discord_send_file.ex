defmodule LemonGateway.Tools.DiscordSendFile do
  @moduledoc """
  LemonAgent tool definition for sending files to Discord.

  Resolves the file beneath the project or workspace root through
  `LemonGateway.Tools.OutboundFile` (no symlinks below the root, no `..`,
  built-in secret denies plus `[gateway.discord.files].deny_globs`), checks the
  size, and queues a private copy of the validated bytes for delivery to the
  active Discord channel or thread with an optional caption.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.FileAccess
  alias LemonGateway.Tools.OutboundFile

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
    discord_cfg = OutboundFile.channel_config(:discord)

    with :ok <- require_discord_session(session_key),
         {:ok, path} <- fetch_path(params),
         {:ok, name, bytes} <-
           OutboundFile.read(
             path,
             root,
             workspace_dir,
             OutboundFile.deny_globs(discord_cfg),
             max_upload_bytes_limit(discord_cfg)
           ),
         {:ok, filename} <- normalize_filename(params, name),
         {:ok, caption} <- normalize_caption(params),
         {:ok, copy} <- FileAccess.retain_copy(name, bytes) do
      send_file_result(copy, filename, caption)
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

  defp normalize_filename(params, name) when is_map(params) do
    filename = Map.get(params, "filename") || Map.get(params, :filename)

    cond do
      is_nil(filename) ->
        {:ok, name}

      is_binary(filename) ->
        value = String.trim(filename)
        {:ok, if(value == "", do: name, else: value)}

      true ->
        {:error, "filename must be a string"}
    end
  end

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

  defp normalize_dir(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: Path.expand(trimmed)
  end

  defp normalize_dir(_), do: nil

  defp max_upload_bytes_limit(discord_cfg) do
    case discord_cfg[:max_upload_bytes] || discord_cfg["max_upload_bytes"] do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_max_bytes
    end
  rescue
    _ -> @default_max_bytes
  end
end
