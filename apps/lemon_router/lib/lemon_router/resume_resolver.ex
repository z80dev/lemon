defmodule LemonRouter.ResumeResolver do
  @moduledoc """
  Router-owned native resume resolution.

  Explicit resume tokens must belong to Lemon. Persisted tokens from retired
  engines are left in chat state for rollback/history, but never resumed.
  Native journals are bound durably to the initiating execution context. A
  changed or unproven scoped context starts a new journal without deleting the
  previous one. Unbound legacy journals remain usable by unscoped callers that
  do not explicitly override policy or MCP capabilities.

  Context comparisons use `LemonCore.InvocationProof` to project only a valid,
  factory-attested, fixed-run proof header. All other MCP configuration remains
  exact, and the transport configuration is never rewritten.
  """

  require Logger

  alias LemonCore.{ExecutionCommand, InvocationProof, MapHelpers, ResumeToken, Store}

  @native_engine "lemon"
  @context_table :native_resume_contexts

  @type source :: :explicit | :auto | nil
  @type resolved ::
          {:ok, ResumeToken.t() | nil, source()}
          | {:error, {:unsupported_resume_engine, binary(), String.t()}}

  @spec resolve(
          ResumeToken.t() | map() | nil,
          binary() | nil,
          map(),
          map() | nil,
          Store.server(),
          binary() | nil
        ) :: resolved()
  def resolve(explicit_resume, session_key, meta \\ %{}, tool_policy \\ nil, store \\ Store, run_id \\ nil) do
    context = execution_context(meta, tool_policy, comparison_servers(meta, run_id))

    case normalize_explicit_resume(explicit_resume) do
      {:ok, resume} ->
        authorize_resume(resume, :explicit, context, meta, store)

      {:error, engine} ->
        {:error,
         {:unsupported_resume_engine, engine,
          "Top-level router resumes support only the native \"lemon\" engine. " <>
            "Use `lemon resume <id>` or omit the resume token."}}

      :none ->
        if disable_auto_resume?(meta) do
          {:ok, nil, nil}
        else
          resolve_auto_resume(session_key, context, meta, store)
        end
    end
  end

  defp resolve_auto_resume(session_key, context, meta, store) when is_binary(session_key) do
    case persisted_resume(LemonCore.ChatStateStore.get(store, session_key)) do
      {:native, resume} ->
        authorize_resume(resume, :auto, context, meta, store)

      {:non_native, engine} ->
        Logger.warning(
          "Router ignored persisted non-native resume state session=#{inspect(session_key)} " <>
            "engine=#{inspect(engine)}"
        )

        {:ok, nil, nil}

      :none ->
        {:ok, nil, nil}
    end
  end

  defp resolve_auto_resume(_session_key, _context, _meta, _store), do: {:ok, nil, nil}

  @doc false
  def execution_context(%ExecutionCommand{} = request) do
    execution_context(request.meta || %{}, request.tool_policy, InvocationProof.comparison_servers(request))
  end

  defp execution_context(meta, tool_policy, servers) do
    {MapHelpers.get_key(meta, :invocation_context_key), tool_policy, servers,
     MapHelpers.get_key(meta, :memory_context_key),
     Map.get(meta, :memory_context_verified) == true,
     Map.get(meta, :shared_memory_grant) == true}
  end

  defp comparison_servers(meta, run_id) do
    if Map.get(meta, :invocation_proof_verified) == true do
      InvocationProof.comparison_servers(%{run_id: run_id, meta: meta})
    else
      Map.get(meta, :mcp_servers)
    end
  end

  @doc false
  @spec bind(ResumeToken.t(), ExecutionCommand.t(), Store.server()) :: :ok | {:error, term()}
  def bind(%ResumeToken{} = resume, %ExecutionCommand{} = request, store \\ Store) do
    key = {resume.engine, resume.value}
    digest = context_digest(execution_context(request))

    put_binding(store, key, digest)
  end

  @doc false
  @spec bind_run(ExecutionCommand.t(), Store.server()) :: :ok | {:error, term()}
  def bind_run(%ExecutionCommand{} = request, store \\ Store) do
    put_binding(store, {:run, request.run_id}, context_digest(execution_context(request)))
  end

  defp put_binding(store, key, digest) do
    case Store.put_new(store, @context_table, key, digest) do
      :ok -> durable_binding(store, key, digest)
      {:error, :exists} -> durable_binding(store, key, digest)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def filter_history(history, meta, tool_policy, store \\ Store, run_id \\ nil) do
    context = execution_context(meta, tool_policy, comparison_servers(meta, run_id))
    digest = context_digest(context)
    legacy = legacy_unbound_context?(context, meta)

    if Store.sync(store) == :ok do
      Enum.filter(history, fn {run_id, data} ->
        case Store.fetch(store, @context_table, {:run, run_id}) do
          {:ok, ^digest} -> true
          {:ok, nil} -> legacy and legacy_summary?(data)
          _ -> false
        end
      end)
    else
      []
    end
  end

  defp durable_binding(store, key, digest) do
    case Store.fetch(store, @context_table, key) do
      {:ok, ^digest} -> Store.sync(store)
      {:ok, _other} -> {:error, :resume_context_conflict}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_resume(resume, source, context, meta, store) do
    digest = context_digest(context)

    allowed =
      case Store.fetch(store, @context_table, {resume.engine, resume.value}) do
        {:ok, ^digest} -> Store.sync(store) == :ok
        {:ok, nil} -> legacy_unbound_context?(context, meta)
        _ -> false
      end

    if allowed, do: {:ok, resume, source}, else: {:ok, nil, nil}
  end

  defp legacy_unbound_context?({nil, _tool_policy, nil, nil, false, false}, meta) do
    Map.get(meta, :resume_policy_override) != true
  end

  defp legacy_unbound_context?(_context, _meta), do: false

  defp legacy_summary?(data) do
    summary = MapHelpers.get_key(data, :summary) || %{}
    meta = MapHelpers.get_key(summary, :meta) || %{}
    legacy_unbound_context?(execution_context(meta, nil, Map.get(meta, :mcp_servers)), meta)
  end

  defp context_digest(context) do
    :crypto.hash(:sha256, :erlang.term_to_binary(context, [:deterministic]))
  end

  defp persisted_resume(state) when is_map(state) do
    case {fetch(state, :last_engine), fetch(state, :last_resume_token)} do
      {engine, token} when is_binary(engine) and is_binary(token) ->
        case normalize_engine(engine) do
          @native_engine -> {:native, %ResumeToken{engine: @native_engine, value: token}}
          nil -> :none
          other -> {:non_native, other}
        end

      _ ->
        :none
    end
  end

  defp persisted_resume(_), do: :none

  defp normalize_explicit_resume(%ResumeToken{engine: engine, value: value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(%{engine: engine, value: value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(%{"engine" => engine, "value" => value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(_), do: :none

  defp normalize_explicit_token(engine, value) when is_binary(engine) do
    case normalize_engine(engine) do
      @native_engine when is_binary(value) ->
        {:ok, %ResumeToken{engine: @native_engine, value: value}}

      @native_engine ->
        :none

      nil ->
        :none

      other ->
        {:error, other}
    end
  end

  defp normalize_explicit_token(_engine, _value), do: :none

  defp normalize_engine(engine) when is_binary(engine) do
    case String.trim(engine) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp disable_auto_resume?(meta) when is_map(meta) do
    fetch(meta, :disable_auto_resume) == true
  end


  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
