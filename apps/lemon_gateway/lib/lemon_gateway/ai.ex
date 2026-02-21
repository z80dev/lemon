defmodule LemonGateway.AI do
  @moduledoc """
  Simple interface for AI chat completions.

  Supports multiple providers (OpenAI, Anthropic) with a unified interface.
  """

  require Logger

  @doc """
  Generate a chat completion using the specified model.

  ## Examples

      iex> messages = [%{role: "user", content: "Hello!"}]
      iex> LemonGateway.AI.chat_completion("gpt-4o-mini", messages)
      {:ok, %{"choices" => [%{"message" => %{"content" => "Hi there!"}}]}}

  """
  @spec chat_completion(String.t(), list(map()), map()) :: {:ok, map()} | {:error, term()}
  def chat_completion(model, messages, opts \\ %{}) do
    provider = get_provider(model)

    case provider do
      :openai -> openai_chat_completion(model, messages, opts)
      :anthropic -> anthropic_chat_completion(model, messages, opts)
      _ -> {:error, :unknown_provider}
    end
  end

  # Private Functions

  defp get_provider(model) do
    cond do
      String.starts_with?(model, "gpt-") -> :openai
      String.starts_with?(model, "o1") -> :openai
      String.starts_with?(model, "claude-") -> :anthropic
      true -> :unknown
    end
  end

  defp openai_chat_completion(model, messages, opts) do
    api_key = System.get_env("OPENAI_API_KEY") ||
              Application.get_env(:lemon_gateway, :openai_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      url = "https://api.openai.com/v1/chat/completions"

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      body = %{
        model: model,
        messages: messages,
        max_tokens: Map.get(opts, :max_tokens, 150),
        temperature: Map.get(opts, :temperature, 0.7)
      }

      case :httpc.request(
             :post,
             {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)},
             [timeout: 30_000],
             []
           ) do
        {:ok, {{_, 200, _}, _headers, response_body}} ->
          case Jason.decode(response_body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, reason} -> {:error, {:json_decode_error, reason}}
          end

        {:ok, {{_, status, _}, _headers, response_body}} ->
          Logger.error("OpenAI API error: #{status} - #{response_body}")
          {:error, {:api_error, status, response_body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp anthropic_chat_completion(model, messages, opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      url = "https://api.anthropic.com/v1/messages"

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]

      # Convert OpenAI-style messages to Anthropic format
      {system_message, conversation_messages} = extract_system_message(messages)

      body = %{
        model: model,
        max_tokens: Map.get(opts, :max_tokens, 150),
        temperature: Map.get(opts, :temperature, 0.7),
        messages: conversation_messages
      }

      body = if system_message, do: Map.put(body, :system, system_message), else: body

      case :httpc.request(
             :post,
             {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)},
             [timeout: 30_000],
             []
           ) do
        {:ok, {{_, 200, _}, _headers, response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"content" => content}} ->
              # Convert Anthropic format to OpenAI-like format
              text =
                content
                |> Enum.filter(fn c -> c["type"] == "text" end)
                |> Enum.map(fn c -> c["text"] end)
                |> Enum.join("\n")

              {:ok, %{"choices" => [%{"message" => %{"content" => text}}]}}

            {:error, reason} ->
              {:error, {:json_decode_error, reason}}
          end

        {:ok, {{_, status, _}, _headers, response_body}} ->
          Logger.error("Anthropic API error: #{status} - #{response_body}")
          {:error, {:api_error, status, response_body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp extract_system_message(messages) do
    case Enum.split_with(messages, fn m -> m[:role] == "system" end) do
      {[%{} = sys | _], rest} -> {sys[:content], rest}
      {_, rest} -> {nil, rest}
    end
  end
end
