defmodule LemonCli.Setup.ModelReadiness do
  @moduledoc """
  One readiness vocabulary for "can this machine answer a message right now?".

  The CLI wizard, `lemon setup model` and the provider management RPC all report
  the same four states, so a terminal, the web app and the Mac app can describe
  the same machine identically:

    * `:verified` - a non-generating check passed just now
    * `:saved` - a credential resolves (or the provider is keyless) but was not
      verified: the provider has no check, it was unreachable, or the check
      failed for a non-authentication reason
    * `:action_required` - missing, expired or rejected credential, a model the
      account cannot use, or a default provider/model mismatch
    * `:not_configured` - no default provider/model and no usable credential

  `:verified` and `:saved` both count as ready; surfaces show which one. Only
  `check/1` reaches the network, and only through a non-generating request that
  sends no message. `status/1` and `detect/1` are offline and never read
  credential values.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAi.Auth.OpenAICodexOAuth
  alias LemonAi.Models
  alias LemonCli.Onboarding.Providers
  alias LemonCli.ProviderLiveCheck
  alias LemonCli.Setup.{ProviderAuth, Verification}
  alias LemonCore.{Config, Secrets}

  @type state :: :verified | :saved | :action_required | :not_configured

  @type reason ::
          :credential_missing
          | :credential_expired
          | :credential_rejected
          | :model_unavailable
          | :provider_unreachable
          | :check_unavailable
          | :check_failed
          | :no_default
          | :model_provider_mismatch
          | nil

  @type check :: :codex_discovery | :models_endpoint | nil

  @type readiness :: %{
          state: state(),
          provider_id: String.t() | nil,
          model_id: String.t() | nil,
          check: check(),
          reason: reason(),
          available_model_ids: [String.t()] | nil,
          suggested_model_id: String.t() | nil,
          checked_at_ms: integer() | nil
        }

  @type detected ::
          %{source: :codex_cli, provider_id: String.t()}
          | %{source: :environment, provider_id: String.t(), variable: String.t()}

  # Wire limits (spec §3.2): bounded lists keep diagnostics and payloads small.
  @max_model_ids 64
  @max_model_id_bytes 256
  @max_detected 64
  @model_id_format ~r/^[A-Za-z0-9._:-]+$/
  @env_var_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Derives readiness from local config and the encrypted store only.

  Never sends a request and therefore never returns `:verified`.

  ## Options

    * `:provider` - report this provider instead of the default one
    * `:config_path`, `:cwd` - config selection, as in `LemonCli.Setup.Verification`
    * `:setup_state` - a setup state already derived by the caller
    * `:secrets` - secrets module (tests)
  """
  @spec status(keyword()) :: readiness()
  def status(opts \\ []) do
    opts = bind_setup_state(opts)
    setup = Keyword.fetch!(opts, :setup_state)
    provider_state = setup.provider

    default_provider = provider_state.provider
    requested = Keyword.get(opts, :provider)
    provider = requested || default_provider
    provider_id = canonical(provider)

    cond do
      is_nil(provider_id) ->
        readiness(:not_configured, nil, nil, reason: :no_default)

      not default?(provider, default_provider) ->
        # A provider other than the default is reported on its credential alone;
        # it is not the identity a run would use.
        credential_state(provider_id, nil, opts)

      is_nil(provider_state.model) ->
        readiness(:action_required, provider_id, nil,
          reason: :no_default,
          suggested_model_id: suggested_model_id(provider_id, nil)
        )

      provider_state.reason == :model_provider_mismatch ->
        readiness(:action_required, provider_id, model_id(provider_state.model, provider_id),
          reason: :model_provider_mismatch,
          suggested_model_id: suggested_model_id(provider_id, nil)
        )

      true ->
        credential_state(provider_id, model_id(provider_state.model, provider_id), opts)
    end
  end

  @doc """
  Runs one bounded non-generating check (≤10 s) and maps it to a readiness state.

  Codex providers use authenticated model discovery; other providers use their
  models endpoint. Resolving an OAuth credential may refresh it, exactly as a
  model call would.

  ## Options

  `status/1`'s options plus:

    * `:verifier` - live-check function (arity 1 or 2); defaults to
      `LemonCli.ProviderLiveCheck.check/2`
    * `:codex_discover` - Codex discovery function passed to the live check
  """
  @spec check(keyword()) :: readiness()
  def check(opts \\ []) do
    opts = bind_setup_state(opts)

    case Verification.live_input(opts) do
      {:ok, input} -> live_readiness(input, opts)
      {:skip, reason} -> offline_readiness(reason, opts)
      {:error, reason} -> offline_readiness(reason, opts)
    end
  end

  @doc """
  Lists logins and keys already present on this machine, without reading values.

  A Codex CLI ChatGPT login is reported first; it is never imported here. The
  environment entries report variable names only, never their contents.

  ## Options

    * `:codex_login_status` - login probe (tests)
    * `:env_lookup` - environment reader, a map or a one-argument function (tests)
    * `:codex_auth_path` - explicit CLI login path (never accepted from RPC)
  """
  @spec detect(keyword()) :: [detected()]
  def detect(opts \\ []) do
    (detect_codex_cli(opts) ++ detect_environment(opts))
    |> Enum.take(@max_detected)
  end

  @doc """
  Projects readiness or detected logins onto their camelCase wire shape.
  """
  @spec to_wire(readiness() | detected() | [detected()]) :: map() | [map()]
  def to_wire(entries) when is_list(entries), do: Enum.map(entries, &to_wire/1)

  def to_wire(%{state: _} = readiness) do
    %{
      "state" => wire_atom(readiness.state),
      "providerId" => readiness.provider_id,
      "modelId" => readiness.model_id,
      "check" => wire_atom(readiness.check),
      "reason" => wire_atom(readiness.reason),
      "availableModelIds" => readiness.available_model_ids,
      "suggestedModelId" => readiness.suggested_model_id,
      "checkedAtMs" => readiness.checked_at_ms
    }
  end

  def to_wire(%{source: :codex_cli} = entry),
    do: %{"source" => "codex_cli", "providerId" => entry.provider_id}

  def to_wire(%{source: :environment} = entry),
    do: %{
      "source" => "environment",
      "providerId" => entry.provider_id,
      "variable" => entry.variable
    }

  # ──────────────────────────────────────────────────────────────────────────
  # Live check

  defp live_readiness(input, opts) do
    provider_id = canonical(input.provider) || to_string(input.provider)
    model_id = input[:model_id]
    codex? = input.api == :openai_codex_responses
    kind = if codex?, do: :codex_discovery, else: :models_endpoint
    now = System.system_time(:millisecond)

    case run_verifier(input, opts) do
      {:ok, info} when is_map(info) ->
        ids = sanitize_model_ids(info[:model_ids])

        readiness(:verified, provider_id, model_id,
          check: info[:check] || kind,
          available_model_ids: ids,
          suggested_model_id: suggested_model_id(provider_id, ids),
          checked_at_ms: now
        )

      {:error, {:model_unavailable, ids}} ->
        ids = sanitize_model_ids(ids)

        readiness(:action_required, provider_id, model_id,
          check: kind,
          reason: :model_unavailable,
          available_model_ids: ids,
          suggested_model_id: suggested_model_id(provider_id, ids),
          checked_at_ms: now
        )

      {:error, :unauthorized} ->
        checked(:action_required, provider_id, model_id, kind, :credential_rejected, now)

      {:error, {:unauthorized, _}} ->
        checked(:action_required, provider_id, model_id, kind, :credential_rejected, now)

      {:error, :credential_not_usable} ->
        checked(:action_required, provider_id, model_id, kind, :credential_missing, now)

      {:error, unreachable} when unreachable in [:unreachable, :timeout] ->
        checked(:saved, provider_id, model_id, kind, :provider_unreachable, now)

      {:error, {:check_failed, _}} ->
        checked(:saved, provider_id, model_id, kind, :check_failed, now)

      # Nothing was sent, so no check time is reported.
      {:skip, _} ->
        readiness(:saved, provider_id, model_id,
          reason: :check_unavailable,
          suggested_model_id: suggested_model_id(provider_id, nil)
        )

      {:error, _other} ->
        checked(:saved, provider_id, model_id, kind, :check_failed, now)
    end
  end

  defp run_verifier(input, opts) do
    case Keyword.get(opts, :verifier) do
      verifier when is_function(verifier, 2) -> verifier.(input, opts)
      verifier when is_function(verifier, 1) -> verifier.(input)
      nil -> ProviderLiveCheck.check(input, check_options(opts))
    end
  end

  defp check_options(opts), do: Keyword.take(opts, [:codex_discover, :http_get])

  # No live input means no request was made: fall back to the offline state and
  # name why the check did not run.
  defp offline_readiness(reason, opts) do
    base = status(opts)

    case reason do
      {:unsupported_api, _} ->
        if base.state == :saved, do: %{base | reason: :check_unavailable}, else: base

      :unknown_model ->
        base

      :model_provider_mismatch ->
        %{base | state: :action_required, reason: :model_provider_mismatch}

      :credential_not_usable ->
        %{base | state: :action_required, reason: :credential_missing}

      _ ->
        %{base | state: :action_required, reason: base.reason || :credential_missing}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Offline state

  defp credential_state(provider_id, model_id, opts) do
    provider_cfg = provider_table(provider_id, opts)
    secrets = Keyword.get(opts, :secrets, Secrets)
    suggested = suggested_model_id(provider_id, nil)

    {state, reason} =
      case ProviderAuth.static_status(provider_id, provider_cfg, secrets) do
        %{status: status} when status in ["ready", "configured"] -> {:saved, nil}
        %{status: "expired"} -> {:action_required, :credential_expired}
        _ -> {:action_required, :credential_missing}
      end

    readiness(state, provider_id, model_id,
      reason: reason,
      suggested_model_id: suggested
    )
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Detection

  defp detect_codex_cli(opts) do
    probe = Keyword.get(opts, :codex_login_status, &OpenAICodexOAuth.codex_cli_login_status/1)
    probe_opts = if path = Keyword.get(opts, :codex_auth_path), do: [path: path], else: []

    case probe.(probe_opts) do
      :present -> [%{source: :codex_cli, provider_id: "openai_codex"}]
      _ -> []
    end
  end

  defp detect_environment(opts) do
    read_env = env_reader(Keyword.get(opts, :env_lookup))

    Enum.flat_map(ProviderNames.all_canonical_names(), fn provider_id ->
      provider_id
      |> ProviderNames.env_vars()
      |> Enum.filter(&(Regex.match?(@env_var_format, &1) and present?(read_env.(&1))))
      |> Enum.map(&%{source: :environment, provider_id: provider_id, variable: &1})
    end)
  end

  defp env_reader(nil), do: &System.get_env/1
  defp env_reader(env) when is_map(env), do: &Map.get(env, &1)
  defp env_reader(fun) when is_function(fun, 1), do: fun

  # ──────────────────────────────────────────────────────────────────────────
  # Shared helpers

  defp bind_setup_state(opts) do
    setup = Keyword.get(opts, :setup_state) || Verification.setup_state(opts)
    Keyword.put(opts, :setup_state, setup)
  end

  # The static credential check reads the provider table exactly as written, so
  # it uses the config file's own string keys, not the resolved runtime config.
  defp provider_table(provider_id, opts) do
    path = Keyword.get(opts, :config_path) || Config.global_path()

    settings =
      with {:ok, content} <- File.read(Path.expand(path)),
           {:ok, decoded} <- Toml.decode(content) do
        decoded
      else
        _ -> %{}
      end

    ProviderNames.provider_config(Map.get(settings, "providers", %{}), provider_id) || %{}
  end

  defp readiness(state, provider_id, model_id, fields \\ []) do
    %{
      state: state,
      provider_id: provider_id,
      model_id: model_id,
      check: Keyword.get(fields, :check),
      reason: Keyword.get(fields, :reason),
      available_model_ids: Keyword.get(fields, :available_model_ids),
      suggested_model_id: Keyword.get(fields, :suggested_model_id),
      checked_at_ms: Keyword.get(fields, :checked_at_ms)
    }
  end

  defp checked(state, provider_id, model_id, check, reason, now) do
    readiness(state, provider_id, model_id,
      check: check,
      reason: reason,
      suggested_model_id: suggested_model_id(provider_id, nil),
      checked_at_ms: now
    )
  end

  defp canonical(nil), do: nil

  defp canonical(provider) do
    provider = to_string(provider)
    ProviderNames.canonical_name(provider) || present_or_nil(provider)
  end

  defp default?(provider, default_provider),
    do: not is_nil(default_provider) and canonical(provider) == canonical(default_provider)

  # Only a known provider prefix is stripped, so ids such as `qwen:7b` survive.
  defp model_id(nil, _provider_id), do: nil

  defp model_id(model, provider_id) do
    model = to_string(model)

    case String.split(model, ":", parts: 2) do
      [prefix, rest] ->
        if canonical(prefix) == provider_id and rest != "", do: rest, else: model

      _ ->
        present_or_nil(model)
    end
  end

  defp suggested_model_id(nil, _available), do: nil

  defp suggested_model_id(provider_id, available) do
    candidates =
      case available do
        [_ | _] -> available
        _ -> catalog_model_ids(provider_id)
      end

    preferred =
      case Providers.find(ProviderNames.config_name(provider_id) || provider_id) do
        nil -> []
        spec -> spec.preferred_models || []
      end

    Enum.find(preferred, &(&1 in candidates)) || List.first(candidates)
  end

  defp catalog_model_ids(provider_id) do
    case ProviderNames.provider_atom(provider_id) do
      nil -> []
      atom -> atom |> Models.get_models() |> Enum.map(& &1.id)
    end
  end

  defp sanitize_model_ids(nil), do: nil

  defp sanitize_model_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(fn
      %{id: id} -> id
      id -> id
    end)
    |> Enum.filter(
      &(is_binary(&1) and byte_size(&1) <= @max_model_id_bytes and
          Regex.match?(@model_id_format, &1))
    )
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_model_ids)
  end

  defp sanitize_model_ids(_), do: nil

  defp wire_atom(nil), do: nil
  defp wire_atom(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp present_or_nil(value), do: if(present?(value), do: value, else: nil)
end
