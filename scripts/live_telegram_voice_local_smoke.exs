Application.ensure_all_started(:lemon_core)
Application.ensure_all_started(:lemon_channels)

defmodule LemonScripts.LiveTelegramVoiceLocalSmoke.Router do
  def submit(%LemonCore.RunRequest{} = request) do
    if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
      send(pid, {:telegram_voice_local_run, request})
    end

    {:ok, "telegram_voice_local_#{System.unique_integer([:positive])}"}
  end

  def handle_inbound(%LemonCore.InboundMessage{} = inbound) do
    if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
      send(pid, {:telegram_voice_local_inbound, inbound})
    end

    :ok
  end
end

defmodule LemonScripts.LiveTelegramVoiceLocalSmoke.API do
  @updates_key {__MODULE__, :updates}

  def set_updates(updates), do: :persistent_term.put(@updates_key, updates)

  def get_updates(_token, _offset, _timeout_ms) do
    updates = :persistent_term.get(@updates_key, [])

    case updates do
      [first | rest] ->
        :persistent_term.put(@updates_key, rest)
        {:ok, %{"ok" => true, "result" => [first]}}

      [] ->
        {:ok, %{"ok" => true, "result" => []}}
    end
  end

  def get_file(_token, _file_id) do
    {:ok, %{"ok" => true, "result" => %{"file_path" => "voice-local-proof.ogg"}}}
  end

  def download_file(_token, _file_path), do: {:ok, "AUDIO"}

  def send_message(_token, _chat_id, _text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
    {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
  end

  def edit_message_text(_token, _chat_id, _message_id, _text, _parse_mode_or_opts \\ nil) do
    {:ok, %{"ok" => true}}
  end

  def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
  def answer_callback_query(_token, _cb_id, _opts \\ %{}), do: {:ok, %{"ok" => true}}
end

defmodule LemonScripts.LiveTelegramVoiceLocalSmoke do
  @proof_object "lemon.telegram_voice_local_smoke"
  @proof_scope "telegram_voice_local_transcript"

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    out =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "telegram-voice-local-latest.json"])

    proof = run()

    write_json!(out, proof)
    write_json!(archive_path(out), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run do
    token = unique_token()

    with {:ok, request} <- run_transport(token),
         {:ok, checks} <- validate_request(request, token) do
      proof(:completed, checks)
    else
      {:error, reason, checks} -> proof(:failed, checks, reason)
      {:error, reason} -> proof(:failed, [], reason)
    end
  end

  defp run_transport(token) do
    previous_router = Application.get_env(:lemon_core, :router_bridge)

    try do
      :persistent_term.put({LemonScripts.LiveTelegramVoiceLocalSmoke.Router, :notify_pid}, self())

      LemonCore.RouterBridge.configure(
        router: LemonScripts.LiveTelegramVoiceLocalSmoke.Router,
        run_orchestrator: LemonScripts.LiveTelegramVoiceLocalSmoke.Router
      )

      LemonScripts.LiveTelegramVoiceLocalSmoke.API.set_updates([voice_update(token)])

      {:ok, pid} =
        LemonChannels.Adapters.Telegram.Transport.start_link(
          config: %{
            bot_token: "telegram-local-voice-proof-token",
            bot_id: 1000 + token,
            bot_username: "lemon_voice_local_proof_bot",
            api_mod: LemonScripts.LiveTelegramVoiceLocalSmoke.API,
            poll_interval_ms: 10,
            debounce_ms: 10,
            voice_transcription: true,
            voice_transcription_provider: "local_transcript",
            voice_max_bytes: 10_000,
            authorized_chat_ids: [123_000 + token]
          }
        )

      receive do
        {:telegram_voice_local_run, request} ->
          cleanup(pid, previous_router)
          {:ok, request}
      after
        2_000 ->
          cleanup(pid, previous_router)
          {:error, "timed out waiting for local voice transcript routing"}
      end
    rescue
      exception ->
        cleanup(nil, previous_router)
        {:error, Exception.message(exception)}
    end
  end

  defp validate_request(%LemonCore.RunRequest{} = request, token) do
    checks = [
      check(
        "telegram_voice_local_transcript_provider",
        request.prompt =~ "local voice transcript preview",
        %{
          provider: "local_transcript",
          prompt_hash: short_hash(request.prompt),
          prompt_chars: String.length(request.prompt || "")
        },
        "missing local transcript preview"
      ),
      check(
        "telegram_voice_local_no_api_key",
        request.prompt =~ "5 bytes audio/ogg",
        %{audio_bytes: 5, mime_type: "audio/ogg"},
        "local transcript did not include deterministic audio shape"
      ),
      check(
        "telegram_voice_local_inbound_metadata",
        voice_meta?(request, token),
        %{
          channel_id: safe_string(request.meta[:channel_id]),
          peer_kind: safe_atom(get_in(request.meta, [:peer, :kind])),
          chat_id_hash: short_hash(get_in(request.meta, [:raw, "message", "chat", "id"])),
          sender_id_hash: short_hash(get_in(request.meta, [:sender, :id])),
          voice_transcribed: request.meta[:voice_transcribed] == true
        },
        "voice metadata was not preserved"
      )
    ]

    if Enum.all?(checks, &(&1.status == "completed")) do
      {:ok, checks}
    else
      {:error, "one or more Telegram local voice checks failed", checks}
    end
  end

  defp validate_request(_request, _token), do: {:error, "router did not receive a RunRequest"}

  defp voice_meta?(request, token) do
    request.meta[:voice_transcribed] == true and
      request.meta[:channel_id] == "telegram" and
      get_in(request.meta, [:peer, :kind]) == :dm and
      get_in(request.meta, [:raw, "message", "chat", "id"]) == 123_000 + token
  end

  defp check(name, true, details, _failure_hint) do
    Map.merge(
      %{
        name: name,
        status: "completed",
        proof_scope: @proof_scope
      },
      details
    )
  end

  defp check(name, false, details, failure_hint) do
    Map.merge(
      %{
        name: name,
        status: "failed",
        proof_scope: @proof_scope,
        reason_kind: "telegram_voice_local_proof_failed",
        failure_hint_hash: short_hash(failure_hint)
      },
      details
    )
  end

  defp proof(:completed, checks) do
    %{
      proof_object: @proof_object,
      proof_scope: @proof_scope,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      completed_count: length(checks),
      failed_count: 0,
      skipped_count: 0,
      checks: checks,
      coverage: %{
        check_count: length(checks)
      },
      cleanup: cleanup_flags()
    }
  end

  defp proof(:failed, checks, reason) do
    completed = Enum.count(checks, &(&1.status == "completed"))
    failed = max(1, Enum.count(checks, &(&1.status == "failed")))

    %{
      proof_object: @proof_object,
      proof_scope: @proof_scope,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      completed_count: completed,
      failed_count: failed,
      skipped_count: 0,
      checks: checks,
      reason_kind: "telegram_voice_local_proof_failed",
      details: %{
        reason_hash: short_hash(reason)
      },
      cleanup: cleanup_flags()
    }
  end

  defp cleanup_flags do
    %{
      includes_raw_bot_token: false,
      includes_raw_chat_ids: false,
      includes_raw_sender_ids: false,
      includes_raw_audio_bytes: false,
      includes_raw_transcript: false,
      includes_raw_message_body: false
    }
  end

  defp voice_update(token) do
    %{
      "update_id" => token,
      "message" => %{
        "message_id" => 11,
        "date" => 1,
        "chat" => %{"id" => 123_000 + token, "type" => "private"},
        "from" => %{"id" => 999_000 + token, "username" => "voice_proof"},
        "voice" => %{
          "file_id" => "voice-local-proof",
          "mime_type" => "audio/ogg",
          "file_size" => 120,
          "duration" => 1
        }
      }
    }
  end

  defp cleanup(pid, previous_router) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal)

    if is_map(previous_router) do
      Application.put_env(:lemon_core, :router_bridge, previous_router)
    else
      Application.delete_env(:lemon_core, :router_bridge)
    end

    :persistent_term.erase({LemonScripts.LiveTelegramVoiceLocalSmoke.Router, :notify_pid})
    :persistent_term.erase({LemonScripts.LiveTelegramVoiceLocalSmoke.API, :updates})
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

  defp unique_token, do: System.unique_integer([:positive])

  defp short_hash(value) do
    :crypto.hash(:sha256, inspect(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(_value), do: nil

  defp safe_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_atom(_value), do: nil
end

LemonScripts.LiveTelegramVoiceLocalSmoke.main(System.argv())
