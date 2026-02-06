defmodule LemonGateway.Telegram.API do
  @moduledoc false

  @default_timeout 10_000

  def get_updates(token, offset, timeout_ms) do
    params = %{
      "offset" => offset,
      "timeout" => 0
    }

    request(token, "getUpdates", params, timeout_ms)
  end

  def send_message(token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil)

  def send_message(token, chat_id, text, reply_to_or_opts, parse_mode)
      when is_map(reply_to_or_opts) or is_list(reply_to_or_opts) do
    opts =
      if is_map(reply_to_or_opts), do: reply_to_or_opts, else: Enum.into(reply_to_or_opts, %{})

    params =
      %{
        "chat_id" => chat_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put(
        "reply_to_message_id",
        opts[:reply_to_message_id] || opts["reply_to_message_id"]
      )
      |> maybe_put("message_thread_id", opts[:message_thread_id] || opts["message_thread_id"])
      |> maybe_put("parse_mode", opts[:parse_mode] || opts["parse_mode"] || parse_mode)
      |> maybe_put("entities", opts[:entities] || opts["entities"])
      |> maybe_put("reply_markup", opts[:reply_markup] || opts["reply_markup"])

    request(token, "sendMessage", params, @default_timeout)
  end

  def send_message(token, chat_id, text, reply_to_message_id, parse_mode) do
    params =
      %{
        "chat_id" => chat_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("parse_mode", parse_mode)

    request(token, "sendMessage", params, @default_timeout)
  end

  def edit_message_text(token, chat_id, message_id, text, parse_mode_or_opts \\ nil)

  def edit_message_text(token, chat_id, message_id, text, parse_mode_or_opts)
      when is_map(parse_mode_or_opts) or is_list(parse_mode_or_opts) do
    opts =
      if is_map(parse_mode_or_opts),
        do: parse_mode_or_opts,
        else: Enum.into(parse_mode_or_opts, %{})

    params =
      %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("parse_mode", opts[:parse_mode] || opts["parse_mode"])
      |> maybe_put("entities", opts[:entities] || opts["entities"])
      |> maybe_put("reply_markup", opts[:reply_markup] || opts["reply_markup"])

    request(token, "editMessageText", params, @default_timeout)
  end

  def edit_message_text(token, chat_id, message_id, text, parse_mode) do
    params =
      %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("parse_mode", parse_mode)

    request(token, "editMessageText", params, @default_timeout)
  end

  def answer_callback_query(token, callback_query_id, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    params =
      %{
        "callback_query_id" => callback_query_id
      }
      |> maybe_put("text", opts[:text] || opts["text"])
      |> maybe_put("show_alert", opts[:show_alert] || opts["show_alert"])

    request(token, "answerCallbackQuery", params, @default_timeout)
  end

  def delete_message(token, chat_id, message_id) do
    params = %{
      "chat_id" => chat_id,
      "message_id" => message_id
    }

    request(token, "deleteMessage", params, @default_timeout)
  end

  defp request(token, method, params, timeout_ms) do
    url = "https://api.telegram.org/bot#{token}/#{method}"
    body = Jason.encode!(params)

    headers = [
      {~c"content-type", ~c"application/json"}
    ]

    opts = [timeout: timeout_ms, connect_timeout: timeout_ms]

    case :httpc.request(:post, {to_charlist(url), headers, ~c"application/json", body}, opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        Jason.decode(response_body)

      {:ok, {{_, status, _}, _headers, response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
