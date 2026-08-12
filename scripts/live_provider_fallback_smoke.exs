unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveProviderFallbackSmoke do
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}
  alias CodingAgent.Session.{ModelResolver, ProviderFallback}
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.{CredentialHealth, Credentials, SessionPins}

  @cross_check "live_provider_fallback_smoke"
  @pool_check "live_provider_fallback_credential_pool_smoke"

  @pool_bad_one_env "LEMON_SMOKE_POOL_BAD_ONE"
  @pool_bad_two_env "LEMON_SMOKE_POOL_BAD_TWO"
  @pool_good_env "LEMON_SMOKE_POOL_GOOD"

  # The client-error negative case (a 400 must NOT walk the fallback chain)
  # cannot be forced deterministically against a live provider, so it is
  # covered by a scripted-stream test instead of a live scenario here.
  @negative_client_error %{
    covered_by:
      "apps/coding_agent/test/coding_agent/session/provider_fallback_acceptance_test.exs",
    mode: "deterministic_test",
    note:
      "client-shaped (HTTP 400) errors relay terminally: single attempt, no provider/credential failover, no credential cooldown recorded"
  }

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [out: :string, primary: :string, fallback: :string, model: :string]
      )

    proof_path =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "provider-fallback-smoke-latest.json"])

    archive_path = archive_path(proof_path)

    scenarios =
      case live_config(opts) do
        {:skip, reason} ->
          [
            scenario(@cross_check, "cross_provider_fallback", :skipped, %{reason: reason}),
            scenario(@pool_check, "credential_pool_rotation", :skipped, %{reason: reason})
          ]

        {:ok, config} ->
          [run_cross_provider_smoke(config), run_credential_pool_smoke(config)]
      end

    proof = build_proof(scenarios)

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  # ---- Scenario 1: cross-provider fallback (primary key poisoned) ----

  defp run_cross_provider_smoke(config) do
    reset_runtime_state()

    providers =
      config.providers
      |> Map.put(config.primary_provider, %{api_key: "invalid-provider-fallback-smoke-key"})

    settings = %SettingsManager{
      default_model: %{
        provider: config.primary_provider,
        model_id: config.model,
        base_url: nil
      },
      providers: providers,
      provider_routing: %{
        enabled: true,
        fallback_providers: [config.fallback_provider],
        require_credentials: true
      }
    }

    primary_model = ModelResolver.resolve_session_model(nil, settings)
    stream_fn = ProviderFallback.maybe_wrap(nil, primary_model, settings, File.cwd!())

    context =
      Context.new(
        messages: [
          %UserMessage{
            content:
              "Reply with a short sentence confirming Lemon provider fallback works. Do not mention secrets."
          }
        ]
      )

    case stream_fn.(primary_model, context, %StreamOptions{
           max_tokens: 64,
           stream_timeout: 120_000
         }) do
      {:ok, stream} ->
        case LemonAi.EventStream.result(stream, 130_000) do
          {:ok, message} ->
            final_provider = message.provider && to_string(message.provider)

            fallback_fired =
              final_provider != nil and
                not same_provider?(final_provider, config.primary_provider)

            details = %{
              primary_provider: config.primary_provider,
              fallback_provider: config.fallback_provider,
              final_provider: final_provider,
              fallback_fired: fallback_fired,
              model: message.model,
              answer_hash: message |> output_text() |> hash(),
              cleanup: cleanup()
            }

            if fallback_fired do
              scenario(@cross_check, "cross_provider_fallback", :completed, details)
            else
              # An ambient live key for the primary provider (e.g. an env var)
              # can shadow the poisoned key; the proof must not claim fallback
              # fired when the turn never left the primary provider.
              scenario(
                @cross_check,
                "cross_provider_fallback",
                :failed,
                Map.put(details, :reason, "fallback_did_not_fire")
              )
            end

          {:error, message} ->
            scenario(@cross_check, "cross_provider_fallback", :failed, %{
              reason: "fallback_stream_error",
              primary_provider: config.primary_provider,
              fallback_provider: config.fallback_provider,
              final_provider: message.provider && to_string(message.provider),
              model: message.model,
              error_hash: hash(message.error_message || inspect(message.stop_reason)),
              cleanup: cleanup()
            })
        end

      {:error, reason} ->
        scenario(@cross_check, "cross_provider_fallback", :failed, %{
          reason: inspect(reason),
          cleanup: cleanup()
        })
    end
  end

  # ---- Scenario 2: credential-pool rotation on a single provider ----
  #
  # Same provider, two poisoned keys ahead of the real one: the turn must
  # succeed WITHOUT leaving the provider, committing on a credential that is
  # not the first pool entry (proven by the session pin, which only exists
  # when a non-first credential commits).

  defp run_credential_pool_smoke(config) do
    provider = config.fallback_provider
    good_key = Credentials.resolve_provider_api_key(provider, config.providers)

    if is_binary(good_key) and String.trim(good_key) != "" do
      try do
        reset_runtime_state()
        System.put_env(@pool_bad_one_env, "invalid-pool-smoke-key-one")
        System.put_env(@pool_bad_two_env, "invalid-pool-smoke-key-two")
        System.put_env(@pool_good_env, good_key)
        execute_credential_pool_smoke(config, provider)
      after
        Enum.each([@pool_bad_one_env, @pool_bad_two_env, @pool_good_env], &System.delete_env/1)
        reset_runtime_state()
      end
    else
      scenario(@pool_check, "credential_pool_rotation", :skipped, %{
        reason: "no resolvable live api key for #{provider}"
      })
    end
  end

  defp execute_credential_pool_smoke(config, provider) do
    pool_refs = ["env:#{@pool_bad_one_env}", "env:#{@pool_bad_two_env}", "env:#{@pool_good_env}"]
    good_ref = List.last(pool_refs)

    settings = %SettingsManager{
      default_model: %{provider: provider, model_id: config.model, base_url: nil},
      providers: config.providers,
      provider_routing: %{
        enabled: true,
        # Escape hatch so the fallback loop installs; landing on it means the
        # pool scenario failed (the assertion is that we never leave
        # `provider`), so its credentials are not required.
        fallback_providers: [escape_provider(provider, config.primary_provider)],
        require_credentials: false,
        default_pool: "smoke_pool",
        credential_pools: %{
          "smoke_pool" => %{
            providers: [provider],
            strategy: "priority",
            credentials: %{provider => pool_refs}
          }
        }
      }
    }

    session_id = "provider-fallback-smoke-pool-#{System.unique_integer([:positive])}"
    primary_model = ModelResolver.resolve_session_model(nil, settings)

    stream_fn =
      ProviderFallback.maybe_wrap(nil, primary_model, settings, File.cwd!(),
        session_id: session_id
      )

    context =
      Context.new(
        messages: [
          %UserMessage{
            content:
              "Reply with a short sentence confirming Lemon credential rotation works. Do not mention secrets."
          }
        ]
      )

    case stream_fn.(primary_model, context, %StreamOptions{
           max_tokens: 64,
           stream_timeout: 120_000
         }) do
      {:ok, stream} ->
        case LemonAi.EventStream.result(stream, 130_000) do
          {:ok, message} ->
            assess_pool_result(message, provider, session_id, pool_refs, good_ref)

          {:error, message} ->
            scenario(@pool_check, "credential_pool_rotation", :failed, %{
              reason: "credential_pool_stream_error",
              provider: provider,
              final_provider: message.provider && to_string(message.provider),
              model: message.model,
              error_hash: hash(message.error_message || inspect(message.stop_reason)),
              cleanup: cleanup()
            })
        end

      {:error, reason} ->
        scenario(@pool_check, "credential_pool_rotation", :failed, %{
          reason: inspect(reason),
          provider: provider,
          cleanup: cleanup()
        })
    end
  end

  defp assess_pool_result(message, provider, session_id, pool_refs, good_ref) do
    [first_bad_ref, second_bad_ref, _good_ref] = pool_refs
    final_provider = message.provider && to_string(message.provider)
    pinned = SessionPins.get(session_id)
    winning_ref = pinned && pinned.credential_ref

    details = %{
      provider: provider,
      final_provider: final_provider,
      model: message.model,
      pool_refs: pool_refs,
      winning_credential_ref: winning_ref,
      bad_credentials_in_cooldown: %{
        first_bad_ref => CredentialHealth.in_cooldown?(provider, first_bad_ref),
        second_bad_ref => CredentialHealth.in_cooldown?(provider, second_bad_ref)
      },
      answer_hash: message |> output_text() |> hash(),
      cleanup: cleanup()
    }

    cond do
      not same_provider?(final_provider, provider) ->
        scenario(
          @pool_check,
          "credential_pool_rotation",
          :failed,
          Map.put(details, :reason, "left_provider_during_credential_rotation")
        )

      winning_ref != good_ref ->
        # A first-entry commit leaves no pin, so a nil/mismatched winning ref
        # means rotation past the poisoned keys was not demonstrated.
        scenario(
          @pool_check,
          "credential_pool_rotation",
          :failed,
          Map.put(details, :reason, "winning_credential_not_rotated")
        )

      true ->
        scenario(@pool_check, "credential_pool_rotation", :completed, details)
    end
  end

  defp live_config(opts) do
    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run provider fallback proof"}

      true ->
        primary_provider = opts[:primary] || "openai"
        fallback_provider = opts[:fallback] || "zai"
        model = opts[:model] || "glm-5-turbo"
        config = LemonCore.Config.load(File.cwd!(), cache: false)

        if LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
             fallback_provider,
             config.providers,
             cwd: File.cwd!()
           ) do
          {:ok,
           %{
             providers: config.providers || %{},
             primary_provider: primary_provider,
             fallback_provider: fallback_provider,
             model: model
           }}
        else
          {:skip, "no configured credential resolved for #{fallback_provider}"}
        end
    end
  end

  defp scenario(check, name, status, details) do
    %{check: check, name: name, status: status, details: details}
  end

  defp build_proof(scenarios) do
    completed = Enum.count(scenarios, &(&1.status == :completed))
    failed = Enum.count(scenarios, &(&1.status == :failed))
    skipped = Enum.count(scenarios, &(&1.status == :skipped))

    status =
      cond do
        failed > 0 -> "failed"
        completed > 0 -> "completed"
        true -> "skipped"
      end

    cross = Enum.find(scenarios, &(&1.name == "cross_provider_fallback"))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: status,
      proof_object: "lemon.provider_fallback_smoke",
      proof_scope: "provider_fallback",
      checks: Enum.map(scenarios, &%{name: &1.check, status: to_string(&1.status)}),
      completed_count: completed,
      skipped_count: skipped,
      failed_count: failed,
      # Backward-compatible: the cross-provider scenario keeps its historical
      # top-level `details` slot; the full scenario list is additive below.
      details: cross.details,
      scenarios:
        Enum.map(
          scenarios,
          &%{name: &1.name, check: &1.check, status: to_string(&1.status), details: &1.details}
        ),
      negative_client_error: @negative_client_error,
      cleanup: cleanup()
    }
  end

  # A provider other than the pool provider so the fallback loop installs.
  defp escape_provider(pool_provider, preferred) do
    [preferred, "openai", "zai", "anthropic"]
    |> Enum.reject(&is_nil/1)
    |> Enum.find("openai", &(not same_provider?(&1, pool_provider)))
  end

  defp reset_runtime_state do
    CredentialHealth.reset()
    SessionPins.reset()
  end

  defp output_text(message) do
    message.content
    |> List.wrap()
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      _other -> ""
    end)
    |> Enum.join("")
  end

  defp cleanup do
    %{
      includes_raw_api_keys: false,
      includes_raw_prompts: false,
      includes_raw_answer: false
    }
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    root = String.trim_trailing(path, ext)
    "#{root}-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}#{ext}"
  end

  defp hash(nil), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
  end

  defp same_provider?(a, b), do: normalize_provider_id(a) == normalize_provider_id(b)

  defp normalize_provider_id(provider) when is_atom(provider) and not is_nil(provider),
    do: provider |> Atom.to_string() |> normalize_provider_id()

  defp normalize_provider_id(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider_id(_), do: nil
end

LemonScripts.LiveProviderFallbackSmoke.main(System.argv())
