defmodule LemonGateway.Transports.Webhook.Payload do
  @moduledoc """
  Request normalization for webhook transport.

  Converts raw webhook payloads into a normalized internal format by
  extracting the prompt text, attachments, and metadata from various
  field naming conventions.
  """

  import LemonGateway.Transports.Webhook.Helpers

  @doc """
  Normalizes a raw webhook payload map into a structured format with
  prompt, attachments, and metadata fields.

  Returns `{:ok, normalized}` on success or `{:error, :unprocessable_entity}`
  when the payload cannot be parsed into a valid prompt.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, :unprocessable_entity}
  def normalize(payload) when is_map(payload) do
    prompt_text = extract_prompt(payload)
    attachments = extract_attachments(payload)
    metadata = extract_metadata(payload)
    prompt = build_prompt(prompt_text, attachments)

    if is_binary(prompt) and String.trim(prompt) != "" do
      {:ok,
       %{
         prompt: prompt,
         prompt_text: prompt_text,
         attachments: attachments,
         metadata: metadata
       }}
    else
      {:error, :unprocessable_entity}
    end
  end

  def normalize(_), do: {:error, :unprocessable_entity}

  # --- Prompt extraction ---

  defp extract_prompt(payload) do
    first_non_blank([
      fetch_any(payload, [["prompt"]]),
      fetch_any(payload, [["text"]]),
      fetch_any(payload, [["message"]]),
      fetch_any(payload, [["input"]]),
      fetch_any(payload, [["body", "text"]]),
      fetch_any(payload, [["body.text"]]),
      fetch_any(payload, [["content", "text"]]),
      fetch_any(payload, [["content.text"]])
    ])
  end

  # --- Metadata extraction ---

  defp extract_metadata(payload) do
    case fetch_any(payload, [["metadata"]]) do
      value when is_map(value) ->
        value

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # --- Attachment extraction ---

  defp extract_attachments(payload) do
    [
      {"attachments", fetch_any(payload, [["attachments"]])},
      {"files", fetch_any(payload, [["files"]])},
      {"urls", fetch_any(payload, [["urls"]])}
    ]
    |> Enum.flat_map(fn {source, value} -> normalize_attachment_input(value, source) end)
    |> Enum.reject(&attachment_empty?/1)
    |> Enum.uniq_by(fn attachment ->
      {attachment[:source], attachment[:url], attachment[:name], attachment[:content_type],
       attachment[:size]}
    end)
  end

  defp normalize_attachment_input(nil, _source), do: []

  defp normalize_attachment_input(value, source) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        normalize_attachment_input(decoded, source)

      _ ->
        [%{source: source, url: value}]
    end
  end

  defp normalize_attachment_input(value, source) when is_list(value) do
    Enum.flat_map(value, &normalize_attachment_input(&1, source))
  end

  defp normalize_attachment_input(value, source) when is_map(value) do
    normalized =
      %{
        source: source,
        url: first_non_blank([fetch(value, :url), fetch(value, :href), fetch(value, :uri)]),
        name:
          first_non_blank([
            fetch(value, :name),
            fetch(value, :filename),
            fetch(value, :file_name),
            fetch(value, :title)
          ]),
        content_type:
          first_non_blank([
            fetch(value, :content_type),
            fetch(value, :mime_type),
            fetch(value, :type)
          ]),
        size: int_value(first_non_blank([fetch(value, :size), fetch(value, :bytes)]), nil)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(normalized) > 1 do
      [normalized]
    else
      value
      |> Map.values()
      |> Enum.flat_map(&normalize_attachment_input(&1, source))
    end
  end

  defp normalize_attachment_input(_value, _source), do: []

  defp attachment_empty?(attachment) do
    attachment
    |> Map.drop([:source])
    |> map_size()
    |> Kernel.==(0)
  end

  # --- Prompt building ---

  defp build_prompt(prompt_text, []), do: prompt_text

  defp build_prompt(prompt_text, attachments) do
    attachment_lines =
      attachments
      |> Enum.map(&attachment_line/1)
      |> Enum.reject(&is_nil/1)

    context =
      case attachment_lines do
        [] -> nil
        lines -> "Attachments:\n" <> Enum.join(lines, "\n")
      end

    [prompt_text, context]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> normalize_blank()
  end

  defp attachment_line(attachment) when is_map(attachment) do
    url = normalize_blank(fetch(attachment, :url))
    name = normalize_blank(fetch(attachment, :name))

    cond do
      is_binary(name) and is_binary(url) -> "- #{name} (#{url})"
      is_binary(url) -> "- #{url}"
      is_binary(name) -> "- #{name}"
      true -> nil
    end
  end

  defp attachment_line(_), do: nil
end
