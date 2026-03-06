defmodule LemonChannels.Adapters.Telegram.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates Telegram with the unified ModelPolicy system.

  This module provides a compatibility layer between Telegram's existing
  model preference storage and the new ModelPolicy system. It:

  1. Reads from the new ModelPolicy system first
  2. Falls back to legacy storage for backward compatibility
  3. Provides functions to migrate data to the new system

  ## Usage

  Use this module instead of direct legacy storage access for model resolution:

      # Old way (legacy typed store access)
      StateStore.get_default_model(key)

      # New way (unified policy resolution)
      ModelPolicyAdapter.resolve_model(state, chat_id, thread_id)
      ModelPolicyAdapter.resolve_thinking(account_id, chat_id, thread_id)

  ## Migration

  To migrate existing Telegram policies to the unified system:

      mix lemon.policy migrate_telegram

  Or programmatically:

      LemonCore.ModelPolicy.Migration.migrate_telegram()
  """

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route
  alias LemonChannels.Telegram.StateStore

  require Logger

  @doc """
  Resolves the effective model ID for a Telegram chat/thread.

  Checks in order:
  1. New ModelPolicy system
  2. Legacy telegram_default_model storage (backward compatibility)

  ## Examples

      iex> ModelPolicyAdapter.resolve_model(state, -1001234567890, nil)
      "claude-sonnet-4-20250514"

      iex> ModelPolicyAdapter.resolve_model(state, -1001234567890, 456)
      nil
  """
  @spec resolve_model(map(), integer(), integer() | nil) :: String.t() | nil
  def resolve_model(state, chat_id, thread_id) when is_integer(chat_id) do
    account_id = state.account_id || "default"
    route = Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))

    # First try the new ModelPolicy system
    case ModelPolicy.resolve_model_id(route) do
      nil ->
        # Fall back to legacy storage for backward compatibility
        resolve_legacy_model(state, chat_id, thread_id)

      model_id ->
        model_id
    end
  end

  def resolve_model(_state, _chat_id, _thread_id), do: nil

  @doc """
  Resolves the effective thinking level for a Telegram chat/thread.

  Checks in order:
  1. New ModelPolicy system
  2. Legacy telegram_default_thinking storage (backward compatibility)

  ## Examples

      iex> ModelPolicyAdapter.resolve_thinking("default", -1001234567890, nil)
      :high

      iex> ModelPolicyAdapter.resolve_thinking("default", -1001234567890, 456)
      nil
  """
  @spec resolve_thinking(String.t(), integer(), integer() | nil) :: atom() | nil
  def resolve_thinking(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    route = Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))

    # First try the new ModelPolicy system
    case ModelPolicy.resolve_thinking_level(route) do
      nil ->
        # Fall back to legacy storage for backward compatibility
        resolve_legacy_thinking(account_id, chat_id, thread_id)

      level ->
        level
    end
  end

  def resolve_thinking(_account_id, _chat_id, _thread_id), do: nil

  @doc """
  Sets a model policy for a Telegram chat/thread using the new ModelPolicy system.

  ## Examples

      iex> ModelPolicyAdapter.set_model(state, -1001234567890, nil, "claude-sonnet-4-20250514")
      :ok
  """
  @spec set_model(map(), integer(), integer() | nil, String.t()) :: :ok | {:error, term()}
  def set_model(state, chat_id, thread_id, model)
      when is_integer(chat_id) and is_binary(model) do
    account_id = state.account_id || "default"
    route = Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))

    policy =
      ModelPolicy.new_policy(model,
        set_by: "telegram_adapter",
        reason: "Set via Telegram adapter"
      )

    ModelPolicy.set(route, policy)
  end

  def set_model(_state, _chat_id, _thread_id, _model), do: :ok

  @doc """
  Sets a thinking level policy for a Telegram chat/thread.

  If a model policy already exists at this route, the thinking level is merged
  into it. Otherwise, the operation is skipped (thinking requires a model).

  ## Examples

      iex> ModelPolicyAdapter.set_thinking("default", -1001234567890, nil, :high)
      :ok
  """
  @spec set_thinking(String.t(), integer(), integer() | nil, atom()) :: :ok | {:error, term()}
  def set_thinking(account_id, chat_id, thread_id, level)
      when is_binary(account_id) and is_integer(chat_id) and is_atom(level) do
    route = Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))

    case ModelPolicy.get(route) do
      nil ->
        Logger.warning(
          "Cannot set thinking level without a model policy. " <>
            "Set a model first for route=#{inspect(Route.to_key(route))}"
        )

        {:error, :no_model_policy}

      existing_policy ->
        updated_policy = Map.put(existing_policy, :thinking_level, level)
        ModelPolicy.set(route, updated_policy)
    end
  end

  def set_thinking(_account_id, _chat_id, _thread_id, _level), do: :ok

  @doc """
  Clears the model policy for a Telegram chat/thread.

  ## Examples

      iex> ModelPolicyAdapter.clear_model(state, -1001234567890, nil)
      :ok
  """
  @spec clear_model(map(), integer(), integer() | nil) :: :ok | {:error, term()}
  def clear_model(state, chat_id, thread_id) when is_integer(chat_id) do
    account_id = state.account_id || "default"
    route = Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))
    ModelPolicy.clear(route)
  end

  def clear_model(_state, _chat_id, _thread_id), do: :ok

  @doc """
  Returns the ModelPolicy Route for a Telegram chat/thread.

  Useful for direct ModelPolicy operations.

  ## Examples

      iex> ModelPolicyAdapter.route_for(state, -1001234567890, 456)
      %Route{channel_id: "telegram", account_id: "default", peer_id: "-1001234567890", thread_id: "456"}
  """
  @spec route_for(map() | String.t(), integer(), integer() | nil) :: Route.t()
  def route_for(%{account_id: account_id}, chat_id, thread_id) do
    route_for(account_id || "default", chat_id, thread_id)
  end

  def route_for(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    Route.new("telegram", account_id, to_string(chat_id), to_string(thread_id))
  end

  # ============================================================================
  # Private Functions - Legacy Compatibility
  # ============================================================================

  defp resolve_legacy_model(state, chat_id, thread_id) when is_integer(chat_id) do
    key = {state.account_id || "default", chat_id, thread_id}

    case StateStore.get_default_model(key) do
      %{model: model} when is_binary(model) and model != "" -> model
      %{"model" => model} when is_binary(model) and model != "" -> model
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_legacy_thinking(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_integer(chat_id) do
    key = {account_id, chat_id, thread_id}

    case StateStore.get_default_thinking(key) do
      %{thinking_level: level} -> normalize_thinking_level(level)
      %{"thinking_level" => level} -> normalize_thinking_level(level)
      level -> normalize_thinking_level(level)
    end
  rescue
    _ -> nil
  end

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(level) when is_atom(level), do: level

  defp normalize_thinking_level(level) when is_binary(level) do
    case String.downcase(String.trim(level)) do
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
      _ -> nil
    end
  end

  defp normalize_thinking_level(_), do: nil
end
