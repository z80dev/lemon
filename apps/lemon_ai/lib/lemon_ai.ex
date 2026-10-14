defmodule LemonAi do
  @moduledoc """
  Provider-agnostic LLM client: one API for 27 providers.

  This module is the whole public surface. `stream/3` and `complete/3` send a
  `LemonAi.Types.Context` to any provider's model and return either a lazy
  `LemonAi.EventStream` of events or the final `LemonAi.Types.AssistantMessage`. Model
  configuration, cost accounting, per-provider circuit breaking and rate limiting,
  and context handoffs between providers are all handled behind this interface.

  ## Usage

      # Create a context
      context = LemonAi.new_context(system_prompt: "You are a helpful assistant")
      context = LemonAi.Types.Context.add_user_message(context, "Hello!")

      # Stream a response
      {:ok, stream} = LemonAi.stream(model, context)

      for event <- LemonAi.EventStream.events(stream) do
        case event do
          {:text_delta, _idx, delta, _partial} -> IO.write(delta)
          {:done, _reason, message} -> IO.puts("\\nDone!")
          _ -> :ok
        end
      end

      # Or get a complete response
      {:ok, message} = LemonAi.complete(model, context)

  ## Models

  Models are defined with their provider, API type, and capabilities:

      model = %LemonAi.Types.Model{
        id: "claude-sonnet-5",
        name: "Claude Sonnet 5",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://api.anthropic.com",
        reasoning: true,
        adaptive_thinking: true,
        reasoning_efforts: [:low, :medium, :high, :xhigh],
        input: [:text, :image],
        cost: %{input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5},
        context_window: 1_000_000,
        max_tokens: 128_000
      }
  """

  alias LemonAi.Types.{Context, Model, StreamOptions, AssistantMessage}
  alias LemonAi.{EventStream, ProviderRegistry}

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

      {:ok, stream} = LemonAi.stream(model, context, %{temperature: 0.7})

      stream
      |> LemonAi.EventStream.events()
      |> Enum.each(&IO.inspect/1)
  """
  @spec stream(Model.t(), Context.t(), StreamOptions.t() | map()) ::
          {:ok, EventStream.t()} | {:error, term()}
  def stream(%Model{} = model, %Context{} = context, opts \\ %{}) do
    opts = normalize_options(opts)

    case ProviderRegistry.get(model.api) do
      {:ok, provider_module} ->
        LemonAi.CallDispatcher.dispatch(model.provider, fn ->
          provider_module.stream(model, context, opts)
        end)

      {:error, :not_found} ->
        {:error, {:unknown_api, model.api}}
    end
  end

  @doc """
  Get a complete response from an LLM (non-streaming).

  Collects `stream/3` privately and retries classified transient failures with
  `LemonAi.OneshotRetry`. The default is three total attempts, not three sets
  of provider HTTP retries. `stream/3` itself never gains completion retries.

  Pass `:retry` as a keyword list or map alongside stream options to override
  `:max_attempts`, `:base_delay_ms`, `:max_delay_ms`, `:sleep_fun` or `:cancelled?`.
  Set `retry: [max_attempts: 1]` to surface the first failure. Server hints
  longer than the allowed wait surface unchanged instead of retrying early.

  ## Examples

      {:ok, message} = LemonAi.complete(model, context)
      IO.puts(LemonAi.get_text(message))
  """
  @spec complete(Model.t(), Context.t(), StreamOptions.t() | map()) ::
          {:ok, AssistantMessage.t()} | {:error, term()}
  def complete(%Model{} = model, %Context{} = context, opts \\ %{}) do
    retry_options =
      case opts do
        %StreamOptions{} -> []
        options when is_list(options) -> Keyword.get(options, :retry, [])
        options when is_map(options) -> Map.get(options, :retry, [])
      end

    options = normalize_options(opts)
    provider_retry = Map.put(options.provider_retry || %{}, :max_attempts, 1)
    options = %{options | provider_retry: provider_retry}

    LemonAi.OneshotRetry.run(
      fn _attempt -> complete_once(model, context, options) end,
      retry_options
    )
  end

  defp complete_once(model, context, opts) do
    with {:ok, stream} <- stream(model, context, opts) do
      try do
        case EventStream.result(stream) do
          {:ok, %AssistantMessage{} = msg} = ok ->
            _ = LemonAi.PromptDiagnostics.record_complete_call(model, context, opts, msg)
            ok

          other ->
            other
        end
      after
        # No consumer sees this private handle. Release its bounded queue and
        # attached worker before a retry, even when the caller is long-lived.
        EventStream.cancel(stream, :completion_collected)
      end
    end
  end

  @doc """
  Extract all text content from an assistant message.

  ## Examples

      {:ok, message} = LemonAi.complete(model, context)
      text = LemonAi.get_text(message)
  """
  @spec get_text(AssistantMessage.t()) :: String.t()
  def get_text(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%LemonAi.Types.TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  @doc """
  Extract all thinking content from an assistant message.
  """
  @spec get_thinking(AssistantMessage.t()) :: String.t()
  def get_thinking(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%LemonAi.Types.ThinkingContent{}, &1))
    |> Enum.map(& &1.thinking)
    |> Enum.join("")
  end

  @doc """
  Extract all tool calls from an assistant message.
  """
  @spec get_tool_calls(AssistantMessage.t()) :: [LemonAi.Types.ToolCall.t()]
  def get_tool_calls(%AssistantMessage{content: content}) do
    Enum.filter(content, &match?(%LemonAi.Types.ToolCall{}, &1))
  end

  @doc """
  Calculate the cost of a response based on model pricing.
  """
  @spec calculate_cost(Model.t(), LemonAi.Types.Usage.t()) :: LemonAi.Types.Cost.t()
  def calculate_cost(%Model{cost: model_cost}, %LemonAi.Types.Usage{} = usage) do
    input_tokens = usage.input + usage.cache_read + usage.cache_write

    model_cost =
      case Map.get(model_cost, :long_context) do
        %{input_threshold: threshold} = long_context when input_tokens > threshold -> long_context
        _ -> model_cost
      end

    # Cost is per million tokens
    input_cost = usage.input * model_cost.input / 1_000_000
    output_cost = usage.output * model_cost.output / 1_000_000
    cache_read_cost = usage.cache_read * model_cost.cache_read / 1_000_000

    cache_write_cost =
      (usage.cache_write + min(usage.cache_write_long, usage.cache_write) * 0.6) *
        model_cost.cache_write / 1_000_000

    %LemonAi.Types.Cost{
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
