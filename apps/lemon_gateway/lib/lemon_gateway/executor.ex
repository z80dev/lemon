defmodule LemonGateway.Executor do
  @moduledoc """
  Native execution boundary for a gateway run.

  The configured executor is resolved at runtime from
  `:lemon_gateway, :executor`. This keeps the gateway independent of the
  application which provides native execution while allowing the reference
  runtime to select its executor in configuration.

  Executors send lifecycle events to the supplied sink as
  `{:engine_event, run_ref, event}` and streamed text as
  `{:engine_delta, run_ref, text}`. Control operations that an executor cannot
  perform must return `{:error, :unsupported}`.
  """

  alias LemonGateway.ExecutionRequest

  @required_callbacks [start_run: 3, cancel: 1, steer: 2, redirect: 2]

  @type run_opts :: keyword()
  @type cancel_context :: term()
  @type validation_error ::
          :executor_not_configured
          | {:invalid_executor, term()}
          | {:executor_not_loadable, module()}
          | {:executor_missing_callbacks, module(), [{atom(), non_neg_integer()}]}

  @callback start_run(ExecutionRequest.t(), run_opts(), pid()) ::
              {:ok, reference(), cancel_context()} | {:error, term()}
  @callback cancel(cancel_context()) :: :ok
  @callback steer(cancel_context(), String.t()) :: :ok | {:error, :unsupported | term()}
  @callback redirect(cancel_context(), String.t()) :: :ok | {:error, :unsupported | term()}

  @doc """
  Returns the executor module selected by runtime configuration.
  """
  @spec configured_module() :: {:ok, module()} | {:error, validation_error()}
  def configured_module do
    case Application.fetch_env(:lemon_gateway, :executor) do
      {:ok, module} when is_atom(module) -> {:ok, module}
      {:ok, configured} -> {:error, {:invalid_executor, configured}}
      :error -> {:error, :executor_not_configured}
    end
  end

  @doc """
  Validates the executor selected by runtime configuration.
  """
  @spec validate_configured() :: :ok | {:error, validation_error()}
  def validate_configured do
    with {:ok, module} <- configured_module() do
      validate(module)
    end
  end

  @doc """
  Validates that a module is loadable and implements the native executor
  contract.
  """
  @spec validate(module()) :: :ok | {:error, validation_error()}
  def validate(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      case missing_callbacks(module) do
        [] -> :ok
        callbacks -> {:error, {:executor_missing_callbacks, module, callbacks}}
      end
    else
      {:error, {:executor_not_loadable, module}}
    end
  end

  def validate(configured), do: {:error, {:invalid_executor, configured}}

  defp missing_callbacks(module) do
    Enum.reject(@required_callbacks, fn {function, arity} ->
      function_exported?(module, function, arity)
    end)
  end
end
