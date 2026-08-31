Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveProviderConfigurationSmoke do
  @moduledoc false

  alias CodingAgent.Session.ProviderFallback
  alias CodingAgent.SettingsManager
  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, TextContent, Usage}
  alias LemonAgent.ModelRuntime.{CredentialHealth, ProviderStatus, SessionPins}
  alias LemonControlPlane.Methods.ProvidersConfigure

  @bad_env "LEMON_PROVIDER_CONFIG_SMOKE_BAD"
  @next_env "LEMON_PROVIDER_CONFIG_SMOKE_NEXT"

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    out =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "provider-configuration-smoke-latest.json"])

    root =
      Path.join(
        System.tmp_dir!(),
        "lemon-provider-configuration-smoke-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".lemon"))
    config_path = Path.join([root, ".lemon", "config.toml"])

    File.write!(config_path, """
    # provider-configuration-smoke sentinel
    [defaults]
    provider = "openai"
    model = "gpt-4"

    [runtime.provider_routing]
    require_credentials = false
    """)

    bad_key = "stub-bad-#{System.unique_integer([:positive])}"
    next_key = "stub-next-#{System.unique_integer([:positive])}"
    System.put_env(@bad_env, bad_key)
    System.put_env(@next_env, next_key)

    try do
      proof = run_proof(root, config_path, bad_key, next_key)
      encoded = Jason.encode!(proof, pretty: true)

      assert_redacted!(encoded, [bad_key, next_key, @bad_env, @next_env])
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, encoded <> "\n")
      IO.puts(encoded)
    after
      CredentialHealth.reset()
      SessionPins.reset()
      System.delete_env(@bad_env)
      System.delete_env(@next_env)
      File.rm_rf!(root)
    end
  rescue
    error ->
      IO.puts(:stderr, "provider configuration smoke failed: #{Exception.message(error)}")
      System.halt(1)
  end

  defp run_proof(root, config_path, bad_key, next_key) do
    configure!(%{
      "action" => "fallback.add",
      "provider" => "azure_openai_responses",
      "scope" => "project",
      "projectDir" => root,
      "apply" => true
    })

    configure!(%{
      "action" => "pool.upsert",
      "pool" => "smoke_pool",
      "providers" => ["openai"],
      "strategy" => "priority",
      "activate" => true,
      "scope" => "project",
      "projectDir" => root,
      "apply" => true
    })

    Enum.each([@bad_env, @next_env], fn env_name ->
      configure!(%{
        "action" => "pool.credential.add",
        "pool" => "smoke_pool",
        "provider" => "openai",
        "credentialRef" => "env:#{env_name}",
        "scope" => "project",
        "projectDir" => root,
        "apply" => true
      })
    end)

    content = File.read!(config_path)
    assert!(content =~ "# provider-configuration-smoke sentinel", "config comment was lost")

    preview =
      configure!(%{
        "action" => "fallback.remove",
        "provider" => "azure_openai_responses",
        "scope" => "project",
        "projectDir" => root,
        "apply" => false
      })

    assert!(get_in(preview, ["confirmation", "required"]) == true, "preview omitted guard")

    guarded =
      ProvidersConfigure.handle(
        %{
          "action" => "fallback.remove",
          "provider" => "azure_openai_responses",
          "scope" => "project",
          "projectDir" => root,
          "apply" => true
        },
        %{}
      )

    assert!(match?({:error, {:conflict, _, _}}, guarded), "destructive write was not guarded")
    assert!(File.read!(config_path) == content, "guarded operation changed config")

    status = ProviderStatus.snapshot(%{"projectDir" => root})
    routing = status["routingConfig"]
    assert!(routing["credentialReferenceCount"] == 2, "credential counts were not loaded")

    settings = SettingsManager.load(root)
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    assert!(not is_nil(primary), "primary stub model is missing")

    fallback = run_fallback(settings, primary, bad_key, next_key)
    terminal = run_terminal_failure(settings, primary)

    %{
      "generatedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => "completed",
      "proofObject" => "lemon.provider_configuration_smoke",
      "proofScope" => "provider_configuration",
      "checks" => [
        %{"name" => "control_plane_configuration", "status" => "completed"},
        %{"name" => "credential_and_provider_fallback", "status" => "completed"},
        %{"name" => "terminal_client_error", "status" => "completed"}
      ],
      "configuration" => %{
        "commentPreserved" => true,
        "destructiveGuardEnforced" => true,
        "fallbackProviderCount" => length(routing["fallbackProviders"]),
        "credentialPoolCount" => routing["credentialPoolCount"],
        "credentialReferenceCount" => routing["credentialReferenceCount"]
      },
      "fallback" => fallback,
      "terminalFailure" => terminal,
      "cleanup" => cleanup()
    }
  end

  defp configure!(params) do
    case ProvidersConfigure.handle(params, %{}) do
      {:ok, result} ->
        serialized = Jason.encode!(result)
        assert_redacted!(serialized, [@bad_env, @next_env])
        result

      other ->
        raise "provider configuration failed: #{inspect(other)}"
    end
  end

  defp run_fallback(settings, primary, bad_key, next_key) do
    CredentialHealth.reset()
    SessionPins.reset()
    parent = self()
    session_id = "provider-config-smoke-fallback"

    stream_fn = fn model, _context, options ->
      send(parent, {:fallback_attempt, model.provider, options.api_key})

      case {model.provider, options.api_key} do
        {:openai, ^bad_key} ->
          {:ok, error_stream(model, "Authentication failed (HTTP 401): stub credential")}

        {:openai, ^next_key} ->
          {:ok, error_stream(model, "Provider unavailable (HTTP 503): stub outage")}

        {:azure_openai_responses, _} ->
          {:ok, success_stream(model, "stub fallback completed")}

        _ ->
          {:ok, error_stream(model, "Invalid request (HTTP 400): unexpected route")}
      end
    end

    wrapped =
      ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!(),
        session_id: session_id
      )

    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})
    {:ok, message} = LemonAi.EventStream.result(stream, 2_000)
    attempts = collect_attempts(:fallback_attempt)

    providers = Enum.map(attempts, fn {provider, _key} -> to_string(provider) end)

    assert!(
      providers == ["openai", "openai", "azure_openai_responses"],
      "fallback route order was not exercised"
    )

    assert!(message.provider == :azure_openai_responses, "fallback provider did not commit")

    assert!(
      CredentialHealth.in_cooldown?(:openai, "env:#{@bad_env}"),
      "failed credential was not cooled down"
    )

    assert!(
      CredentialHealth.in_cooldown?(:openai, "env:#{@next_env}"),
      "failed provider attempt was not cooled down"
    )

    %{
      "attemptProviders" => providers,
      "attemptCount" => length(attempts),
      "credentialRotationObserved" => true,
      "providerFallbackObserved" => true,
      "failedCredentialCooldowns" => 2,
      "finalProvider" => to_string(message.provider)
    }
  end

  defp run_terminal_failure(settings, primary) do
    CredentialHealth.reset()
    SessionPins.reset()
    parent = self()

    stream_fn = fn model, _context, _options ->
      send(parent, {:terminal_attempt, model.provider})
      {:ok, error_stream(model, "Invalid request (HTTP 400): stub client error")}
    end

    wrapped =
      ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!(),
        session_id: "provider-config-smoke-terminal"
      )

    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})
    {:error, message} = LemonAi.EventStream.result(stream, 2_000)
    attempts = collect_attempts(:terminal_attempt)

    assert!(attempts == [:openai], "client error incorrectly walked the fallback chain")
    assert!(message.provider == :openai, "client error changed providers")
    refute_cooldown!()

    %{
      "attemptProviders" => Enum.map(attempts, &to_string/1),
      "attemptCount" => length(attempts),
      "fallbackSuppressed" => true,
      "finalProvider" => to_string(message.provider)
    }
  end

  defp collect_attempts(tag, acc \\ []) do
    receive do
      {^tag, provider, key} -> collect_attempts(tag, [{provider, key} | acc])
      {^tag, provider} -> collect_attempts(tag, [provider | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp refute_cooldown! do
    assert!(
      not CredentialHealth.in_cooldown?(:openai, "env:#{@bad_env}"),
      "client error incorrectly cooled a credential"
    )
  end

  defp success_stream(model, text) do
    message = message(model, :stop, text, nil)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:text_start, 0, message})
      LemonAi.EventStream.push(stream, {:text_delta, 0, text, message})
      LemonAi.EventStream.push(stream, {:text_end, 0, text, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end

  defp error_stream(model, error_message) do
    message = message(model, :error, "", error_message)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.error(stream, message)
    end)

    stream
  end

  defp message(model, stop_reason, text, error_message) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{},
      stop_reason: stop_reason,
      error_message: error_message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp assert_redacted!(serialized, forbidden) do
    Enum.each(forbidden, fn value ->
      assert!(not String.contains?(serialized, value), "proof leaked credential material")
    end)
  end

  defp cleanup do
    %{
      "includesRawApiKeys" => false,
      "includesSecretNames" => false,
      "includesCredentialReferences" => false,
      "includesRawProviderResponses" => false
    }
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

LemonScripts.LiveProviderConfigurationSmoke.main(System.argv())
