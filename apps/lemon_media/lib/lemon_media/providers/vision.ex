defmodule LemonMedia.Providers.Vision do
  @moduledoc """
  Image-analysis drivers: `local_vision` preview and OpenAI-compatible
  `/chat/completions` vision.

  `request.input` carries the image (`:bytes`, `:mime_type`, `:hash`) and the
  analysis `:prompt`.
  """

  alias LemonMedia.Artifact
  alias LemonMedia.Providers.Http

  @doc false
  def run(%{provider: "local_vision", artifact_path: path, input: %{image: image}}) do
    analysis =
      "local image analysis preview for #{image.mime_type} image #{String.slice(image.hash, 0, 12)}"

    store(path, Jason.encode!(%{"text" => analysis}, pretty: true), analysis)
  end

  def run(%{provider: "openai_vision"} = request) do
    %{artifact_path: path, generation: generation, runtime: runtime, input: input} = request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, response} <- post_analysis(input, generation, runtime, api_key),
         {:ok, analysis, content} <- normalize_response(response, generation.format) do
      store(path, content, analysis)
    end
  end

  defp post_analysis(%{image: image, prompt: prompt}, generation, runtime, api_key) do
    body = %{
      "model" => runtime.api_model,
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => prompt},
            %{
              "type" => "image_url",
              "image_url" => %{
                "url" => "data:#{image.mime_type};base64,#{Base.encode64(image.bytes)}",
                "detail" => generation.detail
              }
            }
          ]
        }
      ]
    }

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    url = Http.url(runtime.base_url, "/chat/completions")

    Http.request(
      fn -> Http.post_fun(runtime).(url, request_opts) end,
      generation.max_retries,
      :openai_vision
    )
  end

  defp normalize_response(response, "json") when is_map(response) do
    text = response_text(response)
    {:ok, text, Jason.encode!(%{"text" => text}, pretty: true)}
  end

  defp normalize_response(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_response(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_response(response, "text") when is_binary(response),
    do: {:ok, response, response}

  defp normalize_response(response, "text") when is_map(response) do
    text = response_text(response)
    {:ok, text, text}
  end

  defp response_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}),
    do: content_text(content)

  defp response_text(%{choices: [%{message: %{content: content}} | _]}),
    do: content_text(content)

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text
  defp response_text(%{output_text: text}) when is_binary(text), do: text
  defp response_text(%{"text" => text}) when is_binary(text), do: text
  defp response_text(%{text: text}) when is_binary(text), do: text
  defp response_text(response), do: Jason.encode!(response)

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp content_text(content), do: to_string(content)

  defp store(path, content, analysis) do
    Artifact.store(path, content, text_mime_type(path), %{analysis: analysis})
  end

  @doc false
  def text_mime_type(path) do
    if String.downcase(Path.extname(path)) == ".json",
      do: "application/json",
      else: "text/plain"
  end
end
