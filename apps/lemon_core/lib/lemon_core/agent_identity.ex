defmodule LemonCore.AgentIdentity do
  @moduledoc """
  Durable, scope-local addresses for existing conversations.

  Handles are case-insensitive ASCII names, independent of display titles and
  stable `session://` or `bot://` IDs. Registration never creates a session.
  Native identities belong to the local `operator` scope; private product
  scopes contain only their explicitly registered external identities.

  Each scope is one strictly read, compare-and-swapped Store row. The bounded
  row holds at most 2,048 entries and its name index, so claiming, renaming and
  releasing a name are one atomic mutation. A fresh revision on every write
  prevents an old snapshot matching a remove/recreate (ABA) cycle. Native
  entries and pending claims bind to the exact durable session incarnation,
  never a reusable key or timestamp. Storage failures are errors, never absence
  or an empty roster.
  """

  alias LemonCore.{RunStore, SessionKey, Store}

  @table :agent_identities_v1
  @max_entries 2_048
  @max_attempts 64
  @max_label_bytes 256
  @max_metadata_bytes 2_048
  @default_limit 100
  @max_limit 500

  @type entry :: %{
          optional(:session_key) => binary(),
          optional(:incarnation) => binary(),
          id: binary(),
          name: binary() | nil,
          kind: :session | :bot,
          label: binary(),
          scope: binary(),
          metadata: map()
        }

  @doc "Register an existing native session or a durable external identity."
  @spec register(binary(), binary(), map()) :: {:ok, entry()} | {:error, atom()}
  def register(scope, id, attrs) when is_map(attrs) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, identity} <- parse_id(id),
         :ok <- allowed_kind(scope, identity.kind),
         :ok <- validate_attrs(identity, attrs),
         {:ok, identity} <- bind_incarnation(identity) do
      # Capture once, outside the CAS retry closure. A deleted claimant must
      # never acquire the replacement session's incarnation on retry.
      mutate(scope, fn state ->
        with :ok <- verify_native(identity),
             {:ok, entry} <- build_entry(scope, identity, attrs, state.entries[id]),
             {:ok, state} <- available_name(state, id, entry.name),
             :ok <- capacity(state, id) do
          {:ok, put_entry(state, entry), entry}
        end
      end)
    end
  end

  def register(_scope, _id, _attrs), do: {:error, :invalid_attrs}

  @doc "Rename an identity atomically, or clear its handle with `nil`."
  @spec rename(binary(), binary(), binary() | nil) :: {:ok, entry()} | {:error, atom()}
  def rename(scope, id, name) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, identity} <- parse_id(id),
         {:ok, name} <- normalize_name(name),
         {:ok, intended} <- bind_incarnation(identity) do
      mutate(scope, fn state ->
        with {:ok, entry} <- find_entry(state, id),
             true <- same_incarnation?(entry, intended),
             :ok <- verify_native(entry),
             {:ok, state} <- available_name(state, id, name) do
          entry = %{entry | name: name}
          {:ok, put_entry(state, entry), entry}
        else
          false -> {:error, :not_found}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Resolve only within the supplied scope, without a latest-session fallback."
  @spec resolve(binary(), binary()) :: {:ok, entry()} | {:error, atom()}
  def resolve(scope, target) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, target} <- normalize_target(target),
         {:ok, state} <- fetch_state(scope),
         {:ok, entry} <- lookup(state, target),
         :ok <- verify_native(entry) do
      {:ok, entry}
    end
  end

  @doc "List a bounded, content-free roster. Deleted native sessions are omitted."
  @spec list(binary(), keyword()) :: {:ok, [entry()]} | {:error, atom()}
  def list(scope, opts \\ [])

  def list(scope, opts) when is_list(opts) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, limit, query} <- list_options(opts),
         {:ok, state} <- fetch_state(scope),
         {:ok, entries} <- live_entries(state.entries) do
      entries =
        entries
        |> Enum.filter(&matches_query?(&1, query))
        |> Enum.sort_by(&{&1.name || "", &1.id})
        |> Enum.take(limit)

      {:ok, entries}
    end
  end

  def list(_scope, _opts), do: {:error, :invalid_options}

  @doc "Remove an identity and only its currently owned name binding."
  @spec remove(binary(), binary()) :: :ok | {:error, atom()}
  def remove(scope, id) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, _identity} <- parse_id(id) do
      case mutate(scope, fn state -> {:ok, drop_entry(state, id), :removed} end) do
        {:ok, :removed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Release only a native identity belonging to the deleted incarnation.

  Even an absent entry commits a scope revision to fence pending claims.
  `nil` denotes deletion of an already absent/legacy session, not a wildcard.
  """
  @spec remove(binary(), binary(), binary() | nil) :: :ok | {:error, atom()}
  def remove(scope, id, incarnation)
      when is_nil(incarnation) or (is_binary(incarnation) and byte_size(incarnation) == 22) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, %{kind: :session}} <- parse_id(id) do
      case mutate(scope, fn state ->
             updated =
               case state.entries[id] do
                 %{incarnation: ^incarnation} ->
                   drop_entry(state, id)

                 entry when is_map(entry) and is_nil(incarnation) ->
                   if Map.has_key?(entry, :incarnation), do: state, else: drop_entry(state, id)

                 _ ->
                   state
               end

             {:ok, updated, :removed}
           end) do
        {:ok, :removed} -> :ok
        {:error, _} = error -> error
      end
    else
      {:ok, _bot} -> {:error, :invalid_id}
      {:error, _} = error -> error
    end
  end

  def remove(_scope, _id, _incarnation), do: {:error, :invalid_session}

  defp mutate(scope, fun, attempts \\ @max_attempts)
  defp mutate(_scope, _fun, 0), do: {:error, :identity_busy}

  defp mutate(scope, fun, attempts) do
    with {:ok, previous} <- Store.fetch(@table, scope),
         {:ok, state} <- decode_state(previous, scope),
         {:ok, updated, result} <- fun.(state) do
      # An absent conditional remove still fences claims that verified the
      # deleted incarnation before the canonical index disappeared.
      updated = %{
        updated
        | revision: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      case Store.compare_and_swap(@table, scope, previous, updated) do
        :ok -> {:ok, result}
        {:error, :mismatch} -> mutate(scope, fun, attempts - 1)
        {:error, _} -> {:error, :store_unavailable}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp fetch_state(scope) do
    with {:ok, state} <- Store.fetch(@table, scope), do: decode_state(state, scope)
  end

  defp decode_state(nil, _scope),
    do: {:ok, %{version: 1, revision: nil, entries: %{}, names: %{}}}

  defp decode_state(
         %{version: 1, revision: revision, entries: entries, names: names} = state,
         scope
       )
       when is_binary(revision) and byte_size(revision) == 22 and is_map(entries) and
              map_size(entries) <= @max_entries and is_map(names) and
              map_size(names) <= @max_entries do
    valid? =
      Enum.all?(entries, fn {id, entry} ->
        valid_stored_entry?(id, entry) and entry.scope == scope
      end) and names == name_index(entries) and
        map_size(names) == Enum.count(entries, fn {_id, entry} -> entry.name != nil end)

    if valid?, do: {:ok, state}, else: {:error, :invalid_identity_state}
  end

  defp decode_state(_, _scope), do: {:error, :invalid_identity_state}

  defp valid_stored_entry?(
         id,
         %{id: id, name: name, scope: scope, label: label, metadata: metadata} = entry
       ) do
    with {:ok, identity} <- parse_id(id),
         true <- Map.get(entry, :kind) == identity.kind,
         true <- Map.get(entry, :session_key) == Map.get(identity, :session_key),
         true <- valid_incarnation?(entry),
         {:ok, ^scope} <- normalize_scope(scope),
         :ok <- allowed_kind(scope, identity.kind),
         {:ok, ^name} <- normalize_name(name),
         :ok <- validate_label(label),
         :ok <- validate_metadata(metadata) do
      true
    else
      _ -> false
    end
  end

  defp valid_stored_entry?(_, _), do: false

  defp name_index(entries) do
    Enum.reduce(entries, %{}, fn
      {_id, %{name: nil}}, names -> names
      {id, %{name: name}}, names -> Map.put(names, name, id)
    end)
  end

  defp put_entry(state, entry) do
    state = drop_entry(state, entry.id)
    names = if entry.name, do: Map.put(state.names, entry.name, entry.id), else: state.names
    %{state | entries: Map.put(state.entries, entry.id, entry), names: names}
  end

  defp drop_entry(state, id) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        names =
          if entry.name && state.names[entry.name] == id,
            do: Map.delete(state.names, entry.name),
            else: state.names

        %{state | entries: entries, names: names}
    end
  end

  defp available_name(state, _id, nil), do: {:ok, state}

  defp available_name(state, id, name) do
    case state.names[name] do
      nil ->
        {:ok, state}

      ^id ->
        {:ok, state}

      owner ->
        case verify_native(state.entries[owner]) do
          :ok -> {:error, :name_taken}
          {:error, :not_found} -> {:ok, drop_entry(state, owner)}
          {:error, _} = error -> error
        end
    end
  end

  defp capacity(state, id) do
    if Map.has_key?(state.entries, id) or map_size(state.entries) < @max_entries,
      do: :ok,
      else: {:error, :scope_full}
  end

  defp find_entry(state, id) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  defp lookup(state, {:id, id}), do: find_entry(state, id)

  defp lookup(state, {:name, name}) do
    case state.names[name] do
      nil -> {:error, :not_found}
      id -> find_entry(state, id)
    end
  end

  defp bind_incarnation(%{kind: :bot} = identity), do: {:ok, identity}

  defp bind_incarnation(%{kind: :session, session_key: key} = identity) do
    with {:ok, index} <- RunStore.ensure_session_incarnation(key) do
      {:ok, Map.put(identity, :incarnation, index.incarnation)}
    end
  end

  defp valid_incarnation?(%{kind: :bot}), do: true

  defp valid_incarnation?(%{kind: :session} = entry) do
    case Map.fetch(entry, :incarnation) do
      :error -> true
      {:ok, token} -> is_binary(token) and byte_size(token) == 22
    end
  end

  defp same_incarnation?(%{kind: :bot}, %{kind: :bot}), do: true

  defp same_incarnation?(%{kind: :session} = left, %{kind: :session} = right),
    do: Map.get(left, :incarnation) == Map.get(right, :incarnation)

  defp verify_native(%{kind: :bot}), do: :ok

  defp verify_native(%{kind: :session, session_key: key, incarnation: incarnation}) do
    case RunStore.ensure_session_incarnation(key) do
      {:ok, %{incarnation: ^incarnation}} -> :ok
      {:ok, _replacement} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # A pre-incarnation identity cannot safely inherit the current conversation.
  defp verify_native(%{kind: :session}), do: {:error, :not_found}

  defp live_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {_id, entry}, {:ok, acc} ->
      case verify_native(entry) do
        :ok -> {:cont, {:ok, [entry | acc]}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_entry(scope, identity, attrs, previous) do
    previous =
      if previous && same_incarnation?(previous, identity),
        do: previous,
        else: Map.merge(identity, %{scope: scope, name: nil, label: "", metadata: %{}})

    name = attr(attrs, :name, previous.name)
    label = attr(attrs, :label, previous.label)
    metadata = attr(attrs, :metadata, previous.metadata)

    with {:ok, name} <- normalize_name(name),
         :ok <- validate_label(label),
         :ok <- validate_metadata(metadata) do
      {:ok, %{previous | name: name, label: label, metadata: metadata}}
    end
  end

  defp validate_attrs(identity, attrs) do
    kind = attr(attrs, :kind, identity.kind)
    key = attr(attrs, :session_key, Map.get(identity, :session_key))

    if kind in [identity.kind, Atom.to_string(identity.kind)] and
         key == Map.get(identity, :session_key),
       do: :ok,
       else: {:error, :invalid_attrs}
  end

  defp attr(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_scope(:operator), do: {:ok, "operator"}

  defp normalize_scope(scope) when is_binary(scope) and byte_size(scope) in 1..256 do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9:._-]*\z/, scope),
      do: {:ok, scope},
      else: {:error, :invalid_scope}
  end

  defp normalize_scope(_), do: {:error, :invalid_scope}

  defp allowed_kind("operator", _kind), do: :ok
  defp allowed_kind(_scope, :bot), do: :ok
  defp allowed_kind(_scope, :session), do: {:error, :invalid_scope}

  defp normalize_name(nil), do: {:ok, nil}

  defp normalize_name("@" <> name), do: normalize_bare_name(name)
  defp normalize_name(name), do: normalize_bare_name(name)

  defp normalize_bare_name(name) when is_binary(name) and byte_size(name) in 1..64 do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_-]*\z/, name),
      do: {:ok, String.downcase(name, :ascii)},
      else: {:error, :invalid_name}
  end

  defp normalize_bare_name(_), do: {:error, :invalid_name}

  defp normalize_target(target) when is_binary(target) do
    if String.starts_with?(target, ["session://", "bot://"]) do
      with {:ok, _} <- parse_id(target), do: {:ok, {:id, target}}
    else
      case normalize_name(target) do
        {:ok, nil} -> {:error, :invalid_name}
        {:ok, name} -> {:ok, {:name, name}}
        {:error, _} = error -> error
      end
    end
  end

  defp normalize_target(_), do: {:error, :invalid_id}

  defp parse_id("session://" <> key = id) when byte_size(key) in 1..1_024 do
    case SessionKey.parse(key) do
      %{kind: :main, agent_id: agent, sub_id: sub} ->
        canonical = SessionKey.main(agent) <> if(sub, do: ":sub:" <> sub, else: "")
        native_id(id, key, canonical)

      %{kind: :channel_peer} = parsed ->
        native_id(id, key, SessionKey.channel_peer(parsed))

      _ ->
        {:error, :invalid_id}
    end
  end

  defp parse_id("bot://" <> rest = id) when byte_size(rest) <= 257 do
    case String.split(rest, "/") do
      [instance, bot] ->
        if valid_identifier?(instance, 128) and valid_identifier?(bot, 128),
          do: {:ok, %{id: id, kind: :bot}},
          else: {:error, :invalid_id}

      _ ->
        {:error, :invalid_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_id}

  defp native_id(id, key, canonical) do
    if key == canonical and
         Enum.all?(String.split(key, ":"), fn part ->
           byte_size(part) in 1..256 and Regex.match?(~r/\A[A-Za-z0-9._@-]+\z/, part)
         end),
       do: {:ok, %{id: id, kind: :session, session_key: key}},
       else: {:error, :invalid_id}
  end

  defp valid_identifier?(value, limit) when is_binary(value) do
    byte_size(value) in 1..limit and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)
  end

  defp valid_identifier?(_, _), do: false

  defp validate_label(label) when is_binary(label) and byte_size(label) <= @max_label_bytes do
    if String.valid?(label) and not Regex.match?(~r/[\x00-\x1F\x7F]/, label),
      do: :ok,
      else: {:error, :invalid_label}
  end

  defp validate_label(_), do: {:error, :invalid_label}

  defp validate_metadata(metadata) when is_map(metadata) and map_size(metadata) <= 16 do
    valid? =
      Enum.all?(metadata, fn {key, value} ->
        key = if is_atom(key), do: Atom.to_string(key), else: key
        valid_identifier?(key, 64) and valid_identifier?(value, 256)
      end)

    if valid? and :erlang.external_size(metadata) <= @max_metadata_bytes,
      do: :ok,
      else: {:error, :invalid_metadata}
  end

  defp validate_metadata(_), do: {:error, :invalid_metadata}

  defp list_options(opts) do
    if Keyword.keyword?(opts) do
      limit = Keyword.get(opts, :limit, @default_limit)
      query = Keyword.get(opts, :query, "")

      if is_integer(limit) and limit in 1..@max_limit and is_binary(query) and
           byte_size(query) <= 256 and String.valid?(query),
         do: {:ok, limit, String.downcase(query)},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp matches_query?(_entry, ""), do: true

  defp matches_query?(entry, query) do
    Enum.any?([entry.name || "", entry.id, entry.label], fn value ->
      String.contains?(String.downcase(value), query)
    end)
  end
end
