defmodule LemonAgent.ModelRuntime.CredentialHealth do
  @moduledoc """
  Cooldown tracking for individual provider credentials.

  Records classified failures per `{provider, credential_ref}` and answers
  whether a credential is currently cooling down, so credential selection can
  skip keys that just failed instead of hammering them. Cooldown length is
  driven by the failure category:

    * `:rate_limit` - honors `retry_after_ms` from opts when the provider sent
      one, otherwise exponential backoff on consecutive failures.
    * `:auth` - long cooldown (minutes), doubling on repeated failures; a bad
      key rarely heals quickly but OAuth refreshes can restore it.
    * anything else (`:transient`, `:server`, `:unknown`, ...) - short backoff.

  `record_success/2` clears the credential's state. State lives in a public
  named ETS table owned by this process (same pattern as
  `LemonAgent.AbortSignal.TableOwner`); every call degrades safely when the
  table is missing - no cooldowns, never a crash on the call path.
  """

  use GenServer

  alias LemonAgent.ModelRuntime.ProviderNames

  @table :lemon_agent_credential_health

  # Backoff windows per failure category (base * 2^(failures - 1), capped).
  @rate_limit_base_ms 15_000
  @rate_limit_max_ms 300_000
  @auth_base_ms 300_000
  @auth_max_ms 3_600_000
  @short_base_ms 2_000
  @short_max_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Record a classified failure for a credential and start (or extend) its
  cooldown.

  Options:

    * `:retry_after_ms` - provider-supplied retry-after; used verbatim for
      `:rate_limit` failures instead of the computed backoff.
  """
  @spec record_failure(atom() | String.t(), String.t(), atom(), keyword()) :: :ok
  def record_failure(provider, ref, category, opts \\ []) do
    key = key(provider, ref)

    failures =
      case lookup(key) do
        {_until, failures, _category} -> failures + 1
        nil -> 1
      end

    cooldown_until = now_ms() + cooldown_ms(category, failures, opts)
    :ets.insert(@table, {key, cooldown_until, failures, category})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Clear a credential's failure state after a successful call.
  """
  @spec record_success(atom() | String.t(), String.t()) :: :ok
  def record_success(provider, ref) do
    :ets.delete(@table, key(provider, ref))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec in_cooldown?(atom() | String.t(), String.t()) :: boolean()
  def in_cooldown?(provider, ref) do
    case cooldown_until(provider, ref) do
      nil -> false
      until_ms -> until_ms > now_ms()
    end
  end

  @doc """
  The monotonic millisecond deadline of the credential's current cooldown, or
  `nil` when it has none recorded.
  """
  @spec cooldown_until(atom() | String.t(), String.t()) :: integer() | nil
  def cooldown_until(provider, ref) do
    case lookup(key(provider, ref)) do
      {until_ms, _failures, _category} -> until_ms
      nil -> nil
    end
  end

  @doc """
  Drop all recorded credential state. Intended for tests.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(:ok) do
    ensure_table()
    {:ok, %{}}
  end

  # If another process created the table with this process as heir, ETS sends
  # this message when the original owner exits.
  @impl true
  def handle_info({:"ETS-TRANSFER", @table, _from, _gift_data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp cooldown_ms(:rate_limit, failures, opts) do
    case Keyword.get(opts, :retry_after_ms) do
      retry_after_ms when is_integer(retry_after_ms) and retry_after_ms > 0 ->
        retry_after_ms

      _ ->
        LemonCore.Retry.capped_backoff(@rate_limit_base_ms, failures - 1, @rate_limit_max_ms)
    end
  end

  defp cooldown_ms(:auth, failures, _opts) do
    LemonCore.Retry.capped_backoff(@auth_base_ms, failures - 1, @auth_max_ms)
  end

  defp cooldown_ms(_category, failures, _opts) do
    LemonCore.Retry.capped_backoff(@short_base_ms, failures - 1, @short_max_ms)
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, until_ms, failures, category}] -> {until_ms, failures, category}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp key(provider, ref) do
    {normalize_provider(provider), to_string(ref)}
  end

  defp normalize_provider(provider) do
    ProviderNames.canonical_name(provider) ||
      provider |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
