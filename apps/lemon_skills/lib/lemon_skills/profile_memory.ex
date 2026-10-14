defmodule LemonSkills.ProfileMemory do
  @moduledoc """
  Destination-local profile memory interface for operator clients.

  `execute/4` derives paths from a validated profile ID; it never reads a profile
  configuration record or accepts a caller-provided workspace. The controller
  owns existence/placement validation. `:profile_opts` is passed to
  `LemonCore.ProfileStore.paths/2`; `:store` selects a memory Store server.

  Results contain only string-keyed JSON-safe projections. Sources are
  `workspace` (USER.md/MEMORY.md) and `durable` (run, learned-source, and project
  memory). Text is redacted and capped at 2048 bytes. IDs bind profile and
  revision; clients must refresh stale IDs before an exact-ID confirmed delete.
  Workspace timestamps describe the owning file, not individual note creation.

  List/search browse a bounded 200-record durable window and at most 200 entries
  per workspace file. Pages default to 25, at most 50. Opaque cursors bind the
  profile, query, and snapshot; changed snapshots invalidate them.
  """

  alias LemonCore.ProfileStore
  alias LemonMemory.{Lifecycle, Store}
  alias LemonSkills.WorkspacePreferences

  @operations ~w(list search get add delete)
  @id_pattern ~r/\A(?:durable_|pref_user_|pref_memory_)[A-Za-z0-9_.-]+\z/

  @spec execute(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def execute(operation, profile_id, params, opts \\ []) do
    with :ok <- validate_request(operation, params, opts),
         :ok <- validate_profile_id(profile_id),
         {:ok, paths} <- ProfileStore.paths(profile_id, Keyword.get(opts, :profile_opts, [])),
         :ok <- validate_profile_param(params, profile_id) do
      context = %{
        agent_id: profile_id,
        cwd: paths["workspace"],
        workspace_dir: paths["workspace"],
        session_scope: :main
      }

      case dispatch(operation, context, params, server: Keyword.get(opts, :store, Store)) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :memory_unavailable}
      end
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

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
      do: :ok, else: {:error, :invalid_id}
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
         {:ok, durable} <- Lifecycle.profile_list(context, query, opts),
         {:ok, preferences} <- WorkspacePreferences.list(context.workspace_dir, query) do

      items =
        (durable.items ++ preferences)
        |> Enum.sort_by(&{-&1["updatedAtMs"], &1["id"]})

      binding = digest(Jason.encode!([
        context.agent_id, Path.expand(context.workspace_dir), query,
        durable.revision, items
      ]))

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

  defp dispatch("add", context, params, _opts) do
    with {:ok, item} <- WorkspacePreferences.add(context.workspace_dir,
           Map.get(params, "kind", "memory"), Map.get(params, "text")) do
      {:ok, %{"item" => item}}
    end
  end

  defp dispatch("delete", context, params, opts) do
    with {:ok, id} <- id(params),
         :ok <- confirmation(params, id) do
      delete_item(context, id, opts)
    end
  end

  defp get_item(context, "durable_" <> _ = id, opts),
    do: Lifecycle.profile_get(context, id, opts)

  defp get_item(context, id, _opts), do: WorkspacePreferences.get(context.workspace_dir, id)

  defp delete_item(context, "durable_" <> _ = id, opts) do
    with {:ok, preview} <- Lifecycle.profile_preview_delete(context, id, opts) do
      Lifecycle.profile_delete(context, id, preview.confirmation_digest, opts)
    end
  end

  defp delete_item(context, id, _opts) do
    with {:ok, preview} <- WorkspacePreferences.preview_delete(context.workspace_dir, id) do
      WorkspacePreferences.delete(context.workspace_dir, id, preview.revision)
    end
  end

  defp query(params, operation) do
    value = Map.get(params, "query", "")

    if is_binary(value) and byte_size(value) <= 256 and String.valid?(value) and
         not String.contains?(value, <<0>>) do
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
      do: {:ok, value}, else: {:error, :invalid_document_id}
  end

  defp confirmation(params, id) do
    if Map.get(params, "confirm") == id,
      do: :ok, else: {:error, :confirmation_required}
  end

  defp cursor_offset(nil, _binding, _count), do: {:ok, 0}
  defp cursor_offset(cursor, binding, count) when is_binary(cursor) and byte_size(cursor) <= 512 do
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
    do: Jason.encode!(%{"snapshot" => binding, "offset" => offset}) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
