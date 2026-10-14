defmodule LemonRouter.NativeLineage do
  @moduledoc """
  Controller-owned provenance for factory-attested native executions.

  Continuing handles exist only in private execution metadata. Durable admission
  rows contain their SHA-256 hash, original actor/audience and effective policy,
  never a handle or MCP authentication headers.
  Fresh reservations are fixed-ID, content-free and synced before issuer I/O.
  An interrupted reservation is not retryable.

  Profile `node` placement is a durable-ID or unique-live-name selector. Admission
  resolves it once via `LemonCore.NodeRegistry` (exact ID first) and seals the actual
  durable ID, connection PID and session generation; execution metadata carries the
  durable ID. Later checks re-resolve the same selector and fail closed on any
  change, never falling back to local.
  """

  alias LemonCore.{InvocationProof, MapHelpers, NodeRegistry, ProfileStore, RunRequest, Store}
  alias LemonRouter.Submission

  @table :router_run_admissions
  @binding_fields ~w(native_root_binding nativeRootBinding target_profile_config_hash targetProfileConfigHash target_policy_hash targetPolicyHash destination_binding_hash destinationBindingHash)
  @private_fields ~w(invocation_context_key invocationContextKey memory_context_key memoryContextKey memory_context_verified memoryContextVerified shared_memory_grant sharedMemoryGrant invocation_proof invocationProof invocation_proof_verified invocationProofVerified native_lineage_handle nativeLineageHandle native_lineage_run_id nativeLineageRunId native_source nativeSource native_followup nativeFollowup mcp_servers mcpServers parent_run_id parentRunId profile_id profileId node native_destination_pid nativeDestinationPid native_destination_generation nativeDestinationGeneration) ++
                    @binding_fields
  @owner_fields ~w(native_lineage_handle nativeLineageHandle native_lineage_run_id nativeLineageRunId native_source nativeSource native_followup nativeFollowup native_destination_pid nativeDestinationPid native_destination_generation nativeDestinationGeneration) ++
                  @binding_fields

  @doc false
  def capture_submission(%Submission{execution_request: command} = submission) do
    meta = command.meta || %{}

    if Map.get(meta, :invocation_proof_verified) == true do
      with true <- Map.get(meta, :memory_context_verified) == true,
           :ok <- RunRequest.validate_invocation_context_key(meta[:invocation_context_key]),
           :ok <- RunRequest.validate_invocation_context_key(meta[:memory_context_key]),
           {:ok, _proof} <-
             InvocationProof.validate(
               descriptor(meta[:invocation_proof]),
               command.run_id,
               meta[:mcp_servers]
             ),
           {:ok, native_policy} <- LemonCore.ToolPolicy.normalize(command.tool_policy || %{}),
           {:ok, profile, binding} <- capture_target_binding(command),
           {:ok, _} <- validate_command_invocation(command, profile),
           :ok <- validate_current_target_policy(command),
           true <- profile["id"] == meta[:agent_id],
           {:ok, destination} <- profile_destination(profile),
           true <- selected_destination?(meta[:node], profile, destination),
           true <-
             destination.pid == nil or meta[:native_destination_pid] in [nil, destination.pid],
           true <-
             destination.generation == nil or
               meta[:native_destination_generation] in [nil, destination.generation],
           {:ok, %{} = admission} <- Store.fetch(@table, command.run_id),
           :ok <- current_admission_binding(admission),
           false <- Map.has_key?(admission, :native_source) do
        handle = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        pending = Map.get(admission, :native_followup, %{})

        source = %{
          run_id: command.run_id,
          root_run_id: Map.get(pending, :source_root_run_id, command.run_id),
          profile_id: Map.get(pending, :source_profile_id, profile["id"]),
          session_key: Map.get(pending, :source_session_key, command.session_key),
          execution_profile_id: profile["id"],
          execution_session_key: command.session_key,
          agent_id: meta[:agent_id],
          node_id: destination.node_id,
          node_generation: destination.generation,
          invocation_context_key:
            Map.get(pending, :source_invocation_context_key, meta[:invocation_context_key]),
          memory_context_key:
            Map.get(pending, :source_memory_context_key, meta[:memory_context_key]),
          execution_invocation_context_key: meta[:invocation_context_key],
          execution_memory_context_key: meta[:memory_context_key],
          tool_policy: LemonCore.ToolPolicy.expand(native_policy),
          native_floor_verified: false,
          handle_hash: digest(handle)
        }

        scope =
          Map.get(admission, :scope, %{})
          |> Map.put(
            :dependent_profile_ids,
            Enum.uniq([source.profile_id, source.execution_profile_id])
          )

        replacement =
          admission
          |> Map.put(:native_source, source)
          |> Map.put(:scope, scope)
          |> maybe_bind_root(command, destination, binding, true)

        with :ok <- Store.compare_and_swap(@table, command.run_id, admission, replacement),
             :ok <- Store.sync() do
          private_meta =
            meta
            |> Map.reject(fn {key, _} -> to_string(key) in @owner_fields end)
            |> Map.put(:native_lineage_handle, handle)
            |> Map.put(:native_lineage_run_id, command.run_id)
            |> Map.put(:native_destination_pid, destination.pid)
            |> Map.put(:native_destination_generation, destination.generation)
            |> put_destination_node(destination)

          {:ok,
           %{
             submission
             | execution_request: %{command | meta: private_meta},
               meta: LemonCore.RunStore.execution_projection(private_meta)
           }}
        else
          _ -> {:error, :outcome_unknown}
        end
      else
        {:error, :admission_unavailable} -> {:error, :admission_unavailable}
        _ -> {:error, :invalid_native_lineage}
      end
    else
      # Body/model metadata is not continuing authority. Only this factory
      # stamps these fields after sealing actual execution provenance.
      with {:ok, destination} <- capture_unattested_managed(command) do
        clean_meta =
          meta
          |> Map.reject(fn {key, _} -> to_string(key) in @owner_fields end)
          |> put_destination_node(destination)

        {:ok,
         %{
           submission
           | execution_request: %{command | meta: clean_meta},
             meta: LemonCore.RunStore.execution_projection(clean_meta)
         }}
      end
    end
  end

  @doc false
  def dependent_profile_ids(admission) do
    source = MapHelpers.get_key(admission, :native_source) || %{}
    pending = MapHelpers.get_key(admission, :native_followup) || %{}

    [
      MapHelpers.get_key(source, :profile_id),
      MapHelpers.get_key(source, :execution_profile_id),
      MapHelpers.get_key(pending, :source_profile_id),
      MapHelpers.get_key(pending, :target_profile_id)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc false
  def authenticate(%{run_id: run_id, lineage_handle: handle}, transport)
      when is_binary(run_id) and is_binary(handle) and byte_size(handle) == 43 do
    with {:ok, %{native_source: source}} <- Store.fetch(@table, run_id),
         true <- source.run_id == run_id and source.handle_hash == digest(handle),
         :ok <- source_transport(source, transport) do
      {:ok, source}
    else
      _ -> {:error, :invalid_native_lineage}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_native_lineage}

  @doc """
  Seal the executing host's actual native startup policy before native tools or
  model execution begin. Callers must capture the policy from immutable native
  startup options, not a request body's policy or model metadata.

  Continuing executions bind receipts with their handle and authenticated source
  session. A proofless managed root uses exactly `%{run_id: actual_run_id}` and
  its authenticated destination, sealing only a private startup floor without
  creating any continuing authority. Repeated receipts may only restrict floors.
  """
  def register_source_floor(captured, actual_policy, transport) do
    with {:ok, floor} <- LemonCore.ToolPolicy.normalize(actual_policy) do
      if proofless_capture?(captured) do
        persist_proofless_floor(captured.run_id, floor, transport, 3)
      else
        persist_source_floor(captured, floor, transport, 3)
      end
    else
      _ -> {:error, :invalid_native_policy}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp proofless_capture?(captured) do
    is_map(captured) and not is_struct(captured) and Map.keys(captured) == [:run_id]
  end

  defp persist_proofless_floor(run_id, floor, transport, attempts_left) do
    with :ok <- RunRequest.validate_invocation_context_key(run_id),
         {:ok, %{native_root_binding: %{invocation_proof_required: false} = binding} = entry} <-
           Store.fetch(@table, run_id),
         false <- Map.has_key?(entry, :native_source),
         {:ok, destination} <- destination(binding.target_node_id),
         true <- digest(destination) == binding.destination_binding_hash,
         :ok <-
           source_transport(
             %{node_id: destination.node_id, node_generation: destination.generation},
             transport
           ),
         :ok <- verify_startup_binding(entry, run_id) do
      actual_floor =
        LemonCore.ToolPolicy.intersect(
          Map.get(binding, :native_startup_tool_policy, binding.admitted_tool_policy),
          floor
        )

      sealed =
        binding
        |> Map.put(:native_startup_tool_policy, actual_floor)
        |> Map.put(:native_floor_verified, true)

      case Store.compare_and_swap(
             @table,
             run_id,
             entry,
             Map.put(entry, :native_root_binding, sealed)
           ) do
        :ok ->
          case Store.sync() do
            :ok -> :ok
            _ -> {:error, :outcome_unknown}
          end

        {:error, :mismatch} when attempts_left > 0 ->
          persist_proofless_floor(run_id, floor, transport, attempts_left - 1)

        _ ->
          {:error, :outcome_unknown}
      end
    else
      {:error, :admission_unavailable} = error -> error
      {:error, :outcome_unknown} = error -> error
      {:error, :store_unavailable} -> {:error, :outcome_unknown}
      _ -> {:error, :invalid_native_lineage}
    end
  end

  defp persist_source_floor(captured, floor, transport, attempts_left) do
    with {:ok, source} <- authenticate(captured, transport),
         {:ok, %{native_source: ^source} = entry} <- Store.fetch(@table, source.run_id),
         :ok <- verify_startup_binding(entry, source.run_id) do
      sealed =
        source
        |> Map.put(:tool_policy, LemonCore.ToolPolicy.intersect(source.tool_policy, floor))
        |> Map.put(:native_floor_verified, true)

      replacement = Map.put(entry, :native_source, sealed)

      case Store.compare_and_swap(@table, source.run_id, entry, replacement) do
        :ok ->
          case Store.sync() do
            :ok -> :ok
            _ -> {:error, :outcome_unknown}
          end

        {:error, :mismatch} when attempts_left > 0 ->
          persist_source_floor(captured, floor, transport, attempts_left - 1)

        _ ->
          {:error, :outcome_unknown}
      end
    else
      {:error, :invalid_native_lineage} = error ->
        error

      {:error, :admission_unavailable} = error ->
        error

      {:ok, %{native_source: _}} when attempts_left > 0 ->
        persist_source_floor(captured, floor, transport, attempts_left - 1)

      _ ->
        {:error, :outcome_unknown}
    end
  end

  @doc false
  def current_source(source) do
    case source_transport(source, source.authenticated_transport) do
      :ok -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  defp source_transport(%{node_id: "local"}, :local), do: :ok

  defp source_transport(
         %{node_id: id, node_generation: generation},
         %{node_id: id, connection_pid: pid, generation: generation}
       ) do
    with {:ok, %{id: ^id, pid: ^pid, generation: ^generation, metadata: metadata}} <-
           NodeRegistry.resolve_id(id),
         true <- NodeRegistry.native_privacy_context_supported?(metadata) do
      :ok
    else
      _ -> {:error, :stale_source_node}
    end
  end

  defp source_transport(_, _), do: {:error, :invalid_source_node}

  @doc false
  def prepare_request(source, %RunRequest{} = request) do
    target_id = request.agent_id || source.execution_profile_id

    with :ok <- RunRequest.validate_invocation_context_key(request.run_id),
         true <- request.run_id != source.run_id,
         true <- Map.get(source, :native_floor_verified) == true,
         {:ok, requested_policy} <- LemonCore.ToolPolicy.normalize(request.tool_policy || %{}),
         {:ok, profile} <- ProfileStore.get(target_id),
         true <- profile["id"] == target_id,
         {:ok, destination} <- profile_destination(profile),
         {:ok, prepared} <-
           ProfileStore.chat_request(profile, request.prompt,
             run_id: request.run_id,
             session_key: request.session_key || source.session_key,
             origin: :node,
             images: request.images || [],
             queue_mode: :collect,
             model: request.model,
             cwd: request.cwd,
             resume: request.resume,
             meta: strip_private(request.meta || %{}),
             tool_policy: requested_policy
           ) do
      # Pin an exact durable ID, never a mutable node name.
      # An attested F is a fresh execution, never a steer or merged follower
      # running with another execution's proof. Collect queues F independently.
      meta =
        prepared.meta
        |> Map.put(:node, destination.node_id)
        |> Map.put(:native_destination_pid, destination.pid)
        |> Map.put(:native_destination_generation, destination.generation)
        |> Map.put(:parent_run_id, source.run_id)

      {:ok, %{prepared | meta: meta}, destination}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  @doc false
  def destination(node) when node in [nil, "local", :local] do
    {:ok, %{node_id: "local", pid: nil, generation: nil}}
  end

  def destination(id) when is_binary(id) do
    with {:ok, %{id: ^id, pid: pid, generation: generation, metadata: metadata}} <-
           NodeRegistry.resolve_id(id),
         true <- NodeRegistry.native_privacy_context_supported?(metadata) do
      {:ok, %{node_id: id, pid: pid, generation: generation}}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  def destination(_), do: {:error, :admission_unavailable}

  @doc false
  # Profile placement is the public `local`/durable-ID/unique-live-name selector.
  # Resolve it through the registry owner (exact ID first) and bind the actual
  # durable ID, connection PID and session generation of a privacy-capable node.
  def profile_destination(profile) when is_map(profile) do
    case profile["node"] do
      selector when selector in [nil, "local"] ->
        destination(selector)

      selector when is_binary(selector) ->
        with {:ok, %{id: id, pid: pid, generation: generation, metadata: metadata}} <-
               NodeRegistry.resolve(selector),
             true <- NodeRegistry.native_privacy_context_supported?(metadata) do
          {:ok, %{node_id: id, pid: pid, generation: generation}}
        else
          _ -> {:error, :admission_unavailable}
        end

      _ ->
        {:error, :admission_unavailable}
    end
  end

  def profile_destination(_), do: {:error, :admission_unavailable}

  @doc false
  def current_destination(%{node_id: id} = expected) do
    case destination(id) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  @doc false
  def current_target(request, destination) do
    with {:ok, profile} <- ProfileStore.get(request.meta[:profile_id]),
         true <- profile["id"] == request.agent_id,
         {:ok, current} <- profile_destination(profile),
         true <- current == destination,
         :ok <- current_destination(destination) do
      :ok
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  @doc false
  def reserve(source, request, identity, destination) do
    with {:ok, binding} <- target_binding(request) do
      reserve_bound(source, request, identity, destination, binding)
    end
  end

  defp reserve_bound(source, request, identity, destination, binding) do
    lineage = %{
      run_id: request.run_id,
      source_root_run_id: source.root_run_id,
      parent_run_id: source.run_id,
      source_profile_id: source.profile_id,
      source_session_key: source.session_key,
      source_invocation_context_key: source.invocation_context_key,
      source_memory_context_key: source.memory_context_key,
      target_profile_id: request.meta[:profile_id],
      target_agent_id: request.agent_id,
      target_session_key: request.session_key,
      target_node_id: destination.node_id,
      source_restrictive_tool_policy: source.tool_policy,
      destination_binding_hash: digest(destination),
      target_profile_config_hash: binding.target_profile_config_hash,
      target_policy_hash: binding.target_policy_hash,
      status: :callback_pending
    }

    entry = %{
      state: "native_reserved",
      identity: identity,
      native_followup: lineage,
      scope: %{
        profile_id: request.meta[:profile_id],
        agent_id: request.agent_id,
        session_key: request.session_key,
        dependent_profile_ids: Enum.uniq([source.profile_id, request.meta[:profile_id]])
      }
    }

    case Store.put_new(@table, request.run_id, entry) do
      :ok ->
        case Store.sync() do
          :ok -> {:ok, entry, :new}
          _ -> {:error, :outcome_unknown}
        end

      {:error, :exists} ->
        case Store.fetch(@table, request.run_id) do
          {:ok, %{identity: ^identity, native_followup: _} = existing} ->
            {:ok, existing, :existing}

          {:ok, %{}} ->
            {:error, :run_id_conflict}

          _ ->
            {:error, :outcome_unknown}
        end

      _ ->
        {:error, :outcome_unknown}
    end
  end

  @doc "Read the content-free lineage of an actually reserved fresh run."
  def get_pending_lineage(run_id) when is_binary(run_id) and run_id != "" do
    case Store.fetch(@table, run_id) do
      {:ok, %{native_followup: %{status: :callback_pending} = lineage}} ->
        fields = [
          run_id: "runId",
          source_root_run_id: "sourceRootRunId",
          parent_run_id: "parentRunId",
          source_profile_id: "sourceProfileId",
          source_session_key: "sourceSessionKey",
          source_invocation_context_key: "sourceInvocationContextKey",
          source_memory_context_key: "sourceMemoryContextKey",
          target_profile_id: "targetProfileId",
          target_agent_id: "targetAgentId",
          target_session_key: "targetSessionKey",
          target_node_id: "targetNodeId",
          source_restrictive_tool_policy: "sourceRestrictiveToolPolicy"
        ]

        {:ok, Map.new(fields, fn {key, wire} -> {wire, Map.fetch!(lineage, key)} end)}

      {:ok, nil} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  end

  def get_pending_lineage(_), do: {:error, :not_found}

  @doc """
  Validate a reserved issuer secret's exact current destination. The secret
  operation must use the returned PID as its invocation broker's expected PID.
  Neither the sealed connection hash nor its PID is a management projection.

  `:not_found` proves strict durable absence and is the only result permitting
  initial-root provisioning. An existing nonpending row is `:not_pending`;
  changed placement/connection is `:destination_mismatch`. Query failures are
  `:unavailable`, never absence.
  """
  def pending_destination(run_id, node_id) do
    if RunRequest.validate_invocation_context_key(run_id) == :ok do
      case Store.fetch(@table, run_id) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, %{native_followup: %{status: :callback_pending} = lineage}} ->
          validate_reserved_destination(lineage, node_id)

        {:ok, _} ->
          {:error, :not_pending}

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid_run_id}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp validate_reserved_destination(lineage, node_id) do
    with true <- lineage.target_node_id == node_id,
         {:ok, profile} <- ProfileStore.get(lineage.target_profile_id),
         {:ok, destination} <- profile_destination(profile),
         true <- destination.node_id == node_id,
         true <- digest(destination) == lineage.destination_binding_hash,
         {:ok, _config} <- current_target_binding(lineage) do
      {:ok, destination}
    else
      {:error, :outcome_unknown} -> {:error, :unavailable}
      _ -> {:error, :destination_mismatch}
    end
  end

  @doc false
  def admit(source, request, entry) do
    with {:ok, _target_config} <- current_target_binding(entry.native_followup),
         {:ok, config} <- LemonRouter.NativeFollowupAdmission.fetch_config(source.profile_id),
         {:ok, invocation} <-
           LemonRouter.NativeFollowupAdmission.check(config, entry.native_followup),
         {:ok, target_config} <- current_target_binding(entry.native_followup),
         {:ok, admitted} <- apply_invocation(source, request, invocation, target_config) do
      {:ok, admitted}
    else
      {:error, :denied} -> {:error, :denied}
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      _ -> {:error, :admission_unavailable}
    end
  end

  @doc false
  def apply_invocation(source, request, invocation) do
    with {:ok, profile, _version} <-
           LemonRouter.NativeFollowupAdmission.capture_target(request.meta[:profile_id]) do
      apply_invocation(source, request, invocation, profile)
    end
  end

  defp apply_invocation(source, request, invocation, target_config) when is_map(invocation) do
    with {:ok, invocation} <-
           LemonRouter.NativeFollowupAdmission.validate_invocation(
             invocation,
             request.run_id,
             target_config
           ),
         {:ok, policy} <- LemonCore.ToolPolicy.normalize(invocation["invocationToolPolicy"]),
         {:ok, target_policy} <-
           LemonRouter.SubmissionBuilder.current_native_target_policy(
             request.meta[:profile_id],
             request.session_key,
             %{}
           ),
         {:ok, proof} <-
           InvocationProof.validate(
             invocation["invocationProof"],
             request.run_id,
             invocation["invocationMcpServers"]
           ) do
      meta =
        request.meta
        |> Map.put(:invocation_context_key, invocation["invocationContextKey"])
        |> Map.put(:memory_context_key, invocation["memoryContextKey"])
        |> Map.put(:memory_context_verified, true)
        |> Map.put(:shared_memory_grant, false)
        |> Map.put(:invocation_proof, proof)
        |> Map.put(:invocation_proof_verified, true)
        |> Map.put(:mcp_servers, invocation["invocationMcpServers"])

      {:ok,
       %{
         request
         | meta: meta,
           tool_policy:
             LemonCore.ToolPolicy.intersect(
               source.tool_policy,
               LemonCore.ToolPolicy.intersect(
                 target_policy,
                 LemonCore.ToolPolicy.intersect(request.tool_policy, policy)
               )
             )
       }}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp apply_invocation(_, _, _, _), do: {:error, :admission_unavailable}

  defp target_binding(request) do
    with {:ok, profile, binding} <- capture_target_binding(request),
         true <- profile["mcpServers"] != [] do
      {:ok, binding}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp capture_target_binding(request) do
    with {:ok, profile, version} <-
           LemonRouter.NativeFollowupAdmission.capture_target(request.meta[:profile_id]),
         {:ok, policy} <-
           LemonRouter.SubmissionBuilder.current_native_target_policy(
             request.meta[:profile_id],
             request.session_key,
             %{}
           ) do
      {:ok, profile, %{target_profile_config_hash: version, target_policy_hash: digest(policy)}}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp current_target_binding(lineage) do
    with {:ok, profile, version} <-
           LemonRouter.NativeFollowupAdmission.capture_target(lineage.target_profile_id),
         true <- version == Map.get(lineage, :target_profile_config_hash),
         true <-
           profile["mcpServers"] != [] or Map.get(lineage, :invocation_proof_required) == false,
         {:ok, policy} <-
           LemonRouter.SubmissionBuilder.current_native_target_policy(
             lineage.target_profile_id,
             lineage.target_session_key,
             %{}
           ),
         true <- digest(policy) == Map.get(lineage, :target_policy_hash) do
      {:ok, profile}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp maybe_bind_root(entry, command, destination, binding, proof_required) do
    if Map.has_key?(entry, :native_followup) do
      entry
    else
      root_binding =
        Map.merge(binding, %{
          target_profile_id: command.meta[:profile_id],
          target_session_key: command.session_key,
          target_node_id: destination.node_id,
          destination_binding_hash: digest(destination),
          invocation_proof_required: proof_required,
          admitted_tool_policy: LemonCore.ToolPolicy.expand(command.tool_policy || %{})
        })

      Map.put(entry, :native_root_binding, root_binding)
    end
  end

  defp capture_unattested_managed(command) do
    if is_binary(command.meta[:profile_id]) do
      with [] <- Map.get(command.meta, :mcp_servers),
           nil <- Map.get(command.meta, :invocation_proof),
           {:ok, profile, binding} <- capture_target_binding(command),
           :ok <- validate_current_target_policy(command),
           true <- profile["id"] == command.meta[:agent_id],
           {:ok, destination} <- profile_destination(profile),
           true <- selected_destination?(command.meta[:node], profile, destination),
           {:ok, %{} = entry} <- Store.fetch(@table, command.run_id),
           replacement = maybe_bind_root(entry, command, destination, binding, false),
           :ok <- Store.compare_and_swap(@table, command.run_id, entry, replacement),
           :ok <- Store.sync() do
        {:ok, destination}
      else
        _ -> {:error, :admission_unavailable}
      end
    else
      {:ok, nil}
    end
  end

  defp validate_command_invocation(command, profile) do
    with {:ok, policy} <- LemonCore.ToolPolicy.normalize(command.tool_policy || %{}) do
      LemonRouter.NativeFollowupAdmission.validate_invocation(
        %{
          "invocationContextKey" => command.meta[:invocation_context_key],
          "memoryContextKey" => command.meta[:memory_context_key],
          "invocationToolPolicy" => policy,
          "invocationMcpServers" => command.meta[:mcp_servers],
          "invocationProof" => descriptor(command.meta[:invocation_proof]),
          "sharedMemoryGrant" => command.meta[:shared_memory_grant]
        },
        command.run_id,
        profile
      )
    end
  end

  defp matches_destination?(node, "local"), do: node in [nil, "local", :local]
  defp matches_destination?(node, target), do: node == target

  # The command carries the profile's own selector (or, for a prepared
  # follow-up, the durable ID already resolved from it), never another node.
  defp selected_destination?(node, _profile, %{node_id: "local"}),
    do: node in [nil, "local", :local]

  defp selected_destination?(node, profile, %{node_id: id}), do: node in [profile["node"], id]

  defp put_destination_node(meta, %{node_id: id}) when id != "local", do: Map.put(meta, :node, id)
  defp put_destination_node(meta, _destination), do: meta

  defp verify_startup_binding(entry, run_id) do
    case current_admission_binding(entry) do
      :ok -> :ok
      {:error, :admission_unavailable} -> reject_activation(run_id, :admission_unavailable)
      error -> error
    end
  end

  defp validate_current_target_policy(command) do
    with {:ok, policy} <- LemonCore.ToolPolicy.normalize(command.tool_policy || %{}),
         {:ok, floor} <-
           LemonRouter.SubmissionBuilder.current_native_target_policy(
             command.meta[:profile_id],
             command.session_key,
             %{}
           ),
         {:ok, effective} <-
           LemonCore.ToolPolicy.normalize(LemonCore.ToolPolicy.intersect(policy, floor)),
         true <- effective == policy do
      :ok
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp current_admission_binding(%{native_failure: :outcome_unknown}),
    do: {:error, :outcome_unknown}

  defp current_admission_binding(%{native_failure: _}), do: {:error, :admission_unavailable}

  defp current_admission_binding(%{native_root_binding: lineage}) do
    case validate_reserved_destination(lineage, lineage.target_node_id) do
      {:ok, _} -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  defp current_admission_binding(%{native_followup: %{status: :outcome_unknown}}),
    do: {:error, :outcome_unknown}

  defp current_admission_binding(%{native_followup: lineage}) do
    case validate_reserved_destination(lineage, lineage.target_node_id) do
      {:ok, _} -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  defp current_admission_binding(_), do: :ok

  @doc false
  def validate_activation(command) do
    case Store.fetch(@table, command.run_id) do
      {:ok, %{native_failure: status}} ->
        {:error, status}

      {:ok, %{native_followup: lineage}} ->
        case lineage.status do
          status when status in [:dispatch_pending, :accepted] ->
            validate_bound_activation(command, lineage)

          :outcome_unknown ->
            {:error, :outcome_unknown}

          status when status in [:denied, :admission_unavailable, :aborted] ->
            {:error, status}

          _ ->
            reject_activation(command.run_id, :admission_unavailable)
        end

      {:ok, %{native_root_binding: lineage}} ->
        validate_bound_activation(command, lineage)

      {:ok, _} ->
        :ok

      _ ->
        {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp validate_bound_activation(command, lineage) do
    with true <- command.meta[:profile_id] == lineage.target_profile_id,
         true <- command.session_key == lineage.target_session_key,
         true <- matches_destination?(command.meta[:node], lineage.target_node_id),
         {:ok, _destination} <- validate_reserved_destination(lineage, lineage.target_node_id),
         {:ok, profile} <- current_target_binding(lineage),
         :ok <- validate_bound_authority(command, lineage, profile) do
      :ok
    else
      {:error, :unavailable} -> reject_activation(command.run_id, :outcome_unknown)
      _ -> reject_activation(command.run_id, :admission_unavailable)
    end
  end

  defp validate_bound_authority(command, %{invocation_proof_required: false}, _profile) do
    if command.meta[:mcp_servers] == [] and command.meta[:invocation_proof] == nil,
      do: :ok,
      else: {:error, :admission_unavailable}
  end

  defp validate_bound_authority(command, _lineage, profile) do
    case validate_command_invocation(command, profile) do
      {:ok, _} -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  defp reject_activation(run_id, status) do
    case record_activation_failure(run_id, status) do
      :ok -> {:error, status}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp record_activation_failure(run_id, status) do
    case Store.fetch(@table, run_id) do
      {:ok, %{native_followup: _}} ->
        record_outcome(run_id, status)

      {:ok, %{native_root_binding: _} = entry} ->
        replacement =
          entry
          |> Map.put(:native_failure, status)
          |> Map.put(
            :state,
            if(status == :outcome_unknown, do: "submitting", else: "native_rejected")
          )
          |> Map.put(:terminal, status != :outcome_unknown)

        with :ok <- Store.compare_and_swap(@table, run_id, entry, replacement),
             :ok <- Store.sync() do
          :ok
        else
          _ -> {:error, :outcome_unknown}
        end

      _ ->
        {:error, :outcome_unknown}
    end
  end

  @doc false
  def record_outcome(run_id, status) do
    with {:ok, %{native_followup: lineage} = entry} <- Store.fetch(@table, run_id),
         replacement = Map.put(entry, :native_followup, Map.put(lineage, :status, status)),
         replacement <-
           if(status in [:denied, :admission_unavailable, :aborted],
             do: replacement |> Map.put(:terminal, true) |> Map.put(:state, "native_rejected"),
             else: replacement
           ),
         :ok <- Store.compare_and_swap(@table, run_id, entry, replacement),
         :ok <- Store.sync() do
      :ok
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp descriptor(%{
         run_id: id,
         server_name: name,
         server_url: url,
         header_name: header,
         secret_name: secret
       }),
       do: %{
         "runId" => id,
         "serverName" => name,
         "serverUrl" => url,
         "headerName" => header,
         "secretName" => secret
       }

  defp descriptor(_), do: nil

  @doc false
  def semantic_meta(meta, source_run_id) do
    meta |> strip_private() |> Map.put(:parent_run_id, source_run_id)
  end

  defp strip_private(meta),
    do: Map.reject(meta, fn {key, _} -> to_string(key) in @private_fields end)

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
