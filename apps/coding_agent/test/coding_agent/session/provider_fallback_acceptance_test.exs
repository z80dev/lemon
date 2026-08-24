defmodule CodingAgent.Session.ProviderFallbackAcceptanceTest do
  @moduledoc """
  Deterministic acceptance coverage for the live fallback smoke script
  (`scripts/live_provider_fallback_smoke.exs`).

  The pool test mirrors the script's `credential_pool_rotation` scenario with
  a scripted stream. The negative test is the proof the script's
  `negative_client_error.covered_by` key points at: a client-shaped (HTTP 400)
  error cannot be forced deterministically from a live provider, so it is
  proven here instead - single attempt, terminal error, no failover, no
  credential cooldown recorded.
  """

  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, TextContent, Usage}
  alias LemonAgent.ModelRuntime.{CredentialHealth, SessionPins}
  alias CodingAgent.Session.ProviderFallback
  alias CodingAgent.SettingsManager

  @bad_one_env "PFA_POOL_BAD_ONE"
  @bad_two_env "PFA_POOL_BAD_TWO"
  @good_env "PFA_POOL_GOOD"

  setup do
    CredentialHealth.reset()
    SessionPins.reset()

    System.put_env(@bad_one_env, "pfa-bad-key-one")
    System.put_env(@bad_two_env, "pfa-bad-key-two")
    System.put_env(@good_env, "pfa-good-key")

    on_exit(fn ->
      CredentialHealth.reset()
      SessionPins.reset()
      Enum.each([@bad_one_env, @bad_two_env, @good_env], &System.delete_env/1)
    end)

    :ok
  end

  test "credential pool: two bad keys then a good one succeeds without leaving the provider" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    session_id = "pfa-pool-#{System.unique_integer([:positive])}"
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case {model.provider, options.api_key} do
        {:openai, key} when key in ["pfa-bad-key-one", "pfa-bad-key-two"] ->
          {:ok, error_stream(model, "Authentication failed (HTTP 401): invalid api key")}

        {:openai, "pfa-good-key"} ->
          {:ok, success_stream(model, "rotated key response")}

        {_other, _key} ->
          {:ok, success_stream(model, "unexpected escape-provider response")}
      end
    end

    wrapped =
      ProviderFallback.maybe_wrap(stream_fn, primary, pool_settings(), File.cwd!(),
        session_id: session_id
      )

    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:ok, message} = LemonAi.EventStream.result(stream, 1_000)

    # The turn succeeded without leaving the provider.
    assert message.provider == :openai
    assert [%TextContent{text: "rotated key response"}] = message.content

    assert_receive {:attempt, :openai, "pfa-bad-key-one"}
    assert_receive {:attempt, :openai, "pfa-bad-key-two"}
    assert_receive {:attempt, :openai, "pfa-good-key"}
    refute_receive {:attempt, :azure_openai_responses, _}, 100

    # The winning credential is not the first pool entry: a first-entry commit
    # clears the pin, a later entry pins its ref.
    assert SessionPins.get(session_id) == %{
             provider: "openai",
             credential_ref: "env:#{@good_env}"
           }

    assert CredentialHealth.in_cooldown?(:openai, "env:#{@bad_one_env}")
    assert CredentialHealth.in_cooldown?(:openai, "env:#{@bad_two_env}")
    refute CredentialHealth.in_cooldown?(:openai, "env:#{@good_env}")
  end

  test "negative: a client-shaped (HTTP 400) error does not walk the chain" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    session_id = "pfa-neg-#{System.unique_integer([:positive])}"
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})
      {:ok, error_stream(model, "Invalid request (HTTP 400): messages must be non-empty")}
    end

    wrapped =
      ProviderFallback.maybe_wrap(stream_fn, primary, pool_settings(), File.cwd!(),
        session_id: session_id
      )

    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    # Terminal error relayed from the single attempt.
    assert {:error, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert message.error_message =~ "HTTP 400"

    # Exactly one attempt: no credential advance, no provider fallback.
    assert_receive {:attempt, :openai, "pfa-bad-key-one"}
    refute_receive {:attempt, _, _}, 100

    # Client errors are request problems, not credential problems: no cooldown
    # was recorded and no pin was written.
    refute CredentialHealth.in_cooldown?(:openai, "env:#{@bad_one_env}")
    assert SessionPins.get(session_id) == nil
  end

  # Mirrors the smoke script's pool scenario settings: a priority pool of
  # three env-sourced credentials on the primary provider plus an escape
  # fallback provider that the assertions require to never be reached.
  defp pool_settings do
    %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{api_key: "primary-key"},
        "azure_openai_responses" => %{api_key: "fallback-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: false,
        default_pool: "smoke_pool",
        credential_pools: %{
          "smoke_pool" => %{
            providers: ["openai"],
            strategy: "priority",
            credentials: %{
              "openai" => ["env:#{@bad_one_env}", "env:#{@bad_two_env}", "env:#{@good_env}"]
            }
          }
        }
      }
    }
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
end
