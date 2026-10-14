defmodule LemonMemory.ContextScope do
  @moduledoc """
  Ownership of native memory and explicit operator selections.

  Runtime proof is accepted only from atom fields on the admitted request.
  Persisted string stamps are produced by the owning writer, never by a provider.
  Invocation keys prove admission but are deliberately not durable identities.
  """

  @key ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/
  @fields [:memory_scope, :memory_context_key, :memory_context_verified,
           :memory_shared_verified, :invocation_context_key, :shared_memory_grant]
  @wire_fields ~w(memoryScope memoryContextKey memoryContextVerified memorySharedVerified invocationContextKey sharedMemoryGrant)
  @wire_atoms [:memoryScope, :memoryContextKey, :memoryContextVerified,
               :memorySharedVerified, :invocationContextKey, :sharedMemoryGrant]
  @ownership_fields @fields ++ Enum.map(@fields, &Atom.to_string/1) ++ @wire_fields ++ @wire_atoms

  def valid_key?(key) when is_binary(key) and byte_size(key) in 1..128,
    do: Regex.match?(@key, key)
  def valid_key?(_), do: false

  def scope(context) when is_map(context) do
    cond do
      valid_key?(context[:memory_context_key]) and
          valid_key?(context[:invocation_context_key]) and
          context[:memory_context_verified] == true ->
        {:ok, {:private, context[:memory_context_key]}}
      marked?(context) -> {:error, :unproven_context}
      true -> {:ok, :legacy}
    end
  end
  def scope(_), do: {:error, :unproven_context}

  def selection(params) when is_map(params) do
    mode = Map.get(params, "memoryScope", Map.get(params, :memory_scope))
    key = Map.get(params, "memoryContextKey", Map.get(params, :memory_context_key))
    case {mode, key} do
      {nil, nil} ->
        if Enum.any?(["memoryScope", "memoryContextKey", :memory_scope, :memory_context_key],
             &Map.has_key?(params, &1)), do: {:error, :invalid_memory_scope}, else: {:ok, :operator}
      {mode, key} when mode in ["private", :private] ->
        if valid_key?(key), do: {:ok, {:private, key}}, else: {:error, :invalid_memory_scope}
      {mode, nil} when mode in ["shared", :shared] -> {:ok, :shared}
      _ -> {:error, :invalid_memory_scope}
    end
  end
  def selection(_), do: {:error, :invalid_memory_scope}

  def valid_selector?(:operator), do: true
  def valid_selector?(:shared), do: true
  def valid_selector?({:private, key}), do: valid_key?(key)
  def valid_selector?(_), do: false

  def matches?(meta, :operator) when is_map(meta), do: true
  def matches?(meta, {:private, key}) when is_map(meta) do
    valid_key?(key) and meta["memory_scope"] == "private" and
      meta["memory_context_verified"] == true and meta["memory_context_key"] == key
  end
  def matches?(meta, :shared) when is_map(meta) do
    meta["memory_scope"] == "shared" and meta["memory_shared_verified"] == true and
      meta["memory_context_key"] == nil
  end
  def matches?(meta, :legacy) when is_map(meta) do
    matches?(meta, :shared) or
      (meta["memory_scope"] in [nil, "legacy"] and not marked?(Map.delete(meta, "memory_scope")))
  end
  def matches?(_, _), do: false

  def private_metadata(context) do
    case scope(context) do
      {:ok, {:private, key}} -> {:ok, metadata({:private, key})}
      _ -> {:error, :unproven_context}
    end
  end

  @doc "Canonical stamps for an owning writer's already validated selection."
  def metadata({:private, key}) do
    %{"memory_scope" => "private", "memory_context_key" => key,
      "memory_context_verified" => true}
  end
  def metadata(:shared), do: %{"memory_scope" => "shared", "memory_shared_verified" => true}
  def metadata(:legacy), do: %{"memory_scope" => "legacy"}
  def metadata(:unproven), do: %{"memory_scope" => "unproven"}

  def shared_grant?(context) when is_map(context),
    do: context[:shared_memory_grant] == true and match?({:ok, {:private, _}}, scope(context))
  def shared_grant?(_), do: false

  def run_metadata(meta) when is_map(meta) do
    stamps = case scope(meta) do
      {:ok, owner} -> metadata(owner)
      {:error, :unproven_context} -> metadata(:unproven)
    end
    meta |> Map.drop(@ownership_fields) |> Map.merge(stamps)
  end
  def run_metadata(_), do: run_metadata(%{})

  @doc "Canonical index columns for a trusted new owning write."
  def index_fields(meta, workspace_key) do
    meta = if is_map(meta), do: meta, else: %{}
    owner = cond do
      matches?(meta, {:private, meta["memory_context_key"]}) -> "private"
      matches?(meta, :shared) -> "shared"
      matches?(meta, :legacy) -> "legacy"
      true -> "unproven"
    end
    {owner, if(owner == "private", do: meta["memory_context_key"], else: nil),
      meta["home_digest"] || meta[:home_digest],
      if(owner != "unproven", do: index_kind(meta["kind"] || meta[:kind]), else: "run"),
      LemonMemory.Project.repository_root(workspace_key)}
  end

  defp index_kind(kind) when is_binary(kind), do: kind
  defp index_kind(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp index_kind(_), do: nil

  @doc "Stored authority, never inferred from retained raw ownership claims alone."
  def indexed_owner(meta, {mode, key, home, _kind, _root}) when is_map(meta) do
    selector = case {mode, key} do
      {"private", key} -> {:private, key}
      {"shared", nil} -> :shared
      {"legacy", nil} -> :legacy
      {nil, nil} -> :legacy
      _ -> :unproven
    end
    home_matches = home == (meta["home_digest"] || meta[:home_digest]) or mode == nil
    legacy_matches = selector != :legacy or
      (meta["memory_scope"] in [nil, "legacy"] and not matches?(meta, :shared))
    if home_matches and legacy_matches and matches?(meta, selector), do: selector, else: :unproven
  end
  def indexed_owner(_, _), do: :unproven

  defp marked?(meta) do
    Enum.any?(@ownership_fields, fn field ->
      value = Map.get(meta, field)
      value not in [nil, false, "", :legacy, "legacy"]
    end)
  end
end
