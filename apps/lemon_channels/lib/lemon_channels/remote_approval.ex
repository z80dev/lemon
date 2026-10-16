defmodule LemonChannels.RemoteApproval do
  @moduledoc """
  Exact pending-snapshot boundary for remote approval controls.

  Buttons carry the full approval ID and a bounded snapshot fingerprint, never a
  prefix lookup or a policy scope. The authoritative record is fetched again at
  click time and Core atomically compares it before consuming the decision.
  """

  alias LemonChannels.{ApprovalPromptTracker, OutboundPayload, Outbox, Supervision}
  alias LemonCore.Events.ApprovalPending

  def request(payload, channel, account, authorize, opts \\ []) do
    protect(fn ->
      with %{approval_id: id, pending: event_pending} <- payload,
           true <- valid_id?(id),
           {:ok, pending} <- fetch(id, opts),
           true <- snapshot(pending) == snapshot(event_pending),
           {:ok, target} <- target(pending, channel, account, opts),
           true <- authorize.(target) do
        {:ok, pending, target}
      else
        {:error, _} = error -> error
        _ -> {:error, :rejected}
      end
    end)
  end

  def resolve(data, channel, account, authorize, opts \\ []) do
    protect(fn ->
      case parse(data) do
        {:ok, id, fingerprint, decision} ->
          case fetch(id, opts) do
            {:ok, pending} ->
              resolve_pending(
                id,
                fingerprint,
                decision,
                pending,
                channel,
                account,
                authorize,
                opts
              )

            {:error, :not_pending} ->
              expired_target(id, channel, account, authorize, opts)

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end)
  end

  defp resolve_pending(id, fingerprint, decision, pending, channel, account, authorize, opts) do
    with true <- fingerprint == fingerprint(pending),
         {:ok, target} <- target(pending, channel, account, opts),
         true <- authorize.(target),
         {:ok, %{decision: ^decision, outcome: outcome}} when outcome in [:approved, :denied] <-
           Keyword.get(opts, :resolve, &LemonCore.ExecApprovals.resolve/3).(
             id,
             decision,
             expected_pending: pending
           ) do
      {:ok, target, decision}
    else
      {:error, _} = error -> error
      _ -> {:error, :rejected}
    end
  end

  # A terminal record retained by Core for an approval whose owner ended. Never
  # approves anything; it only yields the authorized target so the stale prompt
  # can be edited.
  defp expired_target(id, channel, account, authorize, opts) do
    case Keyword.get(opts, :fetch_record, &LemonCore.ExecApprovalStore.fetch_record/1).(id) do
      {:ok,
       %{
         resolution: %{
           outcome: :expired,
           decision: :expired,
           approval_id: ^id,
           run_id: run,
           session_key: session
         }
       }}
      when is_binary(run) and run != "" and is_binary(session) and session != "" ->
        with {:ok, target} <- target(%{run_id: run, session_key: session}, channel, account, opts),
             true <- authorize.(target) do
          {:error, {:run_ended, target}}
        else
          {:error, _} = error -> error
          _ -> {:error, :rejected}
        end

      _ ->
        {:error, :not_pending}
    end
  end

  @doc "Resolve a chat-scoped text selection through the exact button snapshot boundary."
  def resolve_text(selector, decision, channel, account, authorize, opts \\ [])
      when decision in [:approve_once, :deny] do
    protect(fn ->
      with {:ok, rows} <-
             Keyword.get(opts, :list, &LemonCore.ExecApprovalStore.fetch_pending_list/0).() do
        candidates =
          Enum.filter(rows, fn {_id, pending} ->
            with {:ok, target} <- target(pending, channel, account, opts),
                 true <- authorize.(target) do
              is_nil(pending.expires_at_ms) or pending.expires_at_ms > LemonCore.Clock.now_ms()
            else
              _ -> false
            end
          end)
          |> Enum.sort_by(fn {id, pending} -> {pending.requested_at_ms || 0, id} end, :desc)

        matches =
          cond do
            selector == "" ->
              candidates

            Enum.any?(candidates, fn {id, _} -> id == selector end) ->
              Enum.filter(candidates, fn {id, _} -> id == selector end)

            valid_id?(selector) ->
              Enum.filter(candidates, fn {id, _} -> String.starts_with?(id, selector) end)

            true ->
              []
          end

        case matches do
          [{_, pending}] ->
            case resolve(callback(pending, decision), channel, account, authorize, opts) do
              {:error, {:run_ended, _}} -> {:error, :run_ended}
              result -> result
            end

          [] ->
            if valid_id?(selector) do
              case expired_target(selector, channel, account, authorize, opts) do
                {:error, {:run_ended, _}} -> {:error, :run_ended}
                _ -> {:error, :not_pending}
              end
            else
              {:error, :not_pending}
            end

          many ->
            ids = Enum.map(many, fn {id, _} -> unique_prefix(id, candidates) end)
            {:error, {:ambiguous, ids}}
        end
      end
    end)
  end

  defp unique_prefix(id, candidates) do
    Enum.find_value(min(8, byte_size(id))..byte_size(id), id, fn length ->
      prefix = binary_part(id, 0, length)

      if Enum.count(candidates, fn {other, _} -> String.starts_with?(other, prefix) end) == 1,
        do: prefix
    end)
  end

  def callback(pending, decision) when decision in [:approve_once, :deny] do
    suffix = if decision == :approve_once, do: "once", else: "deny"
    "#{pending.id}|#{fingerprint(pending)}|#{suffix}"
  end

  def parse(data) when is_binary(data) and byte_size(data) <= 64 do
    case String.split(data, "|") do
      [id, fingerprint, decision] when decision in ["once", "deny"] ->
        if valid_id?(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{16}\z/, fingerprint) do
          {:ok, id, fingerprint, if(decision == "once", do: :approve_once, else: :deny)}
        else
          {:error, :invalid_callback}
        end

      _ ->
        {:error, :invalid_callback}
    end
  end

  def parse(_), do: {:error, :invalid_callback}

  def enqueue(target, text, meta, opts \\ []) do
    payload =
      OutboundPayload.text(target.channel_id, target.account_id, target.peer, text,
        meta: meta,
        idempotency_key: opts[:idempotency_key],
        notify_pid: opts[:notify_pid],
        notify_ref: opts[:notify_ref]
      )

    queue(payload, opts)
  end

  @doc """
  Enqueue an approval prompt exactly like `enqueue/4`, registering it with
  `LemonChannels.ApprovalPromptTracker` first so an owner-ended expiry can edit
  the delivered message. `cleared_meta` is the platform edit meta that removes
  the buttons. Tracking is best-effort and never changes the result.
  """
  def prompt(target, approval_id, text, meta, cleared_meta, opts \\ []) do
    case ApprovalPromptTracker.track(approval_id, target, cleared_meta) do
      {:ok, pid, ref} ->
        opts =
          opts
          |> Keyword.put(:notify_pid, pid)
          |> Keyword.put(:notify_ref, ref)

        meta = Map.put(meta, :notify_tag, ApprovalPromptTracker.notify_tag())

        case enqueue(target, text, meta, opts) do
          :ok ->
            :ok

          error ->
            ApprovalPromptTracker.forget(ref)
            error
        end

      :error ->
        enqueue(target, text, meta, opts)
    end
  end

  def edit(target, message_id, decision, meta, opts \\ []) do
    text =
      case decision do
        :approve_once -> "Approval: Approved (once)"
        :expired -> "Approval: Expired (the run ended)"
        _ -> "Approval: Denied"
      end

    payload =
      OutboundPayload.edit(
        target.channel_id,
        target.account_id,
        target.peer,
        to_string(message_id),
        text,
        meta: meta
      )

    queue(payload, opts)
  end

  def integer(id) when is_integer(id), do: id

  def integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> if Integer.to_string(value) == id, do: value
      _ -> nil
    end
  end

  def integer(_), do: nil

  def action_text(action) when is_map(action) do
    Enum.find_value([:command, "command", :cmd, "cmd"], fn key ->
      value = Map.get(action, key)
      if is_binary(value), do: value
    end) || inspect(action)
  end

  def action_text(action), do: inspect(action)

  defp fetch(id, opts) do
    case Keyword.get(opts, :fetch, &LemonCore.ExecApprovalStore.fetch_pending/1).(id) do
      {:ok, %{id: ^id, session_key: session, run_id: run} = pending}
      when is_binary(session) and session != "" and is_binary(run) and run != "" ->
        case Map.get(pending, :expires_at_ms) do
          nil ->
            {:ok, pending}

          expiry when is_integer(expiry) ->
            if expiry > LemonCore.Clock.now_ms(), do: {:ok, pending}, else: {:error, :expired}

          _ ->
            {:error, :invalid_pending}
        end

      {:ok, nil} ->
        {:error, :not_pending}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_pending}
    end
  end

  defp target(pending, channel, account, opts) do
    lookup = Keyword.get(opts, :target, &Supervision.target_for_run/2)

    case lookup.(pending.run_id, pending.session_key) do
      {:ok, %{channel_id: ^channel, account_id: ^account, peer: peer} = target}
      when is_binary(account) and account != "" ->
        if valid_peer?(peer), do: {:ok, target}, else: {:error, :invalid_target}

      {:error, _} = error ->
        error

      _ ->
        {:error, :wrong_target}
    end
  end

  defp valid_peer?(%{kind: kind, id: id, thread_id: thread}) do
    kind in [:dm, :group, :channel] and is_binary(id) and is_integer(integer(id)) and
      (is_nil(thread) or
         (is_binary(thread) and is_integer(integer(thread)) and integer(thread) > 0))
  end

  defp valid_peer?(_), do: false

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,42}\z/, id)
  defp snapshot(pending) when is_map(pending), do: ApprovalPending.new(pending)
  defp snapshot(_), do: nil

  defp fingerprint(pending) do
    :crypto.hash(:sha256, :erlang.term_to_binary(snapshot(pending)))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  defp queue(payload, opts) do
    protect(fn ->
      case Keyword.get(opts, :enqueue, &Outbox.enqueue/1).(payload) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
        _ -> {:error, :outbox_unavailable}
      end
    end)
  end

  defp protect(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
