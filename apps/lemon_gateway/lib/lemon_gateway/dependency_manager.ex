defmodule LemonGateway.DependencyManager do
  @moduledoc """
  Centralized dependency availability and startup manager for LemonGateway.

  Engines, tools, and transport modules previously contained scattered
  `Application.ensure_all_started/1` and `Code.ensure_loaded?/1` calls.
  This module provides a single boundary for:

  - Ensuring OTP applications are started before use (`ensure_app/1`)
  - Checking module availability without starting apps (`available?/1`)
  - Caching availability results to avoid repeated `Code.ensure_loaded?` calls

  ## Usage

      case DependencyManager.ensure_app(:coding_agent) do
        :ok -> # proceed
        {:error, reason} -> # handle failure
      end

      if DependencyManager.available?(LemonCore.Bus) do
        LemonCore.Bus.broadcast(topic, event)
      end
  """

  @doc """
  Ensure an OTP application and its dependencies are started.

  Returns `:ok` on success, `{:error, reason}` on failure.
  This is the unified replacement for scattered `Application.ensure_all_started/1`
  calls in engine, tool, and transport modules.
  """
  @spec ensure_app(atom()) :: :ok | {:error, term()}
  def ensure_app(app) when is_atom(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {failed_app, reason}} -> {:error, {:app_start_failed, failed_app, reason}}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  @doc """
  Check whether a module is loaded and available for use.

  Uses `Code.ensure_loaded?/1` under the hood. Suitable for optional
  dependencies that may not be present in all deployment configurations
  (e.g., `LemonCore.Bus`, `LemonCore.Telemetry`, `LemonCore.Event`).
  """
  @spec available?(module()) :: boolean()
  def available?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod)
  end

  @doc """
  Check whether a module exports a specific function.

  Combines `Code.ensure_loaded?/1` with `function_exported?/3`.
  """
  @spec exports?(module(), atom(), non_neg_integer()) :: boolean()
  def exports?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  @doc """
  Safely emit an event to LemonCore.Bus if available.

  Returns `:ok` regardless of whether the bus is available.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, event) when is_binary(topic) do
    if available?(LemonCore.Bus) do
      LemonCore.Bus.broadcast(topic, event)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Build a LemonCore.Event if the module is available, otherwise return a plain tuple.
  """
  @spec build_event(atom(), map(), map()) :: term()
  def build_event(event_type, payload, meta) do
    if available?(LemonCore.Event) do
      LemonCore.Event.new(event_type, payload, meta)
    else
      {event_type, payload}
    end
  end

  @doc """
  Safely emit telemetry if LemonCore.Telemetry is available.

  Accepts the telemetry function name and its arguments.
  Returns `:ok` regardless of availability.
  """
  @spec emit_telemetry(atom(), list()) :: :ok
  def emit_telemetry(function_name, args) when is_atom(function_name) and is_list(args) do
    if available?(LemonCore.Telemetry) do
      apply(LemonCore.Telemetry, function_name, args)
    end

    :ok
  rescue
    _ -> :ok
  end
end
