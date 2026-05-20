unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveProviderFallbackSmoke do
  alias Ai.Types.{Context, StreamOptions, UserMessage}
  alias CodingAgent.Session.{ModelResolver, ProviderFallback}
  alias CodingAgent.SettingsManager

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [out: :string, primary: :string, fallback: :string, model: :string]
      )

    proof_path =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "provider-fallback-smoke-latest.json"])

    archive_path = archive_path(proof_path)

    proof =
      case live_config(opts) do
        {:skip, reason} -> proof(:skipped, %{reason: reason})
        {:ok, config} -> run_smoke(config)
      end

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run_smoke(config) do
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
        case Ai.EventStream.result(stream, 130_000) do
          {:ok, message} ->
            proof(:completed, %{
              primary_provider: config.primary_provider,
              fallback_provider: config.fallback_provider,
              final_provider: message.provider && to_string(message.provider),
              model: message.model,
              answer_hash: message |> output_text() |> hash(),
              cleanup: cleanup()
            })

          {:error, message} ->
            proof(:failed, %{
              reason: "fallback_stream_error",
              final_provider: message.provider && to_string(message.provider),
              model: message.model,
              error_hash: hash(message.error_message || inspect(message.stop_reason)),
              cleanup: cleanup()
            })
        end

      {:error, reason} ->
        proof(:failed, %{reason: inspect(reason), cleanup: cleanup()})
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

        if LemonAiRuntime.provider_has_credentials?(fallback_provider, config.providers,
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

  defp proof(:completed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      proof_object: "lemon.provider_fallback_smoke",
      proof_scope: "provider_fallback",
      checks: [%{name: "live_provider_fallback_smoke", status: "completed"}],
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: "lemon.provider_fallback_smoke",
      proof_scope: "provider_fallback",
      checks: [%{name: "live_provider_fallback_smoke", status: "failed"}],
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:skipped, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "skipped",
      proof_object: "lemon.provider_fallback_smoke",
      proof_scope: "provider_fallback",
      checks: [%{name: "live_provider_fallback_smoke", status: "skipped"}],
      completed_count: 0,
      skipped_count: 1,
      failed_count: 0,
      details: details,
      cleanup: cleanup()
    }
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
end

LemonScripts.LiveProviderFallbackSmoke.main(System.argv())
