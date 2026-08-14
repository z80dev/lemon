defmodule LemonCore.Doctor.ChannelProofs do
  @moduledoc """
  Channel-shaped proof classification contributed by the channels-owned app.

  The doctor reads redacted smoke-proof JSON whose per-channel check names and
  evidence fields are defined by the app that owns the channels. Rather than
  hardcoding that knowledge, the framework resolves a proof spec through
  `LemonCore.Doctor.RuntimeModules` and routes every channel-shaped
  classification through `call/3`. The reference runtime registers the spec
  under `:doctor_runtime`:

      config :lemon_core, :doctor_runtime,
        channel_proofs: MyChannelsApp.Doctor.ProofSpec

  This is the same pattern as `LemonCore.Doctor.RuntimeModules` /
  `:workspace_diagnostics`. When no implementation is registered the
  diagnostics degrade to their documented fallbacks instead of failing:

    * `origin_cron_checks/0` — `[]`; the cron channel-origin proof group is
      omitted entirely.
    * `media_delivery_check_names/0` — `[]`; no proof is classified with the
      `channel_generated_media_delivery` scope.
    * `media_delivery_proof/1` — `%{}`; no channel delivery evidence is
      reported in `:media_proof`.
    * `media_delivery_check/1` — `nil`; the `media.channel_delivery` check is
      omitted from the media checks.
    * `failure_hint/1` — `nil`; core falls back to the generic
      `"proof_failure"` classification.
    * `setup_error_hint/1` — `nil`; core falls back to the generic
      `"proof_setup_failure"` classification.
    * `launch_gates/1` — `%{}`; only the core provider-media and
      terminal-backend launch gates remain.
  """

  @type proof_status :: map()

  @doc """
  Check names that mark a proof as a channel-origin cron delivery.

  The cron check builds its "channel origin" proof group from this list; an
  empty list omits the group.
  """
  @callback origin_cron_checks() :: [String.t()]

  @doc """
  Check names that classify a proof as channel-generated media delivery.
  """
  @callback media_delivery_check_names() :: [String.t()]

  @doc """
  Channel delivery evidence extracted from the given check maps.

  Returns a map merged into `:media_proof` (e.g. `:channel_delivery`,
  per-channel delivery flags, `:directive_leaked`).
  """
  @callback media_delivery_proof(checks :: [map()]) :: map()

  @doc """
  The `media.channel_delivery` check built from a full proof-status map.

  Return `nil` when the proof spec has no channel delivery to report.
  """
  @callback media_delivery_check(proof_status :: proof_status()) ::
              LemonCore.Doctor.Check.t() | nil

  @doc """
  Classifies a downcased failure hint into a channel-specific reason kind.

  Return `nil` to let core fall back to `"proof_failure"`.
  """
  @callback failure_hint(normalized_hint :: String.t()) :: String.t() | nil

  @doc """
  Classifies a downcased setup error into a channel-specific reason kind.

  Return `nil` to let core fall back to `"proof_setup_failure"`.
  """
  @callback setup_error_hint(normalized_error :: String.t()) :: String.t() | nil

  @doc """
  Channel-owned launch gates built from a full proof-status map.

  Returns a map keyed by gate name (e.g. `"channelDm"`); core merges these
  ahead of its own `providerMedia` and `terminalBackends` gates.
  """
  @callback launch_gates(proof_status :: proof_status()) :: %{optional(String.t()) => map()}

  @doc """
  The registered proof-spec module, or `nil` when none is configured or the
  configured module cannot be loaded.
  """
  @spec impl() :: module() | nil
  def impl do
    case LemonCore.Doctor.RuntimeModules.fetch(:channel_proofs) do
      nil -> nil
      mod -> if Code.ensure_loaded?(mod), do: mod, else: nil
    end
  end

  @doc """
  Calls `fun` on the registered proof spec with `args`.

  Returns `fallback` when no spec is registered, the spec does not export the
  function, or the call raises — mirroring `LemonCore.Doctor.SupportBundle`'s
  `probe/4` semantics so an unavailable or buggy spec never fails the doctor.
  """
  @spec call(atom(), [term()], term()) :: term()
  def call(fun, args, fallback) when is_atom(fun) and is_list(args) do
    case impl() do
      nil ->
        fallback

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
          try do
            apply(mod, fun, args)
          rescue
            _ -> fallback
          end
        else
          fallback
        end
    end
  end
end
