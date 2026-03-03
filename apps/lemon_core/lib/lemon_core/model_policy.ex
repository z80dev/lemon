defmodule LemonCore.ModelPolicy do
  @moduledoc """
  Route-based model policy management for Lemon.

  Provides persistent storage and resolution of model preferences
  at different granularities: channel, account, peer (chat/DM), and thread.

  ## Policy Structure

  A model policy consists of:
  - `model_id` - The AI model identifier (e.g., "claude-sonnet-4-20250514")
  - `thinking_level` - Optional thinking level (:minimal, :low, :medium, :high, :xhigh)
  - `metadata` - Additional policy metadata (set_by, reason, timestamp, etc.)

  ## Precedence

  Policies are resolved with the following precedence (highest to lowest):

  1. Session override (temporary, not persisted)
  2. Thread-level policy (most specific route)
  3. Peer/Chat-level policy
  4. Account-level policy
  5. Channel-type policy (least specific route)
  6. Global default (from config)

  ## Usage

      # Set a policy for a specific Telegram thread
      route = Route.new("telegram", "default", "-1001234567890", "456")
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514", thinking_level: :medium)
      ModelPolicy.set(route, policy)

      # Resolve policy for a route (finds most specific match)
      {:ok, resolved} = ModelPolicy.resolve(route)

      # Clear a policy
      ModelPolicy.clear(route)

      # List all policies for a channel
      policies = ModelPolicy.list("telegram")
  """

  alias LemonCore.ModelPolicy.Route

  require Logger

  @model_policy_table :model_policies

  @typedoc "Model identifier string"
  @type model_id :: String.t()

  @typedoc "Thinking level for reasoning models"
  @type thinking_level :: :minimal | :low | :medium | :high | :xhigh | nil

  @typedoc "Policy metadata map"
  @type metadata :: %{
          optional(:set_by) => String.t(),
          optional(:reason) => String.t(),
          optional(:set_at_ms) => integer(),
          optional(:updated_at_ms) => integer(),
          optional(atom()) => term()
        }

  @typedoc "Model policy struct"
  @type policy :: %{
          required(:model_id) => model_id(),
          optional(:thinking_level) => thinking_level(),
          optional(:metadata) => metadata()
        }

  @doc """
  Creates a new policy map with the given model and options.

  ## Options

    * `:thinking_level` - The thinking level (:minimal, :low, :medium, :high, :xhigh)
    * `:set_by` - Identifier of who/what set this policy
    * `:reason` - Optional reason for the policy
    * `:metadata` - Additional metadata to include

  ## Examples

      iex> ModelPolicy.new_policy("claude-sonnet-4-20250514")
      %{model_id: "claude-sonnet-4-20250514", metadata: %{set_at_ms: _}}

      iex> ModelPolicy.new_policy("gpt-4o", thinking_level: :medium, set_by: "admin")
      %{model_id: "gpt-4o", thinking_level: :medium, metadata: %{set_by: "admin", set_at_ms: _}}
  """
  @spec new_policy(model_id(), keyword()) :: policy()
  def new_policy(model_id, opts \\ []) when is_binary(model_id) do
    thinking_level = normalize_thinking_level(Keyword.get(opts, :thinking_level))
    now = System.system_time(:millisecond)

    metadata =
      %{}
      |> put_if_present(:set_by, Keyword.get(opts, :set_by))
      |> put_if_present(:reason, Keyword.get(opts, :reason))
      |> Map.put(:set_at_ms, now)

    metadata =
      case Keyword.get(opts, :metadata) do
        extra when is_map(extra) -> Map.merge(metadata, extra)
        _ -> metadata
      end

    base = %{
      model_id: model_id,
      metadata: metadata
    }

    if thinking_level do
      Map.put(base, :thinking_level, thinking_level)
    else
      base
    end
  end

  @doc """
  Sets a model policy for a specific route.

  ## Examples

      iex> route = Route.new("telegram", "default", "-1001234567890", nil)
      iex> policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")
      iex> ModelPolicy.set(route, policy)
      :ok
  """
  @spec set(Route.t(), policy()) :: :ok | {:error, term()}
  def set(%Route{} = route, policy) when is_map(policy) do
    key = Route.to_key(route)
    policy = ensure_metadata_timestamp(policy)

    Logger.debug(
      "Setting model policy for route=#{inspect(key)} model_id=#{policy.model_id}"
    )

    LemonCore.Store.put(@model_policy_table, key, policy)
  end

  @doc """
  Gets the exact policy for a route without resolution.

  Returns `nil` if no policy is set for the exact route.

  ## Examples

      iex> ModelPolicy.get(route)
      %{model_id: "claude-sonnet-4-20250514", metadata: %{...}}

      iex> ModelPolicy.get(unknown_route)
      nil
  """
  @spec get(Route.t()) :: policy() | nil
  def get(%Route{} = route) do
    key = Route.to_key(route)
    LemonCore.Store.get(@model_policy_table, key)
  end

  @doc """
  Clears the policy for a specific route.

  ## Examples

      iex> ModelPolicy.clear(route)
      :ok
  """
  @spec clear(Route.t()) :: :ok | {:error, term()}
  def clear(%Route{} = route) do
    key = Route.to_key(route)
    Logger.debug("Clearing model policy for route=#{inspect(key)}")
    LemonCore.Store.delete(@model_policy_table, key)
  end

  @doc """
  Resolves the effective policy for a route using precedence rules.

  Checks policies in order of specificity:
  1. Exact route match (thread-level)
  2. Peer-level (without thread)
  3. Account-level
  4. Channel-level

  Returns `{:ok, policy}` if a policy is found, or `{:error, :not_found}`
  if no policy exists at any level.

  ## Examples

      iex> route = Route.new("telegram", "default", "-1001234567890", "456")
      iex> ModelPolicy.resolve(route)
      {:ok, %{model_id: "claude-sonnet-4-20250514", metadata: %{...}}}

      iex> ModelPolicy.resolve(unknown_route)
      {:error, :not_found}
  """
  @spec resolve(Route.t()) :: {:ok, policy()} | {:error, :not_found}
  def resolve(%Route{} = route) do
    keys = Route.precedence_keys(route)

    result =
      Enum.find_value(keys, fn key ->
        case LemonCore.Store.get(@model_policy_table, key) do
          nil -> nil
          policy -> {key, policy}
        end
      end)

    case result do
      nil ->
        {:error, :not_found}

      {matched_key, policy} ->
        Logger.debug(
          "Resolved model policy for route=#{inspect(Route.to_key(route))} " <>
            "matched=#{inspect(matched_key)} model_id=#{policy.model_id}"
        )

        {:ok, policy}
    end
  end

  @doc """
  Resolves the effective model ID for a route.

  Convenience function that returns just the model ID, or nil if not found.

  ## Examples

      iex> ModelPolicy.resolve_model_id(route)
      "claude-sonnet-4-20250514"

      iex> ModelPolicy.resolve_model_id(unknown_route)
      nil
  """
  @spec resolve_model_id(Route.t()) :: model_id() | nil
  def resolve_model_id(%Route{} = route) do
    case resolve(route) do
      {:ok, %{model_id: model_id}} -> model_id
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Resolves the effective thinking level for a route.

  ## Examples

      iex> ModelPolicy.resolve_thinking_level(route)
      :medium

      iex> ModelPolicy.resolve_thinking_level(unknown_route)
      nil
  """
  @spec resolve_thinking_level(Route.t()) :: thinking_level()
  def resolve_thinking_level(%Route{} = route) do
    case resolve(route) do
      {:ok, %{thinking_level: level}} when level != nil -> level
      {:ok, _} -> nil
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Lists all policies, optionally filtered by channel.

  ## Examples

      # All policies
      iex> ModelPolicy.list()
      [{%{channel_id: "telegram", ...}, %{model_id: "...", ...}}, ...]

      # Policies for Telegram only
      iex> ModelPolicy.list("telegram")
      [{%{channel_id: "telegram", ...}, %{model_id: "...", ...}}, ...]
  """
  @spec list() :: [{Route.t(), policy()}]
  def list do
    @model_policy_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {key, policy} ->
      {Route.from_key(key), policy}
    end)
  end

  @spec list(Route.channel_id()) :: [{Route.t(), policy()}]
  def list(channel_id) when is_binary(channel_id) do
    list()
    |> Enum.filter(fn {route, _policy} ->
      route.channel_id == channel_id
    end)
  end

  @doc """
  Clears all policies for a channel.

  ## Examples

      iex> ModelPolicy.clear_channel("telegram")
      :ok
  """
  @spec clear_channel(Route.channel_id()) :: :ok
  def clear_channel(channel_id) when is_binary(channel_id) do
    list(channel_id)
    |> Enum.each(fn {route, _policy} ->
      clear(route)
    end)

    :ok
  end

  @doc """
  Checks if a policy exists for the exact route.

  ## Examples

      iex> ModelPolicy.exists?(route)
      true
  """
  @spec exists?(Route.t()) :: boolean()
  def exists?(%Route{} = route) do
    get(route) != nil
  end

  @doc """
  Updates a policy's metadata without changing the model.

  ## Examples

      iex> ModelPolicy.update_metadata(route, reason: "Updated for cost optimization")
      :ok
  """
  @spec update_metadata(Route.t(), keyword()) :: :ok | {:error, term()}
  def update_metadata(%Route{} = route, updates) when is_list(updates) do
    case get(route) do
      nil ->
        {:error, :not_found}

      policy ->
        metadata =
          Map.get(policy, :metadata, %{})
          |> Map.put(:updated_at_ms, System.system_time(:millisecond))

        metadata =
          Enum.reduce(updates, metadata, fn {key, value}, acc ->
            if key in [:set_by, :reason] do
              Map.put(acc, key, value)
            else
              acc
            end
          end)

        policy = Map.put(policy, :metadata, metadata)
        set(route, policy)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(level) when is_atom(level) do
    if level in [:minimal, :low, :medium, :high, :xhigh] do
      level
    else
      nil
    end
  end

  defp normalize_thinking_level(level) when is_binary(level) do
    case String.downcase(level) do
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
      _ -> nil
    end
  end

  defp normalize_thinking_level(_), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp ensure_metadata_timestamp(%{metadata: metadata} = policy) when is_map(metadata) do
    if Map.has_key?(metadata, :set_at_ms) do
      policy
    else
      put_in(policy.metadata.set_at_ms, System.system_time(:millisecond))
    end
  end

  defp ensure_metadata_timestamp(policy) do
    Map.put(policy, :metadata, %{set_at_ms: System.system_time(:millisecond)})
  end
end
