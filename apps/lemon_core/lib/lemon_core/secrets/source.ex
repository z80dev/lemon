defmodule LemonCore.Secrets.Source do
  @moduledoc """
  Read-only contract for external credential sources.

  Implementations return a bounded in-memory name/value map. The shared
  orchestrator owns ordering, caching, timeouts, provenance, and redacted
  diagnostics. Implementations must not log, prompt, persist, or mutate the
  process environment.
  """

  alias LemonCore.Config.Secrets.Source, as: SourceConfig

  @type error_kind ::
          :binary_missing
          | :bootstrap_secret_missing
          | :exit_nonzero
          | :invalid_config
          | :invalid_output
          | :not_found
          | :output_too_large
          | :source_supervisor_unavailable
          | :spawn_failed
          | :timeout

  @type fetch_result :: %{
          required(:values) => %{optional(String.t()) => String.t()},
          required(:byte_count) => non_neg_integer()
        }

  @type bootstrap :: (String.t() -> {:ok, String.t(), :store | :env} | {:error, term()})

  @callback fetch(SourceConfig.t(), bootstrap()) ::
              {:ok, fetch_result()} | {:error, error_kind()}

  @callback configured?(SourceConfig.t()) :: boolean()
  @callback executable(SourceConfig.t()) :: String.t() | nil
  @callback bootstrap_ready?(SourceConfig.t(), bootstrap()) :: boolean()
  @callback scope(SourceConfig.t(), String.t()) :: SourceConfig.t() | nil
  @callback runs(SourceConfig.t()) :: pos_integer()

  # These three callbacks define the operator TOML of registered adapters.
  @callback config_keys() :: [String.t()]
  @callback options(map()) :: map()
  @callback validate([String.t()], map(), map(), String.t()) :: [String.t()]

  @optional_callbacks bootstrap_ready?: 2,
                      scope: 2,
                      runs: 1,
                      config_keys: 0,
                      options: 1,
                      validate: 4
end
