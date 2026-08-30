defmodule LemonSkills.Sources.Hermes do
  @moduledoc """
  Official Nous Research Hermes skill catalog and installer source.

  The catalog is discovered from the live `NousResearch/hermes-agent` GitHub
  tree. Identifiers have one of these forms:

      hermes:bundled/<category>/<skill>
      hermes:optional/<category>/<skill>

  Bundled and optional describe where Hermes ships the skill; both are
  third-party skill bundles from Lemon's perspective and therefore pass through
  Lemon's normal audit and approval pipeline before activation.
  """

  @behaviour LemonSkills.Source

  require Logger

  alias LemonCore.Secrets
  alias LemonSkills.{Entry, HttpClient, Manifest}

  @repo "NousResearch/hermes-agent"
  @branch "main"
  @clone_url "https://github.com/#{@repo}.git"
  @api_base "https://api.github.com"
  @raw_base "https://raw.githubusercontent.com"
  @user_agent "LemonAgent/1.0"

  @type catalog_entry :: %{
          id: String.t(),
          key: String.t(),
          name: String.t(),
          description: String.t(),
          category: String.t(),
          collection: String.t(),
          path: String.t(),
          sha: String.t() | nil
        }

  @doc "Return the current official Hermes skill catalog."
  @spec catalog(keyword()) :: {:ok, [catalog_entry()]} | {:error, term()}
  def catalog(opts \\ []) do
    with {:ok, entries} <- catalog_entries(opts) do
      entries =
        entries
        |> filter_collection(Keyword.get(opts, :collection))
        |> filter_category(Keyword.get(opts, :category))
        |> filter_query(Keyword.get(opts, :query, ""))
        |> maybe_load_details(opts)
        |> Enum.sort_by(&{&1.collection, &1.category, &1.name})

      {:ok, entries}
    end
  end

  @impl true
  def search(query, opts) do
    case catalog(Keyword.put(opts, :query, query)) do
      {:ok, entries} ->
        Enum.map(entries, &to_search_result/1)

      {:error, reason} ->
        Logger.warning("[Sources.Hermes] catalog search failed: #{inspect(reason)}")
        []
    end
  end

  @impl true
  def inspect(id, opts) when is_binary(id) do
    with {:ok, parsed} <- parse_id(id),
         {:ok, entries} <-
           catalog(
             opts
             |> Keyword.put(:collection, parsed.collection)
             |> Keyword.put(:category, parsed.category)
             |> Keyword.put(:details, true)
           ),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.id == parsed.id)) do
      {:ok, stringify_keys(entry)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(id, dest_dir, opts) when is_binary(id) do
    with {:ok, entry} <- parse_id(id) do
      case local_repo(opts) do
        path when is_binary(path) -> copy_skill(Path.join(path, entry.path), dest_dir)
        nil -> sparse_clone(entry.path, dest_dir, opts)
      end
    end
  end

  @impl true
  def upstream_hash(id, opts) when is_binary(id) do
    with {:ok, parsed} <- parse_id(id),
         {:ok, entries} <- catalog_entries(opts),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.id == parsed.id)) do
      if is_binary(entry.sha), do: {:ok, entry.sha}, else: {:error, :no_hash}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def trust_level, do: :official

  @doc false
  def parse_id("hermes:" <> ref) do
    case String.split(ref, "/", trim: true) do
      [collection | rest] when collection in ["bundled", "optional"] and length(rest) >= 1 ->
        if Enum.all?(rest, &safe_segment?/1) do
          root = if collection == "bundled", do: "skills", else: "optional-skills"
          key = List.last(rest)
          category = category_for(rest)
          path = Enum.join([root | rest], "/")

          {:ok,
           %{
             id: "hermes:#{collection}/#{Enum.join(rest, "/")}",
             key: key,
             name: key,
             description: "",
             category: category,
             collection: collection,
             path: path,
             sha: nil
           }}
        else
          {:error, :invalid_hermes_id}
        end

      _ ->
        {:error, :invalid_hermes_id}
    end
  end

  def parse_id(_), do: {:error, :invalid_hermes_id}

  defp catalog_entries(opts) do
    case local_repo(opts) do
      path when is_binary(path) -> catalog_from_local(path)
      nil -> catalog_from_github(opts)
    end
  end

  defp catalog_from_local(repo_path) do
    entries =
      ["skills", "optional-skills"]
      |> Enum.flat_map(fn root ->
        Path.wildcard(Path.join([repo_path, root, "**", "SKILL.md"]))
      end)
      |> Enum.flat_map(fn manifest_path ->
        rel = Path.relative_to(manifest_path, repo_path)

        case entry_from_manifest_path(rel, nil) do
          nil -> []
          entry -> [load_local_description(entry, manifest_path)]
        end
      end)

    {:ok, entries}
  end

  defp catalog_from_github(opts) do
    url = "#{@api_base}/repos/#{@repo}/git/trees/#{@branch}?recursive=1"

    with {:ok, body} <- HttpClient.impl().fetch(url, headers(opts)),
         {:ok, %{"tree" => tree}} when is_list(tree) <- Jason.decode(body) do
      entries =
        tree
        |> Enum.flat_map(fn node ->
          case node["type"] == "blob" && entry_from_manifest_path(node["path"], node["sha"]) do
            nil -> []
            false -> []
            entry -> [entry]
          end
        end)

      {:ok, entries}
    else
      {:ok, _} -> {:error, :invalid_catalog_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry_from_manifest_path(path, sha) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [root | rest] when root in ["skills", "optional-skills"] and length(rest) >= 2 ->
        if List.last(rest) == "SKILL.md" do
          skill_parts = Enum.drop(rest, -1)

          if Enum.all?(skill_parts, &safe_segment?/1) do
            key = List.last(skill_parts)
            category = category_for(skill_parts)
            collection = if root == "skills", do: "bundled", else: "optional"

            %{
              id: "hermes:#{collection}/#{Enum.join(skill_parts, "/")}",
              key: key,
              name: key,
              description: "",
              category: category,
              collection: collection,
              path: Enum.join([root | skill_parts], "/"),
              sha: sha
            }
          end
        end

      _ ->
        nil
    end
  end

  defp entry_from_manifest_path(_, _), do: nil

  defp maybe_load_details(entries, opts) do
    if Keyword.get(opts, :details, false) and is_nil(local_repo(opts)) do
      Enum.map(entries, &load_remote_description(&1, opts))
    else
      entries
    end
  end

  defp load_remote_description(entry, opts) do
    url = "#{@raw_base}/#{@repo}/#{@branch}/#{entry.path}/SKILL.md"

    case HttpClient.impl().fetch(url, headers(opts)) do
      {:ok, content} -> with_manifest_details(entry, content)
      {:error, _} -> entry
    end
  end

  defp load_local_description(entry, manifest_path) do
    case File.read(manifest_path) do
      {:ok, content} -> with_manifest_details(entry, content)
      {:error, _} -> entry
    end
  end

  defp with_manifest_details(entry, content) do
    case Manifest.parse(content) do
      {:ok, manifest, _body} ->
        %{
          entry
          | name: manifest["name"] || entry.name,
            description: manifest["description"] || ""
        }

      _ ->
        entry
    end
  end

  defp filter_collection(entries, nil), do: entries
  defp filter_collection(entries, "all"), do: entries
  defp filter_collection(entries, value), do: Enum.filter(entries, &(&1.collection == value))

  defp filter_category(entries, nil), do: entries
  defp filter_category(entries, ""), do: entries
  defp filter_category(entries, value), do: Enum.filter(entries, &(&1.category == value))

  defp filter_query(entries, query) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      entries
    else
      Enum.filter(entries, fn entry ->
        Enum.any?([entry.name, entry.key, entry.category, entry.description], fn value ->
          String.contains?(String.downcase(value || ""), query)
        end)
      end)
    end
  end

  defp to_search_result(entry) do
    manifest = %{"key" => entry.key, "name" => entry.name, "description" => entry.description}

    lemon_entry =
      Entry.from_manifest(manifest, entry.id,
        source: :hermes,
        source_kind: :git,
        trust_level: :official,
        metadata: %{"hermes_category" => entry.category, "hermes_collection" => entry.collection}
      )

    %{entry: lemon_entry, source: :hermes, validated: true, url: entry.id}
  end

  defp local_repo(opts) do
    candidate =
      Keyword.get(opts, :hermes_repo) || Application.get_env(:lemon_skills, :hermes_repo)

    if is_binary(candidate) and File.dir?(candidate), do: Path.expand(candidate), else: nil
  end

  defp copy_skill(source, dest_dir) do
    cond do
      not File.dir?(source) ->
        {:error, :not_found}

      true ->
        File.rm_rf(dest_dir)

        case File.cp_r(source, dest_dir) do
          {:ok, _} -> {:ok, dest_dir}
          {:error, reason, path} -> {:error, {:copy_failed, path, reason}}
        end
    end
  end

  defp sparse_clone(skill_path, dest_dir, opts) do
    temp = Path.join(System.tmp_dir!(), "lemon-hermes-#{System.unique_integer([:positive])}")
    branch = Keyword.get(opts, :branch, @branch)

    try do
      with {_out, 0} <-
             System.cmd(
               "git",
               [
                 "clone",
                 "--depth",
                 "1",
                 "--filter=blob:none",
                 "--sparse",
                 "--branch",
                 branch,
                 @clone_url,
                 temp
               ],
               stderr_to_stdout: true
             ),
           {_out, 0} <-
             System.cmd("git", ["-C", temp, "sparse-checkout", "set", "--no-cone", skill_path],
               stderr_to_stdout: true
             ) do
        copy_skill(Path.join(temp, skill_path), dest_dir)
      else
        {output, _code} -> {:error, {:clone_failed, String.trim(output)}}
      end
    after
      File.rm_rf(temp)
    end
  end

  defp headers(opts) do
    token = Keyword.get(opts, :github_token, Secrets.fetch_value("GITHUB_TOKEN"))
    base = [{"User-Agent", @user_agent}, {"Accept", "application/vnd.github+json"}]

    if is_binary(token) and token != "",
      do: [{"Authorization", "Bearer #{token}"} | base],
      else: base
  end

  defp safe_segment?(segment) do
    segment not in [".", ".."] and String.match?(segment, ~r/^[A-Za-z0-9._-]+$/)
  end

  defp category_for([_skill]), do: "other"
  defp category_for(parts), do: parts |> Enum.drop(-1) |> Enum.join("/")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
