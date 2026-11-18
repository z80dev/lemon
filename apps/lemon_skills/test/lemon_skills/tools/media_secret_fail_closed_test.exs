defmodule LemonSkills.Tools.MediaSecretFailClosedTest do
  @moduledoc """
  An unreadable configured speech/transcription secret must stop credential
  resolution instead of falling through to default secret aliases or env.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonSkills.Tools.{MediaGenerateSpeech, MediaTranscribeAudio}

  @moduletag :tmp_dir
  @tripwire "tripwire-secret-value"
  @env_vars ~w(LEMON_SECRETS_MASTER_KEY ELEVENLABS_API_KEY elevenlabs_api_key DEEPGRAM_API_KEY deepgram_api_key)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)
    clear_secrets_table()
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])
      {:ok, %Req.Response{status: 200, body: "unused"}}
    end

    %{
      secret: "LEMON_T07C_MEDIA_SECRET_#{System.unique_integer([:positive])}",
      requests: requests,
      http_post: http_post
    }
  end

  test "elevenlabs: corrupt configured secret never falls back to aliases or env", ctx do
    arm_tripwires(ctx.secret, "ELEVENLABS_API_KEY", "elevenlabs_api_key")

    tool =
      MediaGenerateSpeech.tool(ctx.tmp_dir,
        output_guard: :none,
        media_speech_config: %{gateway: %{voice: %{elevenlabs_api_key_secret: ctx.secret}}},
        elevenlabs_tts_base_url: "https://api.elevenlabs.test/v1",
        media_speech_http_post: ctx.http_post
      )

    result =
      tool.execute.(
        "call-1",
        %{"text" => "hello", "provider" => "elevenlabs_tts", "voice" => "voice_123"},
        nil,
        nil
      )

    assert_no_tripwire(ctx.requests)
    assert {:error, _} = result
  end

  test "deepgram: corrupt configured secret never falls back to aliases or env", ctx do
    arm_tripwires(ctx.secret, "DEEPGRAM_API_KEY", "deepgram_api_key")
    File.write!(Path.join(ctx.tmp_dir, "a.wav"), wav_bytes())

    tool =
      MediaTranscribeAudio.tool(ctx.tmp_dir,
        output_guard: :none,
        media_transcription_config: %{gateway: %{voice: %{deepgram_api_key_secret: ctx.secret}}},
        deepgram_transcription_base_url: "https://api.deepgram.test/v1",
        media_transcription_http_post: ctx.http_post
      )

    result =
      tool.execute.(
        "call-1",
        %{"audioPath" => "a.wav", "provider" => "deepgram_transcribe"},
        nil,
        nil
      )

    assert_no_tripwire(ctx.requests)
    assert {:error, _} = result
  end

  defp arm_tripwires(secret, upper, lower) do
    assert {:ok, _} = Secrets.set(upper, @tripwire)
    assert {:ok, _} = Secrets.set(lower, @tripwire)
    # Written last: secret writes validate every stored row.
    Store.put(Secrets.table(), {"default", secret}, "corrupt")
    # The uppercase env var is explicit top precedence, so it stays unset.
    System.put_env(lower, @tripwire)
  end

  defp assert_no_tripwire(requests) do
    refute inspect(Agent.get(requests, & &1), limit: :infinity, printable_limit: :infinity) =~
             @tripwire
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end

  defp wav_bytes do
    "RIFF" <> <<36::little-32>> <> "WAVEfmt " <> <<16::little-32>> <> "data"
  end
end
