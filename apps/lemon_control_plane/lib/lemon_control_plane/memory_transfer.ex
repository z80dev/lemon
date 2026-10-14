defmodule LemonControlPlane.MemoryTransfer do
  @moduledoc """
  Coordinates a private, profile-owned memory copy without changing placement.

  The controller journals only intent, digests, previews, and receipts. Raw memory
  stays in the owning source snapshot and travels only on targeted node traffic.
  Once apply may have been dispatched, the same mutation only queries the durable
  destination receipt: it never resubmits the mutation after an uncertain result.
  """

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{JSONPayload, NodeRegistry, ProfileStore, Store}
  alias LemonSkills.ProfileMemoryTransfer

  @table :control_memory_transfers
  @timeout_ms 60_000
  @max_payload_bytes 4 * 1_024 * 1_024
  @max_snapshot_bytes 2 * 1_024 * 1_024
  @identity_keys ~w(profileId mutationId sourceNodeId nodeId)
  @receipt_keys @identity_keys ++ ~w(snapshotDigest copied)
  @preview_keys @identity_keys ++
                  ~w(snapshotDigest destinationDigest confirmationToken sourceCounts destinationCounts overwrite)
  @service_errors ~w(invalid_id invalid_params invalid_snapshot profile_mismatch node_mismatch unsafe_snapshot snapshot_too_large stale_source stale_destination destination_conflict confirmation_mismatch transfer_conflict transfer_pending outcome_unknown not_found memory_unavailable)

  @spec execute(map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(params, ctx) do
    with :ok <- validate_params(params) do
      :global.trans({{__MODULE__, journal(ctx), params["mutationId"]}, self()}, fn ->
        case Store.get(journal(ctx), @table, params["mutationId"]) do
          nil -> create(params, ctx)
          operation when is_map(operation) -> resume(operation, params, ctx)
          _ -> error(:memory_unavailable)
        end
      end)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    _ -> uncertain(params)
  catch
    _, _ -> uncertain(params)
  end

  @doc "Inspect only the destination's durable transfer journal; never starts or replays a copy."
  @spec status(map(), map()) :: {:ok, map()} | {:error, term()}
  def status(params, ctx) when is_map(params) do
    params = Map.take(params, ~w(profileId nodeId mutationId))
    with :ok <- validate_params(params),
         operation <- Store.get(journal(ctx), @table, params["mutationId"]),
         :ok <- status_binding(operation, params),
         {:ok, result} <- node_call(params["nodeId"], "inspect", params),
         {:ok, result} <- project_status(operation, params, result) do
      {:ok, result}
    else
      {:error, reason} -> error(reason)
      _ -> status_unavailable(params)
    end
  rescue
    _ -> status_unavailable(params)
  catch
    _, _ -> status_unavailable(params)
  end

  def status(_params, _ctx), do: error(:invalid_params)

  defp status_binding(nil, _params), do: :ok
  defp status_binding(operation, params) when is_map(operation) do
    if operation["profileId"] == params["profileId"] and operation["nodeId"] == params["nodeId"],
      do: :ok, else: {:error, :transfer_conflict}
  end
  defp status_binding(_, _), do: {:error, :memory_unavailable}

  defp project_status(operation, params, result) when is_map(result) do
    source = result["sourceNodeId"]
    snapshot = result["snapshotDigest"]
    status = result["status"]
    receipt = result["receipt"]
    with true <- Map.take(result, ~w(profileId nodeId mutationId)) == params,
         true <- status in ["completed", "pending", "unknown"],
         true <- source == nil or valid_id?(source, 128, ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/),
         true <- snapshot == nil or digest?(snapshot),
         true <- status == "unknown" or (is_binary(source) and is_binary(snapshot)),
         true <- status == "completed" or receipt == nil,
         true <- not is_map(operation) or source == nil or source == operation["sourceNodeId"],
         true <- not is_map(operation) or snapshot == nil or operation["snapshotDigest"] == nil or
                   snapshot == operation["snapshotDigest"],
         :ok <- status_receipt(result, receipt) do
      {:ok, result |> Map.take(~w(profileId nodeId mutationId sourceNodeId snapshotDigest status))
        |> Map.put("receipt", if(is_map(receipt), do: Map.take(receipt, @receipt_keys), else: nil))}
    else
      _ -> {:error, :transfer_conflict}
    end
  end
  defp project_status(_, _, _), do: {:error, :transfer_conflict}

  defp status_receipt(%{"status" => "completed"} = result, receipt),
    do: validate_receipt(result, receipt)
  defp status_receipt(_result, nil), do: :ok
  defp status_receipt(_, _), do: {:error, :transfer_conflict}

  defp status_unavailable(params) do
    {:error, Errors.error(:unavailable, "Memory transfer status is unavailable",
      Map.merge(Map.take(params, ~w(profileId nodeId mutationId)),
        %{"code" => "MEMORY_TRANSFER_STATUS_UNAVAILABLE"}))}
  end

  defp create(params, ctx) do
    with {:ok, profile} <- ProfileStore.get(params["profileId"]),
         {:ok, source_node_id} <- source_node(profile),
         {:ok, _destination} <- destination_node(params["nodeId"]),
         true <- source_node_id != params["nodeId"] do
      operation = %{
        "profileId" => params["profileId"],
        "mutationId" => params["mutationId"],
        "sourceNodeId" => source_node_id,
        "nodeId" => params["nodeId"],
        "state" => "unprepared"
      }

      case Store.put_new(journal(ctx), @table, params["mutationId"], operation) do
        :ok -> prepare(operation, params, ctx)
        {:error, :exists} -> error(:transfer_conflict)
        {:error, _} -> error(:memory_unavailable)
      end
    else
      false -> error(:same_destination)
      {:error, reason} -> error(reason)
    end
  end

  defp resume(operation, params, ctx) do
    cond do
      operation["profileId"] != params["profileId"] or operation["nodeId"] != params["nodeId"] ->
        error(:transfer_conflict)

      expected_digest_conflict?(operation, params) ->
        error(:transfer_conflict)

      operation["state"] == "completed" ->
        {:ok, operation["receipt"]}

      operation["state"] in ["applying", "outcome_unknown"] ->
        reconcile(operation, ctx)

      operation["state"] == "unprepared" ->
        prepare(operation, params, ctx)

      operation["state"] in ["preparing", "source_unknown", "prepared", "previewed"] ->
        case source_call(operation, "snapshot", identity(operation), ctx) do
          {:ok, envelope} -> accept_snapshot(operation, envelope, params, ctx)
          _ -> uncertain(operation)
        end

      operation["state"] == "failed" ->
        error(operation["error"])

      true ->
        uncertain(operation)
    end
  end

  defp prepare(operation, params, ctx) do
    with {:ok, preparing} <- persist(operation, %{"state" => "preparing"}, ctx) do
      case source_call(preparing, "prepare", identity(preparing), ctx) do
        {:ok, envelope} -> accept_snapshot(preparing, envelope, params, ctx)
        {:service_error, reason} when reason in ["transfer_pending", "outcome_unknown"] ->
          _ = persist(preparing, %{"state" => "source_unknown"}, ctx)
          uncertain(preparing)
        {:service_error, reason} -> fail(preparing, reason, ctx)
        {:not_dispatched, _reason} ->
          _ = persist(preparing, %{"state" => "unprepared"}, ctx)
          error(:node_unavailable)
        {:uncertain, _invoke_id} ->
          _ = persist(preparing, %{"state" => "source_unknown"}, ctx)
          uncertain(preparing)
      end
    else
      {:error, _} -> error(:memory_unavailable)
    end
  end

  defp accept_snapshot(operation, envelope, params, ctx) do
    with :ok <- validate_envelope(operation, envelope),
         false <- expected_digest_conflict?(Map.put(operation, "snapshotDigest", envelope["snapshotDigest"]), params),
         {:ok, prepared} <- persist(operation,
           %{"state" => "prepared", "snapshotDigest" => envelope["snapshotDigest"]}, ctx),
         :ok <- current_source(prepared),
         {:ok, %{"valid" => true}} <- source_call(prepared, "validate", envelope, ctx) do
      case Map.get(params, "action", "apply") do
        "preview" -> preview(prepared, envelope, ctx)
        "apply" -> apply_snapshot(prepared, envelope, params, ctx)
      end
    else
      true -> error(:transfer_conflict)
      {:error, reason} -> error(reason)
      {:service_error, reason} -> error(reason)
      _ -> error(:node_unavailable)
    end
  end

  defp preview(operation, envelope, ctx) do
    case node_call(operation["nodeId"], "preview", envelope) do
      {:ok, preview} ->
        with :ok <- validate_preview(operation, preview),
             preview = Map.take(preview, @preview_keys),
             {:ok, _} <- persist(operation, %{"state" => "previewed", "preview" => preview}, ctx) do
          {:ok, preview}
        else
          {:error, reason} -> error(reason)
        end
      {:service_error, reason} when reason in ["transfer_pending", "outcome_unknown"] ->
        _ = persist(operation, %{"state" => "outcome_unknown"}, ctx)
        uncertain(operation)
      {:service_error, reason} -> error(reason)
      _ -> error(:node_unavailable)
    end
  end

  defp apply_snapshot(operation, envelope, params, ctx) do
    envelope = Map.merge(envelope, Map.take(params, ~w(confirmationToken destinationDigest)))

    with {:ok, applying} <- persist(operation, %{"state" => "applying"}, ctx) do
      case node_call(applying["nodeId"], "apply", envelope) do
        {:ok, receipt} -> complete(applying, receipt, ctx)
        {:service_error, reason} when reason in ["transfer_pending", "outcome_unknown"] ->
          _ = persist(applying, %{"state" => "outcome_unknown"}, ctx)
          uncertain(applying)
        {:service_error, reason} ->
          _ = persist(applying, %{"state" => "prepared"}, ctx)
          error(reason)
        {:not_dispatched, _reason} ->
          _ = persist(applying, %{"state" => "prepared"}, ctx)
          error(:node_unavailable)
        {:uncertain, _invoke_id} ->
          _ = persist(applying, %{"state" => "outcome_unknown"}, ctx)
          uncertain(applying)
      end
    else
      {:error, _} -> error(:memory_unavailable)
    end
  end

  defp reconcile(operation, ctx) do
    case node_call(operation["nodeId"], "status", identity(operation)) do
      {:ok, receipt} -> complete(operation, receipt, ctx)
      _ -> uncertain(operation)
    end
  end

  defp complete(operation, receipt, ctx) do
    with :ok <- validate_receipt(operation, receipt),
         {:ok, _} <- persist(operation,
           %{"state" => "completed", "receipt" => Map.take(receipt, @receipt_keys)}, ctx) do
      {:ok, Map.take(receipt, @receipt_keys)}
    else
      _ -> uncertain(operation)
    end
  end

  defp fail(operation, reason, ctx) do
    _ = persist(operation, %{"state" => "failed", "error" => safe_reason(reason)}, ctx)
    error(reason)
  end

  defp persist(operation, update, ctx) do
    next = Map.merge(operation, update)
    case Store.put(journal(ctx), @table, operation["mutationId"], next) do
      :ok -> {:ok, next}
      {:error, _} -> {:error, :memory_unavailable}
    end
  end

  defp source_call(%{"sourceNodeId" => "local"}, operation, args, ctx) do
    opts = Map.get(ctx, :memory_transfer_opts, Map.get(ctx, :memory_opts, []))
    result =
      case operation do
        "prepare" -> ProfileMemoryTransfer.prepare(args["profileId"], args["mutationId"],
          args["sourceNodeId"], args["nodeId"], opts)
        "snapshot" -> ProfileMemoryTransfer.snapshot(args["profileId"], args["mutationId"],
          args["sourceNodeId"], args["nodeId"], opts)
        "validate" ->
          case ProfileMemoryTransfer.validate(args, opts) do
            :ok -> {:ok, %{"valid" => true}}
            {:error, reason} -> {:error, reason}
          end
      end

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:service_error, safe_reason(reason)}
    end
  rescue
    _ -> {:uncertain, nil}
  catch
    _, _ -> {:uncertain, nil}
  end

  defp source_call(operation, method, args, _ctx),
    do: node_call(operation["sourceNodeId"], method, args)

  defp node_call(node_id, operation, args) do
    with {:ok, _node} <- destination_node(node_id),
         {:ok, invoke_id} <- NodeRegistry.invoke_node(node_id, "memory.transfer." <> operation, args,
           recipient: self(), timeout_ms: @timeout_ms, max_payload_bytes: @max_payload_bytes) do
      receive do
        {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true, "payload" => payload}}} ->
          {:ok, payload}
        {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => false, "error" => reason}}} ->
          {:service_error, safe_reason(reason)}
        {:lemon_node_result, ^invoke_id, _result} ->
          {:uncertain, invoke_id}
      after
        @timeout_ms + 1_000 ->
          NodeRegistry.cancel(invoke_id, :timeout)
          {:uncertain, invoke_id}
      end
    else
      {:error, _reason} -> {:not_dispatched, :node_unavailable}
    end
  catch
    _, _ -> {:uncertain, nil}
  end

  defp source_node(profile) do
    case profile["node"] do
      node when node in [nil, "local"] -> {:ok, "local"}
      node when is_binary(node) ->
        case NodeRegistry.resolve(node) do
          {:ok, %{id: id}} -> {:ok, id}
          {:error, _} -> {:error, :node_unavailable}
        end
    end
  end

  defp destination_node(node_id) do
    case NodeRegistry.resolve_id(node_id) do
      {:ok, %{id: ^node_id} = node} -> {:ok, node}
      _ -> {:error, :node_unavailable}
    end
  end

  defp current_source(operation) do
    with {:ok, profile} <- ProfileStore.get(operation["profileId"]),
         {:ok, source} <- source_node(profile),
         true <- source == operation["sourceNodeId"] do
      :ok
    else
      {:error, :node_unavailable} -> {:error, :node_unavailable}
      _ -> {:error, :stale_source}
    end
  end

  defp validate_params(params) when is_map(params) do
    cond do
      not valid_id?(params["profileId"], 64, ~r/\A[a-z0-9][a-z0-9_-]*\z/) -> {:error, :invalid_params}
      not valid_id?(params["mutationId"], 128, ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/) -> {:error, :invalid_params}
      not valid_id?(params["nodeId"], 128, ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/) -> {:error, :invalid_params}
      Map.get(params, "action", "apply") not in ["preview", "apply"] -> {:error, :invalid_params}
      Map.has_key?(params, "confirmationToken") and not bounded_string?(params["confirmationToken"], 512) -> {:error, :invalid_params}
      Map.has_key?(params, "destinationDigest") and not digest?(params["destinationDigest"]) -> {:error, :invalid_params}
      Map.has_key?(params, "snapshotDigest") and not digest?(params["snapshotDigest"]) -> {:error, :invalid_params}
      Map.has_key?(params, "confirmationToken") != Map.has_key?(params, "destinationDigest") -> {:error, :invalid_params}
      true -> :ok
    end
  end

  defp validate_params(_), do: {:error, :invalid_params}

  defp validate_envelope(operation, envelope) when is_map(envelope) do
    with true <- identity_matches?(operation, envelope),
         true <- digest?(envelope["snapshotDigest"]),
         true <- is_map(envelope["snapshot"]),
         true <- is_nil(operation["snapshotDigest"]) or
                   operation["snapshotDigest"] == envelope["snapshotDigest"],
         {:ok, _} <- JSONPayload.validate(envelope["snapshot"], max_bytes: @max_snapshot_bytes) do
      :ok
    else
      _ -> {:error, :transfer_conflict}
    end
  end

  defp validate_envelope(_, _), do: {:error, :transfer_conflict}

  defp validate_receipt(operation, receipt) when is_map(receipt) do
    if identity_matches?(operation, receipt) and receipt["snapshotDigest"] == operation["snapshotDigest"] and
         receipt["copied"] == true,
      do: :ok, else: {:error, :transfer_conflict}
  end

  defp validate_receipt(_, _), do: {:error, :transfer_conflict}

  defp validate_preview(operation, preview) when is_map(preview) do
    if identity_matches?(operation, preview) and preview["snapshotDigest"] == operation["snapshotDigest"] and
         digest?(preview["destinationDigest"]) and bounded_string?(preview["confirmationToken"], 512) and
         is_boolean(preview["overwrite"]) and counts?(preview["sourceCounts"]) and counts?(preview["destinationCounts"]),
      do: :ok, else: {:error, :transfer_conflict}
  end

  defp validate_preview(_, _), do: {:error, :transfer_conflict}
  defp counts?(%{"documents" => docs, "preferences" => preferences} = counts),
    do: map_size(counts) == 2 and is_integer(docs) and docs in 0..500 and
          is_integer(preferences) and preferences in 0..2
  defp counts?(_), do: false
  defp identity(operation), do: Map.take(operation, @identity_keys)
  defp identity_matches?(operation, value), do: identity(operation) == Map.take(value, @identity_keys)
  defp expected_digest_conflict?(operation, params),
    do: is_binary(operation["snapshotDigest"]) and is_binary(params["snapshotDigest"]) and
          operation["snapshotDigest"] != params["snapshotDigest"]
  defp journal(ctx), do: Map.get(ctx, :memory_transfer_journal, Store)
  defp valid_id?(value, max, pattern), do: bounded_string?(value, max) and Regex.match?(pattern, value)
  defp bounded_string?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and not String.contains?(value, <<0>>)
  defp bounded_string?(_, _), do: false
  defp digest?(value), do: valid_id?(value, 64, ~r/\A[a-f0-9]{64}\z/)
  defp safe_reason(reason) when is_atom(reason), do: safe_reason(Atom.to_string(reason))
  defp safe_reason(reason) when reason in @service_errors, do: reason
  defp safe_reason(_), do: "memory_unavailable"

  defp uncertain(operation) when is_map(operation) do
    {:error, Errors.error(:unavailable, "Memory transfer outcome is unknown", %{
      "code" => "MEMORY_TRANSFER_OUTCOME_UNKNOWN", "profileId" => operation["profileId"],
      "nodeId" => operation["nodeId"], "mutationId" => operation["mutationId"], "retrySafe" => false
    })}
  end

  defp uncertain(_), do: error(:memory_unavailable)
  defp error(reason) when is_atom(reason), do: error(Atom.to_string(reason))
  defp error("not_found"), do: {:error, Errors.not_found("Profile or memory transfer not found")}
  defp error(reason) when reason in ["invalid_params", "invalid_id", "invalid_mutation_id", "invalid_snapshot", "unsafe_snapshot", "snapshot_too_large", "same_destination"],
    do: {:error, Errors.invalid_request("Memory transfer parameters or selected memory are invalid")}
  defp error(reason) when reason in ["transfer_conflict", "destination_conflict", "stale_source", "stale_destination", "confirmation_required", "confirmation_mismatch"],
    do: {:error, Errors.error(:conflict, "Memory transfer requires a fresh, exact confirmed preview", %{"code" => String.upcase(reason)})}
  defp error(_), do: {:error, Errors.unavailable("Profile memory transfer is unavailable")}
end
