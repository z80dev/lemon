defmodule LemonCore.Testing.HermeticEnv do
  @moduledoc """
  Environment snapshot/restore helpers for tests that mutate process-wide env.

  Ambient provider and platform credentials are scrubbed before the BEAM
  starts, by the single list in `scripts/test` (`SCRUB_CREDENTIAL_ENV_VARS`);
  `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1` keeps them for live runs.
  """

  @doc """
  Runs `fun` and restores the provided env vars afterward.

  This helper is intentionally small and synchronous. Use it from `async: false`
  tests when mutating process-wide environment variables.
  """
  @spec with_restored_env([String.t()], (-> result)) :: result when result: term()
  def with_restored_env(keys, fun) when is_list(keys) and is_function(fun, 0) do
    snapshot = snapshot_env(keys)

    try do
      fun.()
    after
      restore_env(snapshot)
    end
  end

  @doc """
  Captures current values for env vars.
  """
  @spec snapshot_env([String.t()]) :: %{String.t() => String.t() | nil}
  def snapshot_env(keys) when is_list(keys) do
    Map.new(keys, fn key -> {key, System.get_env(key)} end)
  end

  @doc """
  Restores env vars captured with `snapshot_env/1`.
  """
  @spec restore_env(%{String.t() => String.t() | nil}) :: :ok
  def restore_env(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    :ok
  end
end
