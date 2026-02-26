defmodule LemonRouter.Router do
  @moduledoc """
  Main router for handling inbound messages and control plane requests.

  The router is responsible for:
  - Normalizing inbound messages from different channels
  - Routing to the appropriate session
  - Handling abort requests
  - Applying pending compaction for all channels (generic path)
  """

  alias LemonCore.RunRequest
  alias LemonCore.SessionKey
  alias LemonRouter.RunOrchestrator

  require Logger

  # Pending compaction markers older than 12 hours are considered stale.
  @pending_compaction_ttl_ms 12 * 60 * 60 * 1000

  @doc """
  Handle an inbound message from a channel.

  Normalizes the message and submits it to the orchestrator.
  Before submission, applies any pending compaction marker for the session
  (unless the channel adapter already handled it, indicated by meta.auto_compacted).
  """
  @spec handle_inbound(LemonCore.InboundMessage.t()) :: :ok
  def handle_inbound(%LemonCore.InboundMessage{} = msg) do
    # Emit inbound telemetry
    emit_inbound_telemetry(msg)

    meta = normalize_meta(msg.meta)
    session_key = resolve_session_key(msg)

    agent_id =
      meta[:agent_id] || meta["agent_id"] || SessionKey.agent_id(session_key) || "default"

    # Apply generic pending-compaction before building the run request.
    # Telegram transport sets auto_compacted=true before reaching here; the guard
    # prevents double-injection.
    {msg, meta} = maybe_apply_pending_compaction(msg, meta, session_key)

    request = build_inbound_run_request(msg, meta, session_key, agent_id)

    # Submit to orchestrator
    case run_orchestrator().submit(request) do
      {:ok, _run_id} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RunOrchestrator.submit failed for inbound (channel_id=#{inspect(msg.channel_id)} account_id=#{inspect(msg.account_id)} peer_id=#{inspect(msg.peer && msg.peer.id)}): " <>
            inspect(reason)
        )

        :ok
    end

    :ok
  end

  @doc false
  def resolve_session_key(%LemonCore.InboundMessage{} = msg) do
    meta = msg.meta || %{}

    candidate =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" ->
          meta[:session_key]

        is_binary(meta["session_key"]) and meta["session_key"] != "" ->
          meta["session_key"]

        true ->
          nil
      end

    if is_binary(candidate) and SessionKey.valid?(candidate) do
      candidate
    else
      SessionKey.channel_peer(%{
        agent_id: meta[:agent_id] || meta["agent_id"] || "default",
        channel_id: msg.channel_id,
        account_id: msg.account_id,
        peer_kind: msg.peer.kind,
        peer_id: msg.peer.id,
        thread_id: msg.peer.thread_id
      })
    end
  end

  defp emit_inbound_telemetry(msg) do
    meta = normalize_meta(msg.meta)

    LemonCore.Telemetry.channel_inbound(msg.channel_id, %{
      account_id: msg.account_id,
      peer_kind: msg.peer.kind,
      agent_id: meta[:agent_id] || meta["agent_id"] || "default"
    })
  rescue
    _ -> :ok
  end

  @doc """
  Handle a control plane agent request.

  Returns the run_id and session_key for tracking.
  """
  @spec handle_control_agent(params :: map(), ctx :: map()) ::
          {:ok, %{run_id: binary(), session_key: binary()}}
          | {:error, %{code: binary(), message: binary(), details: term()}}
  def handle_control_agent(params, ctx) do
    session_key = control_param(params, :session_key)
    agent_id = control_param(params, :agent_id) || "default"
    session_key = session_key || SessionKey.main(agent_id)

    request =
      RunRequest.new(%{
        origin: :control_plane,
        session_key: session_key,
        agent_id: agent_id,
        prompt: control_param(params, :prompt),
        queue_mode: control_param(params, :queue_mode),
        engine_id: control_param(params, :engine_id),
        model: control_param(params, :model),
        cwd: control_param(params, :cwd),
        tool_policy: control_param(params, :tool_policy),
        meta:
          Map.merge(normalize_meta(control_param(params, :meta)), %{
            control_plane_ctx: ctx
          })
      })

    case run_orchestrator().submit(request) do
      {:ok, run_id} ->
        {:ok, %{run_id: run_id, session_key: session_key}}

      {:error, reason} ->
        {:error, %{code: "SUBMIT_FAILED", message: "Failed to submit run", details: reason}}
    end
  end

  @doc """
  Abort all runs for a session.
  """
  @spec abort(session_key :: binary(), reason :: term()) :: :ok
  def abort(session_key, reason \\ :user_requested) do
    # Find active run for session
    LemonRouter.SessionRegistry
    |> Registry.lookup(session_key)
    |> Enum.reduce(MapSet.new(), fn
      {_pid, %{run_id: run_id}}, acc when is_binary(run_id) -> MapSet.put(acc, run_id)
      _, acc -> acc
    end)
    |> Enum.each(&abort_run(&1, reason))

    :ok
  end

  @doc """
  Abort a specific run by ID.
  """
  @spec abort_run(run_id :: binary(), reason :: term()) :: :ok
  def abort_run(run_id, reason \\ :user_requested) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] ->
        LemonRouter.RunProcess.abort(pid, reason)

      _ ->
        # Run not found, might have already completed
        :ok
    end
  end

  @doc """
  Apply a watchdog keepalive decision to a specific run.
  """
  @spec keep_run_alive(run_id :: binary(), decision :: :continue | :cancel) :: :ok
  def keep_run_alive(run_id, decision \\ :continue) when is_binary(run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] ->
        LemonRouter.RunProcess.keep_alive(pid, decision)

      _ ->
        :ok
    end
  end

  defp build_inbound_run_request(msg, meta, session_key, agent_id) do
    RunRequest.new(%{
      origin: :channel,
      session_key: session_key,
      agent_id: agent_id,
      prompt: msg.message.text,
      queue_mode: meta[:queue_mode] || meta["queue_mode"],
      engine_id: meta[:engine_id] || meta["engine_id"],
      meta:
        Map.merge(meta, %{
          channel_id: msg.channel_id,
          account_id: msg.account_id,
          peer: msg.peer,
          sender: msg.sender,
          raw: msg.raw
        })
    })
  end

  defp control_param(params, key) when is_map(params) and is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp run_orchestrator do
    Application.get_env(:lemon_router, :run_orchestrator, RunOrchestrator)
  end

  # ---------------------------------------------------------------------------
  # Generic pending-compaction consumer
  # ---------------------------------------------------------------------------

  @doc false
  def maybe_apply_pending_compaction(msg, meta, session_key) do
    cond do
      # Already compacted by a channel adapter (e.g. Telegram) — skip.
      meta[:auto_compacted] == true or meta["auto_compacted"] == true ->
        # Clear generic marker to avoid a second compaction injection
        # on a subsequent turn after adapter-level compaction.
        if is_binary(session_key), do: LemonCore.Store.delete(:pending_compaction, session_key)

        {msg, meta}

      true ->
        case LemonCore.Store.get(:pending_compaction, session_key) do
          pending when is_map(pending) ->
            if pending_compaction_fresh?(pending) do
              apply_compaction(msg, meta, session_key, pending)
            else
              # Stale marker — delete and proceed without compaction.
              _ = LemonCore.Store.delete(:pending_compaction, session_key)

              Logger.debug(
                "Router cleared stale pending compaction session_key=#{inspect(session_key)}"
              )

              {msg, meta}
            end

          _ ->
            {msg, meta}
        end
    end
  rescue
    _ -> {msg, meta}
  end

  defp apply_compaction(msg, meta, session_key, _pending) do
    transcript =
      LemonCore.Store.get_run_history(session_key, limit: 8)
      |> format_run_history_transcript(max_chars: 8_000)

    if transcript != "" do
      _ = LemonCore.Store.delete(:pending_compaction, session_key)
      text = build_pending_compaction_prompt(transcript, msg.message.text || "")
      meta = Map.put(meta, :auto_compacted, true)

      Logger.warning(
        "Router applying pending compaction session_key=#{inspect(session_key)} " <>
          "transcript_chars=#{byte_size(transcript)}"
      )

      {%{msg | message: Map.put(msg.message, :text, text)}, meta}
    else
      # No transcript to compact with; clear marker so we don't keep
      # re-attempting compaction on every inbound.
      _ = LemonCore.Store.delete(:pending_compaction, session_key)
      {msg, meta}
    end
  rescue
    _ -> {msg, meta}
  end

  defp pending_compaction_fresh?(pending) when is_map(pending) do
    set_at_ms = pending[:set_at_ms] || pending["set_at_ms"]

    cond do
      is_integer(set_at_ms) ->
        System.system_time(:millisecond) - set_at_ms <= @pending_compaction_ttl_ms

      true ->
        true
    end
  rescue
    _ -> false
  end

  defp pending_compaction_fresh?(_), do: false

  @doc false
  def build_pending_compaction_prompt(transcript, user_text)
      when is_binary(transcript) and is_binary(user_text) do
    user_text = String.trim(user_text)

    base =
      [
        "The previous conversation reached the model context limit.",
        "Use this compact transcript as prior context and continue.",
        "",
        "<previous_conversation>",
        transcript,
        "</previous_conversation>"
      ]
      |> Enum.join("\n")

    if user_text == "" do
      String.trim(base <> "\n\nContinue.")
    else
      String.trim(base <> "\n\nUser:\n" <> user_text)
    end
  end

  def build_pending_compaction_prompt(_transcript, user_text), do: user_text

  defp format_run_history_transcript(history, opts) when is_list(history) do
    max_chars = Keyword.get(opts, :max_chars, 12_000)

    text =
      history
      |> Enum.reverse()
      |> Enum.map(&format_run_history_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.trim()

    if String.length(text) > max_chars do
      String.slice(text, String.length(text) - max_chars, max_chars)
    else
      text
    end
  rescue
    _ -> ""
  end

  defp format_run_history_transcript(_other, _opts), do: ""

  defp format_run_history_entry({_run_id, data}) when is_map(data) do
    summary = data[:summary] || data["summary"] || %{}
    prompt = summary[:prompt] || summary["prompt"] || ""
    answer = summary[:answer] || summary["answer"] || ""

    parts =
      []
      |> maybe_append("User: " <> String.trim(prompt), prompt)
      |> maybe_append("Assistant: " <> String.trim(answer), answer)

    Enum.join(parts, "\n")
  end

  defp format_run_history_entry(_), do: ""

  defp maybe_append(parts, text, raw) do
    if is_binary(raw) and String.trim(raw) != "" do
      parts ++ [text]
    else
      parts
    end
  end
end
