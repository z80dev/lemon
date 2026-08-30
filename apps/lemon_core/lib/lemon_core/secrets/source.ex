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

  @callback fetch(SourceConfig.t(), keyword()) ::
              {:ok, fetch_result()} | {:error, error_kind()}

  @callback configured?(SourceConfig.t()) :: boolean()
  @callback bootstrap_ready?(SourceConfig.t(), keyword()) :: boolean()

  @optional_callbacks bootstrap_ready?: 2
end
