defmodule Ai do
  @moduledoc """
  Unified LLM API abstraction layer.

  This module provides a single interface for interacting with multiple LLM providers
  (OpenAI, Anthropic, Google, etc.) with automatic model configuration, token/cost
  tracking, and seamless context handoffs between providers.

  ## Usage

      # Create a context
      context = Ai.Context.new(system_prompt: "You are a helpful assistant")
      context = Ai.Context.add_user_message(context, "Hello!")

      # Stream a response
      {:ok, stream} = Ai.stream(model, context)

      for event <- Ai.EventStream.events(stream) do
        case event do
          {:text_delta, _idx, delta, _partial} -> IO.write(delta)
          {:done, _reason, message} -> IO.puts("\\nDone!")
          _ -> :ok
        end
      end

      # Or get a complete response
      {:ok, message} = Ai.complete(model, context)

  ## Models

  Models are defined with their provider, API type, and capabilities:

      model = %Ai.Types.Model{
        id: "claude-sonnet-4-20250514",
        name: "Claude Sonnet 4",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://api.anthropic.com",
        reasoning: true,
        input: [:text, :image],
        cost: %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
        context_window: 200_000,
        max_tokens: 64_000
      }
  """

  alias Ai.Types.{Context, Model, StreamOptions, AssistantMessage}
  alias Ai.{EventStream, ProviderRegistry}

  # Re-export commonly used types
  defdelegate new_context(opts \\ []), to: Context, as: :new

  @doc """
  Stream a response from an LLM.

  Returns an EventStream that emits events as the response is generated.
  Use `EventStream.events/1` to consume events or `EventStream.result/1`
  to wait for the final message.

  ## Options

    * `:temperature` - Sampling temperature (0.0-2.0)
    * `:max_tokens` - Maximum tokens to generate
    * `:api_key` - Override the default API key
    * `:headers` - Additional HTTP headers
    * `:reasoning` - Thinking level (:minimal, :low, :medium, :high, :xhigh)

  ## Examples

      {:ok, stream} = Ai.stream(model, context, %{temperature: 0.7})

      stream
      |> Ai.EventStream.events()
      |> Enum.each(&IO.inspect/1)
  """
  @spec stream(Model.t(), Context.t(), StreamOptions.t() | map()) ::
          {:ok, EventStream.t()} | {:error, term()}
  def stream(%Model{} = model, %Context{} = context, opts \\ %{}) do
    opts = normalize_options(opts)

    with {:ok, provider_module} <- ProviderRegistry.get(model.api) do
      provider_module.stream(model, context, opts)
    else
      {:error, :not_found} ->
        {:error, {:unknown_api, model.api}}
    end
  end

  @doc """
  Get a complete response from an LLM (non-streaming).

  This is a convenience wrapper around `stream/3` that collects
  all events and returns the final message.

  ## Examples

      {:ok, message} = Ai.complete(model, context)
      IO.puts(Ai.get_text(message))
  """
  @spec complete(Model.t(), Context.t(), StreamOptions.t() | map()) ::
          {:ok, AssistantMessage.t()} | {:error, term()}
  def complete(%Model{} = model, %Context{} = context, opts \\ %{}) do
    with {:ok, stream} <- stream(model, context, opts) do
      EventStream.result(stream)
    end
  end

  @doc """
  Extract all text content from an assistant message.

  ## Examples

      {:ok, message} = Ai.complete(model, context)
      text = Ai.get_text(message)
  """
  @spec get_text(AssistantMessage.t()) :: String.t()
  def get_text(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%Ai.Types.TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  @doc """
  Extract all thinking content from an assistant message.
  """
  @spec get_thinking(AssistantMessage.t()) :: String.t()
  def get_thinking(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%Ai.Types.ThinkingContent{}, &1))
    |> Enum.map(& &1.thinking)
    |> Enum.join("")
  end

  @doc """
  Extract all tool calls from an assistant message.
  """
  @spec get_tool_calls(AssistantMessage.t()) :: [Ai.Types.ToolCall.t()]
  def get_tool_calls(%AssistantMessage{content: content}) do
    Enum.filter(content, &match?(%Ai.Types.ToolCall{}, &1))
  end

  @doc """
  Calculate the cost of a response based on model pricing.
  """
  @spec calculate_cost(Model.t(), Ai.Types.Usage.t()) :: Ai.Types.Cost.t()
  def calculate_cost(%Model{cost: model_cost}, %Ai.Types.Usage{} = usage) do
    # Cost is per million tokens
    input_cost = usage.input * model_cost.input / 1_000_000
    output_cost = usage.output * model_cost.output / 1_000_000
    cache_read_cost = usage.cache_read * model_cost.cache_read / 1_000_000
    cache_write_cost = usage.cache_write * model_cost.cache_write / 1_000_000

    %Ai.Types.Cost{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost,
      total: input_cost + output_cost + cache_read_cost + cache_write_cost
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_options(%StreamOptions{} = opts), do: opts

  defp normalize_options(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_options()
  end

  defp normalize_options(opts) when is_map(opts) do
    allowed_keys =
      %StreamOptions{}
      |> Map.from_struct()
      |> Map.keys()

    opts = Map.take(opts, allowed_keys)

    struct(StreamOptions, opts)
  end
end
