defmodule CodingAgent.Tools.Task.InvocationAuthority do
  @moduledoc """
  Invocation authority carried by native sessions, children and their followups.

  Managed Lemon Bot invocations bind memory, MCP servers and router lineage to
  session-owned options. This module decides whether a context is managed,
  carries lineage to native followups, captures named-messaging authority, and
  strips every authority-bearing field from child-visible metadata. Model
  parameters never enter any of these maps.
  """

  alias LemonCore.SessionKey

  @doc false
  def private_native_fields do
    [
      :native_lineage_handle,
      :native_lineage_run_id,
      :native_source_profile_id,
      :native_source_session_key,
      :native_followup_submit,
      :native_source_floor_fun,
      :invocation_proof,
      :invocation_proof_verified,
      :native_managed_context,
      :bot_folder_root,
      :config_cwd
    ]
  end

  @doc false
  def submit_native_followup(context, request) do
    source = %{
      run_id: context[:native_lineage_run_id],
      lineage_handle: context[:native_lineage_handle]
    }

    if is_binary(source.run_id) and is_binary(source.lineage_handle) do
      submit =
        context[:native_followup_submit] || (&LemonCore.RouterBridge.submit_native_followup/2)

      submit.(source, request)
    else
      {:error, :native_followup_lineage_unavailable}
    end
  end

  @doc false
  def managed_context?(context) do
    case Map.fetch(context, :native_managed_context) do
      {:ok, flag} when is_boolean(flag) -> flag
      _ -> managed_metadata?(context)
    end
  end

  @doc false
  def named_messaging_managed?(opts) do
    context = Map.merge(Map.new(opts), Keyword.get(opts, :approval_context) || %{})

    managed_context?(context) or
      reserved_invocation_reference?(context[:invocation_mcp_servers] || context[:mcp_servers])
  end

  @doc """
  Captures the current native conversation's authority for named messaging.
  Caller options are session-owned; model parameters must never enter this map.
  Header parentage is not used: ordinary forks can have a parent without being
  delegated workers. Native children retain only their existing family authority.
  """
  def named_messaging_source(opts) do
    session_key = Keyword.get(opts, :session_key)

    cond do
      named_messaging_managed?(opts) ->
        {:error, "Managed Lemon Bot invocations must use product MCP messaging tools"}

      Keyword.get(opts, :task_child, Keyword.get(opts, :session_scope) in [:subagent, "subagent"]) !=
        false or
          Keyword.get(opts, :subagent, false) == true ->
        {:error, "Native task children can message their family only"}

      not is_binary(session_key) or not SessionKey.valid?(session_key) ->
        {:error, "Named messaging requires the current persisted canonical session"}

      true ->
        context =
          Map.merge(Map.new(opts), Keyword.get(opts, :approval_context) || %{})
          |> Map.take([
            :run_id,
            :session_pid,
            :cwd,
            :tool_policy,
            :execution_context,
            :agent_id,
            :native_source_profile_id,
            :profile_id,
            :invocation_context_key,
            :invocation_mcp_servers,
            :mcp_servers,
            :invocation_proof_verified,
            :native_lineage_handle,
            :native_lineage_run_id,
            :memory_context_key,
            :memory_context_verified,
            :shared_memory_grant,
            :channel_identity
          ])
          |> Map.put(:session_key, session_key)
          |> Map.put(:task_child, false)
          |> Map.put(:native_managed_context, false)

        {:ok, "session://" <> session_key, context}
    end
  end

  @doc false
  def continuation_metadata(meta, context) do
    meta = sanitize_child_metadata(meta || %{})

    if managed_context?(context) do
      meta
    else
      case context[:invocation_context_key] do
        key when is_binary(key) and key != "" ->
          meta
          |> Map.put(:invocation_context_key, key)
          |> Map.put(:mcp_servers, context[:invocation_mcp_servers] || [])

        _ ->
          meta
      end
    end
  end

  @doc false
  def sanitize_child_metadata(meta) when is_map(meta) do
    names = [
      "invocation_context_key",
      "invocationContextKey",
      "memory_context_key",
      "memoryContextKey",
      "memory_context_verified",
      "memoryContextVerified",
      "shared_memory_grant",
      "sharedMemoryGrant",
      "invocation_proof",
      "invocationProof",
      "invocation_proof_verified",
      "invocationProofVerified",
      "native_lineage_handle",
      "nativeLineageHandle",
      "native_lineage_run_id",
      "nativeLineageRunId",
      "native_destination_pid",
      "nativeDestinationPid",
      "native_destination_generation",
      "nativeDestinationGeneration",
      "native_source_profile_id",
      "nativeSourceProfileId",
      "native_source_session_key",
      "nativeSourceSessionKey",
      "native_managed_context",
      "nativeManagedContext",
      "native_followup_submit",
      "nativeFollowupSubmit",
      "native_source_floor_fun",
      "nativeSourceFloorFun",
      "mcp_servers",
      "mcpServers",
      "invocation_mcp_servers",
      "invocationMcpServers",
      "sourceRunId",
      "source_run_id",
      "sourceProfileId",
      "source_profile_id",
      "sourceSessionKey",
      "source_session_key",
      "rootRunId",
      "root_run_id"
    ]

    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      name = if is_atom(key), do: Atom.to_string(key), else: key

      if name in names or name in ["mcp_servers_json", "mcpServersJson"],
        do: acc,
        else: Map.put(acc, key, sanitize_nested_metadata(value))
    end)
  end

  defp sanitize_nested_metadata(value) when is_map(value), do: sanitize_child_metadata(value)

  defp sanitize_nested_metadata(value) when is_list(value),
    do: Enum.map(value, &sanitize_nested_metadata/1)

  defp sanitize_nested_metadata(value), do: value

  @doc false
  def managed_metadata?(meta) when is_map(meta) do
    fields = [
      {:memory_context_key, :memoryContextKey, "memoryContextKey"},
      {:memory_context_verified, :memoryContextVerified, "memoryContextVerified"},
      {:shared_memory_grant, :sharedMemoryGrant, "sharedMemoryGrant"},
      {:invocation_proof, :invocationProof, "invocationProof"},
      {:invocation_proof_verified, :invocationProofVerified, "invocationProofVerified"},
      {:native_lineage_handle, :nativeLineageHandle, "nativeLineageHandle"},
      {:native_lineage_run_id, :nativeLineageRunId, "nativeLineageRunId"}
    ]

    Enum.any?(fields, fn {key, camel_atom, camel} ->
      Enum.any?(
        [key, Atom.to_string(key), camel, camel_atom],
        &Map.has_key?(meta, &1)
      )
    end) or
      reserved_invocation_reference?(
        meta[:invocation_mcp_servers] || meta[:mcp_servers] || meta["mcp_servers"]
      )
  end

  defp reserved_invocation_reference?(value) when is_binary(value),
    do: String.contains?(value, "lemon_bot/invocations/")

  defp reserved_invocation_reference?(value) when is_list(value),
    do: Enum.any?(value, &reserved_invocation_reference?/1)

  defp reserved_invocation_reference?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, item} -> reserved_invocation_reference?(item) end)

  defp reserved_invocation_reference?(_), do: false
end
