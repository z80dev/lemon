defmodule LemonMemory.Project do
  @moduledoc """
  Compact coding learnings in the existing durable memory store.

  One document is shared by sessions of the same agent, assistant home, and
  repository root. Repository subdirectories share the nearest `.git` ancestor;
  non-repository directories remain separate. Subagents never read or mutate
  this memory. Recall is a bounded local read, not a model or network call.
  """

  alias LemonMemory.{Document, Query, Safety, Store}

  @max_facts 24
  @max_bytes 2_000
  @max_fact_bytes 512
  @unsafe_controls ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u
  @injection ~r/ignore (all )?(previous|prior|above) instructions|disregard (all )?(previous|prior|above) instructions|system prompt|developer message|<\|\/?(?:system|developer|assistant|user)\|>/iu

  @doc "Resolve a repository/agent/assistant-home identity; never accepts an unscoped child."
  def scope(context) when is_map(context) do
    with :main <- Map.get(context, :session_scope),
         cwd when is_binary(cwd) and cwd != "" <- Map.get(context, :cwd),
         home when is_binary(home) and home != "" <- Map.get(context, :workspace_dir),
         agent when is_binary(agent) and agent != "" <- Map.get(context, :agent_id),
         true <- String.trim(cwd) != "" and String.trim(home) != "" and String.trim(agent) != "" do
      root = repository_root(Path.expand(cwd))
      home_digest = digest(Path.expand(home))
      key = digest(Jason.encode!([agent, home_digest, root]))
      {:ok, %{key: key, root: root, home_digest: home_digest, agent_id: agent}}
    else
      :subagent -> {:error, :subagent}
      _ -> {:error, :unscoped}
    end
  end

  def scope(_), do: {:error, :unscoped}

  @doc "Bind finalized history to a trusted profile or the canonical default assistant home."
  def history_metadata(meta) when is_map(meta) do
    case Map.get(meta, "home_digest") || Map.get(meta, :home_digest) do
      digest when is_binary(digest) and digest != "" ->
        Map.put(meta, "home_digest", digest)

      _ ->
        profile_id = Map.get(meta, :profile_id) || Map.get(meta, "profile_id")

        home =
          if profile_id == nil do
            agent_dir = System.get_env("LEMON_AGENT_DIR") || LemonCore.Paths.home_path("agent")
            Path.join(agent_dir, "workspace")
          else
            case LemonCore.ProfileStore.paths(profile_id) do
              {:ok, %{"workspace" => workspace}} -> workspace
              _ -> nil
            end
          end

        if home, do: Map.put(meta, "home_digest", digest(Path.expand(home))), else: meta
    end
  end

  def history_metadata(_), do: history_metadata(%{})

  @doc "Filter history before recall; project facts are read through their exact identity instead."
  def history_document?(doc, context, scope \\ :agent)

  def history_document?(%Document{} = doc, context, requested_scope) do
    with {:ok, identity} <- scope(context),
         meta when is_map(meta) <- doc.meta,
         false <- (meta["kind"] || meta[:kind]) == "project_learning",
         true <- doc.agent_id == identity.agent_id,
         true <- (meta["home_digest"] || meta[:home_digest]) == identity.home_digest do
      case requested_scope do
        :agent ->
          true

        :workspace ->
          is_binary(doc.workspace_key) and
            repository_root(Path.expand(doc.workspace_key)) == identity.root

        :project ->
          is_binary(doc.workspace_key) and
            repository_root(Path.expand(doc.workspace_key)) == identity.root

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  def history_document?(_, _, _), do: false

  @doc "Check an operator profile boundary, including project learnings across repositories."
  def profile_document?(%Document{} = doc, context) do
    with {:ok, identity} <- scope(context),
         meta when is_map(meta) <- doc.meta do
      doc.agent_id == identity.agent_id and
        (meta["home_digest"] || meta[:home_digest]) == identity.home_digest
    else
      _ -> false
    end
  end

  def profile_document?(_, _), do: false
  @doc "Read at most 24 facts/2000 bytes from this exact project and profile."
  def read(context, opts \\ []) do
    with {:ok, scope} <- scope(context) do
      load(Keyword.get(opts, :store, Store), scope)
    end
  end

  @doc "Add, replace, or delete one exact project fact, rejecting capacity overflow."
  def remember(context, text, replaces \\ nil, opts \\ []) do
    with {:ok, scope} <- scope(context),
         {:ok, text} <- optional_fact(text),
         {:ok, replaces} <- optional_fact(replaces),
         true <- text != nil or replaces != nil do
      mutate(context, scope, opts, fn facts ->
        cond do
          replaces == nil -> {:ok, Enum.uniq(facts ++ [text])}
          replaces not in facts -> {:error, :not_found}
          text == nil -> {:ok, List.delete(facts, replaces)}
          true -> {:ok, facts |> Enum.map(&if(&1 == replaces, do: text, else: &1)) |> Enum.uniq()}
        end
      end)
    else
      false -> {:error, :empty_fact}
      error -> error
    end
  end

  @doc "Merge safe captured facts, retaining the most recent bounded project learnings."
  def capture(context, facts, opts \\ [])

  def capture(context, facts, opts) when is_list(facts) do
    with {:ok, scope} <- scope(context) do
      facts =
        facts
        |> Enum.take(@max_facts)
        |> Enum.flat_map(fn fact ->
          case normalize_fact(fact) do
            {:ok, fact} -> [fact]
            _ -> []
          end
        end)

      mutate(context, scope, opts, fn previous ->
        {:ok, bounded(Enum.uniq(facts ++ previous))}
      end)
    end
  end

  def capture(_, _, _), do: {:error, :invalid_facts}

  @doc "Lexically search this project's compact learnings without an LLM call."
  def search(context, query, opts \\ []) do
    terms = Query.terms(query)

    limit =
      case Keyword.get(opts, :limit, 5) do
        value when is_integer(value) -> value |> max(1) |> min(10)
        _ -> 5
      end

    with [_ | _] <- terms,
         {:ok, facts} <- read(context, opts) do
      facts
      |> Enum.map(&{Query.shared_term_count(terms, &1), &1})
      |> Enum.filter(fn {score, _} -> score > 0 end)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    else
      _ -> []
    end
  end

  defp mutate(context, scope, opts, fun) do
    server = Keyword.get(opts, :store, Store)
    session_key = Map.get(context, :session_key)

    if is_binary(session_key) and session_key != "" do
      :global.trans({{__MODULE__, server, scope.key}, self()}, fn ->
        with {:ok, previous} <- load(server, scope),
             {:ok, facts} <- fun.(previous),
             true <- fits?(facts) do
          if facts == previous do
            {:ok, %{changed: false, facts: facts}}
          else
            with :ok <- persist(server, scope, context, facts) do
              {:ok, %{changed: true, facts: facts}}
            end
          end
        else
          false -> {:error, :capacity_exceeded}
          error -> error
        end
      end)
    else
      {:error, :unscoped}
    end
  end

  defp load(server, scope) do
    case Store.get_document(server, document_id(scope)) do
      {:ok, %Document{} = doc} ->
        facts = String.split(doc.answer_summary, "\n", trim: true)

        if doc.agent_id == scope.agent_id and doc.workspace_key == scope.root and
             doc.meta["home_digest"] == scope.home_digest and fits?(facts) and
             Enum.all?(facts, &(normalize_fact(&1) == {:ok, &1})) do
          {:ok, facts}
        else
          {:error, :invalid_document}
        end

      {:error, :not_found} ->
        {:ok, []}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  defp persist(server, scope, _context, []) do
    case Store.delete_document(server, document_id(scope)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp persist(server, scope, context, facts) do
    doc =
      Document.new(
        doc_id: document_id(scope),
        session_key: Map.fetch!(context, :session_key),
        agent_id: scope.agent_id,
        workspace_key: scope.root,
        scope: :workspace,
        prompt_summary: "Project coding learnings: build commands, conventions, and gotchas",
        answer_summary: Enum.join(facts, "\n"),
        outcome: :success,
        meta: %{"kind" => "project_learning", "home_digest" => scope.home_digest}
      )

    case Store.put_sync(server, doc) do
      :ok -> :ok
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp optional_fact(nil), do: {:ok, nil}
  defp optional_fact(fact), do: normalize_fact(fact)

  defp normalize_fact(fact) when is_binary(fact) do
    cond do
      not String.valid?(fact) or byte_size(fact) > @max_bytes ->
        {:error, :invalid_fact}

      Regex.match?(@unsafe_controls, fact) or Regex.match?(@injection, fact) ->
        {:error, :unsafe_fact}

      Safety.contains_secret?(fact) ->
        {:error, :unsafe_fact}

      true ->
        fact = fact |> String.split() |> Enum.join(" ")

        cond do
          fact == "" -> {:error, :empty_fact}
          byte_size(fact) > @max_fact_bytes -> {:error, :fact_too_long}
          true -> {:ok, fact}
        end
    end
  end

  defp normalize_fact(_), do: {:error, :invalid_fact}

  defp bounded(facts) do
    facts
    |> Enum.take(@max_facts)
    |> Enum.reduce({[], 0}, fn fact, {kept, bytes} ->
      size = byte_size(fact) + if(kept == [], do: 0, else: 1)
      if bytes + size <= @max_bytes, do: {[fact | kept], bytes + size}, else: {kept, bytes}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp fits?(facts),
    do: length(facts) <= @max_facts and byte_size(Enum.join(facts, "\n")) <= @max_bytes

  defp document_id(scope), do: "mem_project_" <> scope.key
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp repository_root(cwd), do: find_repository(cwd) || cwd

  defp find_repository(path) do
    cond do
      File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git")) -> path
      Path.dirname(path) == path -> nil
      true -> find_repository(Path.dirname(path))
    end
  end
end
