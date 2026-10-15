defmodule LemonSkills.ProfileMemory do
  @moduledoc """
  Destination-local profile memory interface for operator clients.

  `execute/4` derives paths from a validated profile ID; it never reads a profile
  configuration record or accepts a caller-provided workspace. The controller
  owns existence/placement validation. `:profile_opts` is passed to
  `LemonCore.ProfileStore.paths/2`; `:store` selects a memory Store server.

  Results contain only string-keyed JSON-safe projections. Legacy omitted operator
  scope can read `workspace` USER.md/MEMORY.md entries and `durable` documents.
  Explicit private/shared selectors delegate canonical preferences and exact-ID
  ownership to the existing memory lifecycle, never raw personal files.
  Successful explicit selections echo memoryScope/memoryContextKey for the trusted
  backend to validate and strip before model/client exposure.

  Text is redacted and capped at 2048 bytes. IDs bind profile and revision, not
  private authority: get/delete recheck the selector. Legacy workspace timestamps
  describe the file. Pages default to 25, at most 50; unfiltered list browses a
  recent window, while scoped queries use bounded candidates from the owning index.
  Opaque cursors bind profile, query, selector and snapshot; changes invalidate them.
  """

  alias LemonCore.ProfileStore
  alias LemonMemory.{ContextScope, Lifecycle, Preferences, Store}
  alias LemonSkills.WorkspacePreferences

  @operations ~w(list search get add delete)
  @id_pattern ~r/\A(?:durable_|pref_user_|pref_memory_)[A-Za-z0-9_.-]+\z/

  @spec execute(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def execute(operation, profile_id, params, opts \\ []) do
    with :ok <- validate_request(operation, params, opts),
         :ok <- validate_profile_id(profile_id),
         {:ok, paths} <- ProfileStore.paths(profile_id, Keyword.get(opts, :profile_opts, [])),
         :ok <- validate_profile_param(params, profile_id),
         {:ok, selection} <- ContextScope.selection(params) do
      context = %{
        agent_id: profile_id,
        cwd: paths["workspace"],
        workspace_dir: paths["workspace"],
        session_scope: :main,
        session_key: "agent:#{profile_id}:main"
      }

      case dispatch(operation, context, params,
             server: Keyword.get(opts, :store, Store),
             memory_scope: selection
           ) do
        {:ok, result} when is_map(result) -> {:ok, scope_echo(result, selection)}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :memory_unavailable}
      end
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  defp scope_echo(result, :operator), do: result

  defp scope_echo(result, :shared),
    do: Map.merge(result, %{"memoryScope" => "shared", "memoryContextKey" => nil})

  defp scope_echo(result, {:private, key}),
    do: Map.merge(result, %{"memoryScope" => "private", "memoryContextKey" => key})

  defp scope_binding({:private, key}), do: ["private", key]
  defp scope_binding(scope), do: Atom.to_string(scope)

  defp validate_request(operation, params, opts) do
    cond do
      operation not in @operations -> {:error, :invalid_operation}
      not is_map(params) -> {:error, :invalid_params}
      not Enum.all?(Map.keys(params), &is_binary/1) -> {:error, :invalid_params}
      not Keyword.keyword?(opts) -> {:error, :invalid_params}
      not Keyword.keyword?(Keyword.get(opts, :profile_opts, [])) -> {:error, :invalid_params}
      true -> :ok
    end
  end

  defp validate_profile_id(profile_id) when is_binary(profile_id) do
    if byte_size(profile_id) <= 64 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, profile_id),
      do: :ok,
      else: {:error, :invalid_id}
  end

  defp validate_profile_id(_), do: {:error, :invalid_id}

  defp validate_profile_param(params, profile_id) do
    case Map.fetch(params, "profileId") do
      :error -> :ok
      {:ok, ^profile_id} -> :ok
      _ -> {:error, :profile_mismatch}
    end
  end

  defp dispatch(operation, context, params, opts) when operation in ["list", "search"] do
    with {:ok, query} <- query(params, operation),
         {:ok, limit} <- limit(params),
         {:ok, durable} <- durable_items(operation, context, query, opts),
         {:ok, preferences} <- workspace_items(context, query, opts) do
      items =
        (durable.items ++ preferences)
        |> Enum.sort_by(&{-&1["updatedAtMs"], &1["id"]})

      binding =
        digest(
          Jason.encode!([
            context.agent_id,
            Path.expand(context.workspace_dir),
            scope_binding(opts[:memory_scope]),
            query,
            durable.revision,
            items
          ])
        )

      with {:ok, offset} <- cursor_offset(Map.get(params, "cursor"), binding, length(items)) do
        page = Enum.slice(items, offset, limit)
        next_offset = offset + length(page)

        next_cursor =
          if next_offset < length(items), do: encode_cursor(binding, next_offset), else: nil

        {:ok, %{"items" => page, "nextCursor" => next_cursor}}
      end
    end
  end

  defp dispatch("get", context, params, opts) do
    with {:ok, id} <- id(params),
         {:ok, item} <- get_item(context, id, opts) do
      {:ok, %{"item" => item}}
    end
  end

  defp dispatch("add", context, params, opts) do
    result =
      case opts[:memory_scope] do
        :operator ->
          WorkspacePreferences.add(
            context.workspace_dir,
            Map.get(params, "kind", "memory"),
            Map.get(params, "text")
          )

        selection ->
          Preferences.add(context, Map.get(params, "kind", "memory"), Map.get(params, "text"),
            store: opts[:server],
            memory_scope: selection
          )
      end

    with {:ok, item} <- result, do: {:ok, %{"item" => item}}
  end

  defp dispatch("delete", context, params, opts) do
    with {:ok, id} <- id(params),
         :ok <- confirmation(params, id) do
      delete_item(context, id, opts)
    end
  end

  defp get_item(context, "durable_" <> _ = id, opts),
    do: Lifecycle.profile_get(context, id, opts)

  defp get_item(context, id, opts) do
    if opts[:memory_scope] == :operator,
      do: WorkspacePreferences.get(context.workspace_dir, id),
      else: {:error, :not_found}
  end

  defp delete_item(context, "durable_" <> _ = id, opts) do
    with {:ok, preview} <- Lifecycle.profile_preview_delete(context, id, opts) do
      Lifecycle.profile_delete(context, id, preview.confirmation_digest, opts)
    end
  end

  defp delete_item(context, id, opts) do
    if opts[:memory_scope] == :operator do
      with {:ok, preview} <- WorkspacePreferences.preview_delete(context.workspace_dir, id) do
        WorkspacePreferences.delete(context.workspace_dir, id, preview.revision)
      end
    else
      {:error, :not_found}
    end
  end

  defp durable_items("list", context, "", opts), do: Lifecycle.profile_list(context, "", opts)

  defp durable_items(_operation, context, query, opts),
    do: Lifecycle.profile_search(context, query, opts)

  defp workspace_items(context, query, opts) do
    if opts[:memory_scope] == :operator,
      do: WorkspacePreferences.list(context.workspace_dir, query),
      else: {:ok, []}
  end

  defp query(params, operation) do
    value = Map.get(params, "query", "")

    if Lifecycle.valid_profile_query?(value) do
      value = String.trim(value)

      cond do
        value == "" and operation == "list" -> {:ok, ""}
        value == "" -> {:error, :invalid_query}
        true -> {:ok, value}
      end
    else
      {:error, :invalid_query}
    end
  end

  defp limit(params) do
    case Map.get(params, "limit", 25) do
      value when is_integer(value) and value in 1..50 -> {:ok, value}
      _ -> {:error, :invalid_limit}
    end
  end

  defp id(params) do
    value = Map.get(params, "id")

    if is_binary(value) and byte_size(value) <= 256 and Regex.match?(@id_pattern, value),
      do: {:ok, value},
      else: {:error, :invalid_document_id}
  end

  defp confirmation(params, id) do
    if Map.get(params, "confirm") == id, do: :ok, else: {:error, :confirmation_required}
  end

  defp cursor_offset(nil, _binding, _count), do: {:ok, 0}

  defp cursor_offset(cursor, binding, count)
       when is_binary(cursor) and byte_size(cursor) <= 512 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"snapshot" => ^binding, "offset" => offset} = decoded} <- Jason.decode(json),
         true <- map_size(decoded) == 2 and is_integer(offset) and offset > 0 and offset < count do
      {:ok, offset}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor_offset(_, _, _), do: {:error, :invalid_cursor}

  defp encode_cursor(binding, offset),
    do:
      Jason.encode!(%{"snapshot" => binding, "offset" => offset})
      |> Base.url_encode64(padding: false)

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
