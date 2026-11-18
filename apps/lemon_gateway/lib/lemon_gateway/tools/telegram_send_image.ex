defmodule LemonGateway.Tools.TelegramSendImage do
  @moduledoc """
  LemonAgent tool definition for sending images to Telegram.

  Resolves the image beneath the project or workspace root through
  `LemonGateway.Tools.OutboundFile` (no symlinks below the root, no `..`,
  built-in secret denies plus `[gateway.telegram.files].deny_globs`), requires
  an image extension on the actual file name, checks the size, and queues a
  private copy of the validated bytes for delivery to the active Telegram chat
  with an optional caption.

  Oversized images report the configured limit; lookup and containment
  failures are separate validation errors.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.FileAccess
  alias LemonGateway.Tools.OutboundFile

  @default_max_bytes 50 * 1024 * 1024

  @image_extensions MapSet.new([
                      ".png",
                      ".jpg",
                      ".jpeg",
                      ".gif",
                      ".webp",
                      ".bmp",
                      ".svg",
                      ".tif",
                      ".tiff",
                      ".heic",
                      ".heif"
                    ])

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    root = normalize_dir(cwd)
    workspace_dir = normalize_dir(Keyword.get(opts, :workspace_dir))
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "telegram_send_image",
      description:
        "Queue an image file from the current workspace for delivery to the active Telegram chat.",
      label: "Send Telegram Image",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Image path. Supports absolute paths and relative paths from project/workspace (for example: /abs/path.png, artifacts/img.png, workspace/img.png)."
          },
          "caption" => %{
            "type" => "string",
            "description" => "Optional caption to include with the image."
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
    telegram_cfg = OutboundFile.channel_config(:telegram)

    with :ok <- require_telegram_session(session_key),
         {:ok, path} <- fetch_path(params),
         {:ok, name, bytes} <-
           OutboundFile.read(
             path,
             root,
             workspace_dir,
             OutboundFile.deny_globs(telegram_cfg),
             max_download_bytes_limit(telegram_cfg)
           ),
         :ok <- ensure_supported_image(name),
         {:ok, caption} <- normalize_caption(params),
         {:ok, copy} <- FileAccess.retain_copy(name, bytes) do
      send_file_result(copy, name, caption)
    else
      {:error, message} ->
        error_result(message)
    end
  end

  defp require_telegram_session(session_key) when is_binary(session_key) and session_key != "" do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: "telegram"} ->
        :ok

      _ ->
        {:error, "telegram_send_image is only available for Telegram channel sessions."}
    end
  rescue
    _ -> {:error, "telegram_send_image is only available for Telegram channel sessions."}
  end

  defp require_telegram_session(_),
    do: {:error, "telegram_send_image is only available for Telegram channel sessions."}

  defp fetch_path(params) when is_map(params) do
    path = Map.get(params, "path") || Map.get(params, :path)

    if is_binary(path) and String.trim(path) != "" do
      {:ok, String.trim(path)}
    else
      {:error, "Missing required parameter: path"}
    end
  end

  defp fetch_path(_), do: {:error, "Missing required parameter: path"}

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

  defp ensure_supported_image(name) do
    ext = name |> Path.extname() |> String.downcase()

    if MapSet.member?(@image_extensions, ext),
      do: :ok,
      else: {:error, "Unsupported image type for telegram_send_image: #{ext}"}
  end

  defp send_file_result(path, filename, caption) do
    %AgentToolResult{
      content: [
        %TextContent{
          text: "Queued image for Telegram delivery: #{filename}"
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

  defp max_download_bytes_limit(telegram_cfg) do
    files_cfg = telegram_cfg[:files] || telegram_cfg["files"] || %{}
    raw = files_cfg[:max_download_bytes] || files_cfg["max_download_bytes"]

    case raw do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> @default_max_bytes
        end

      _ ->
        @default_max_bytes
    end
  rescue
    _ -> @default_max_bytes
  end
end
