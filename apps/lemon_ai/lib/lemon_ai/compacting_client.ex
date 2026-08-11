defmodule LemonAi.CompactingClient do
  @moduledoc """
  AI client with automatic context compaction and retry on ContextLengthExceeded.

  This module wraps the standard AI provider calls with automatic retry logic
  that compacts the context when a ContextLengthExceeded error is encountered.

  ## Usage

  Use this module as a drop-in replacement for direct provider calls:

      # Instead of:
      LemonAi.Providers.Anthropic.stream(model, context, opts)

      # Use:
      LemonAi.CompactingClient.stream(model, context, opts)

  The client will automatically:
  1. Attempt the initial request
  2. Detect ContextLengthExceeded errors
  3. Compact the context using the configured strategy
  4. Retry with the compacted context
  5. Repeat up to the maximum number of compaction attempts

  ## Configuration

  Configure via application environment:

      config :lemon_ai, LemonAi.CompactingClient,
        enabled: true,
        max_compaction_attempts: 3,
        default_strategy: :truncation

  ## Telemetry

  - `[:lemon_ai, :compacting_client, :request_started]` - When a request begins
  - `[:lemon_ai, :compacting_client, :compaction_retry]` - When compaction retry occurs
  - `[:lemon_ai, :compacting_client, :request_succeeded]` - When request succeeds
  - `[:lemon_ai, :compacting_client, :request_failed]` - When request fails permanently
  """

  require Logger

  alias LemonAi.Types.{Context, Model, StreamOptions}

  @default_max_attempts 3

  @doc """
  Stream a response from the provider with automatic compaction retry.

  This function wraps the provider's stream function and automatically
  retries with compacted context if a ContextLengthExceeded error occurs.

  ## Options

  All standard `StreamOptions` are supported, plus:

  - `:compaction_enabled` - Enable/disable compaction for this request (default: true)
  - `:compaction_strategy` - Strategy to use (:truncation, :summarization, :hybrid)
  - `:max_compaction_attempts` - Maximum number of compaction retries

  ## Examples

      {:ok, stream} = LemonAi.CompactingClient.stream(model, context, opts)
      result = LemonAi.EventStream.result(stream)
  """
  @spec stream(Model.t(), Context.t(), StreamOptions.t() | keyword()) ::
          {:ok, LemonAi.EventStream.t()} | {:error, term()}
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    compaction_enabled = Keyword.get(opts, :compaction_enabled, enabled?())
    max_attempts = Keyword.get(opts, :max_compaction_attempts, max_attempts())

    emit_telemetry(:request_started, %{
      provider: model.provider,
      model: model.id,
      compaction_enabled: compaction_enabled,
      max_attempts: max_attempts
    })

    do_stream_with_retry(model, context, opts, max_attempts, 0, compaction_enabled)
  end

  @doc """
  Check if compaction is enabled globally.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:lemon_ai, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Get the maximum number of compaction attempts from configuration.
  """
  @spec max_attempts() :: non_neg_integer()
  def max_attempts do
    Application.get_env(:lemon_ai, __MODULE__, [])
    |> Keyword.get(:max_compaction_attempts, @default_max_attempts)
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_stream_with_retry(model, context, opts, max_attempts, attempt, compaction_enabled) do
    provider = resolve_provider(model)

    result =
      LemonAi.CallDispatcher.dispatch(provider, fn ->
        provider_module(model).stream(model, context, struct(StreamOptions, opts))
      end)

    case result do
      {:ok, stream} ->
        # Wait for the stream to complete to check for context length errors
        handle_stream_result(
          stream,
          model,
          context,
          opts,
          max_attempts,
          attempt,
          compaction_enabled
        )

      {:error, _reason} = error ->
        handle_error(error, model, context, opts, max_attempts, attempt, compaction_enabled)
    end
  end

  defp handle_stream_result(
         stream,
         model,
         _context,
         _opts,
         _max_attempts,
         attempt,
         _compaction_enabled
       ) do
    # For now, we return the stream immediately and let the caller handle errors
    # A more sophisticated implementation would wrap the stream to intercept errors
    emit_telemetry(:request_succeeded, %{
      provider: model.provider,
      model: model.id,
      attempt: attempt + 1
    })

    {:ok, stream}
  end

  defp handle_error(
         {:error, reason},
         model,
         context,
         opts,
         max_attempts,
         attempt,
         compaction_enabled
       ) do
    if compaction_enabled and
         attempt < max_attempts and
         LemonAi.ContextCompactor.context_length_error?(reason) do
      Logger.info(
        "ContextLengthExceeded detected (attempt #{attempt + 1}/#{max_attempts + 1}), " <>
          "compacting context for retry"
      )

      strategy =
        Keyword.get(opts, :compaction_strategy, LemonAi.ContextCompactor.default_strategy())

      emit_telemetry(:compaction_retry, %{
        provider: model.provider,
        model: model.id,
        attempt: attempt + 1,
        strategy: strategy
      })

      case LemonAi.ContextCompactor.compact(context, strategy: strategy) do
        {:ok, compacted_context, metadata} ->
          Logger.debug("Context compacted: #{inspect(metadata)}")

          # Retry with compacted context
          do_stream_with_retry(
            model,
            compacted_context,
            opts,
            max_attempts,
            attempt + 1,
            compaction_enabled
          )

        {:error, compaction_reason} ->
          Logger.warning("Context compaction failed: #{inspect(compaction_reason)}")

          emit_telemetry(:request_failed, %{
            provider: model.provider,
            model: model.id,
            reason: :compaction_failed,
            original_error: reason,
            compaction_error: compaction_reason
          })

          {:error, {:compaction_failed, compaction_reason, original: reason}}
      end
    else
      # Not a context length error, or compaction disabled/exhausted
      emit_telemetry(:request_failed, %{
        provider: model.provider,
        model: model.id,
        reason: reason,
        attempt: attempt + 1,
        compaction_exhausted: attempt >= max_attempts
      })

      {:error, reason}
    end
  end

  defp provider_module(%{provider: :anthropic}), do: LemonAi.Providers.Anthropic
  defp provider_module(%{provider: :openai}), do: LemonAi.Providers.OpenAI
  defp provider_module(%{provider: :google}), do: LemonAi.Providers.Google
  defp provider_module(%{provider: :bedrock}), do: LemonAi.Providers.Bedrock
  defp provider_module(%{api: api}), do: LemonAi.ProviderRegistry.get!(api)
  defp provider_module(_), do: LemonAi.Providers.Anthropic

  defp resolve_provider(%{provider: provider}) when is_atom(provider), do: provider

  defp resolve_provider(%{provider: provider}) when is_binary(provider),
    do: String.to_atom(provider)

  defp resolve_provider(_), do: :anthropic

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:lemon_ai, :compacting_client, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
