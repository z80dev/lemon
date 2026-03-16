defmodule LemonSkills.Sources.Github do
  @moduledoc """
  Source for skills discovered via the GitHub API.

  Uses the GitHub search API to find repositories tagged with the
  `lemon-skill` topic, then delegates cloning to `Sources.Git`.

  ## Identifier

  The canonical identifier is `"<owner>/<repo>"` (without the `https://github.com/`
  prefix). The router accepts the `"gh:<owner>/<repo>"` shorthand and strips the
  prefix before passing the id to this module.

  ## Trust

  Skills discovered via GitHub carry `:community` trust (same as `:git`) since
  they originate from third-party repositories.
  """

  @behaviour LemonSkills.Source

  require Logger

  alias LemonCore.Secrets
  alias LemonSkills.{Entry, HttpClient, Manifest, Sources.Git}

  @github_api_base "https://api.github.com"
  @raw_base "https://raw.githubusercontent.com"
  @user_agent "LemonAgent/1.0"
  @default_per_page 10

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def search(query, opts) do
    token = Keyword.get(opts, :github_token, Secrets.fetch_value("GITHUB_TOKEN"))
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    search_query = "topic:lemon-skill #{query} in:name,description,readme"
    encoded = URI.encode_www_form(search_query)

    url =
      "#{@github_api_base}/search/repositories?q=#{encoded}&sort=stars&order=desc&per_page=#{per_page}"

    headers = build_headers(token)

    case HttpClient.impl().fetch(url, headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"items" => items}} when is_list(items) ->
            Enum.flat_map(items, &repo_to_result(&1, query))

          _ ->
            []
        end

      {:error, reason} ->
        Logger.warning("[Sources.Github] search failed: #{inspect(reason)}")
        []
    end
  end

  @impl true
  def inspect(owner_repo, opts) when is_binary(owner_repo) do
    token = Keyword.get(opts, :github_token, Secrets.fetch_value("GITHUB_TOKEN"))
    url = "#{@github_api_base}/repos/#{owner_repo}"
    headers = build_headers(token)

    case HttpClient.impl().fetch(url, headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, info} -> {:ok, info}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch(owner_repo, dest_dir, opts) when is_binary(owner_repo) do
    clone_url = "https://github.com/#{owner_repo}.git"
    Git.fetch(clone_url, dest_dir, opts)
  end

  @impl true
  def upstream_hash(owner_repo, opts) when is_binary(owner_repo) do
    clone_url = "https://github.com/#{owner_repo}.git"
    Git.upstream_hash(clone_url, opts)
  end

  @impl true
  def trust_level, do: :community

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_headers(nil),
    do: [{"User-Agent", @user_agent}, {"Accept", "application/vnd.github.v3+json"}]

  defp build_headers(token) do
    [{"Authorization", "token #{token} "} | build_headers(nil)]
  end

  defp repo_to_result(repo, query) do
    full_name = repo["full_name"] || ""
    repo_url = repo["html_url"] || ""
    description = repo["description"] || ""
    stars = repo["stargazers_count"] || 0

    # Build raw URL for SKILL.md (try main branch)
    skill_url = skill_md_url(full_name)

    score = relevance_score(full_name, description, query, stars)

    manifest = %{
      "key" => String.replace(full_name, "/", "-"),
      "name" => repo["name"] || full_name,
      "description" => description
    }

    entry =
      Entry.from_manifest(manifest, skill_url,
        source: :github,
        source_kind: :git,
        trust_level: :community,
        metadata: %{
          "discovery_score" => score,
          "github_stars" => stars,
          "github_url" => repo_url
        }
      )

    [%{entry: entry, source: :github, validated: false, url: skill_url}]
  end

  defp skill_md_url(full_name) do
    "#{@raw_base}/#{full_name}/main/SKILL.md"
  end

  defp relevance_score(name, description, query, stars) do
    base = min(stars, 100)
    query_lower = String.downcase(query)

    name_boost = if String.contains?(String.downcase(name), query_lower), do: 50, else: 0
    desc_boost = if String.contains?(String.downcase(description), query_lower), do: 20, else: 0

    base + name_boost + desc_boost
  end

  @doc """
  Fetch the `SKILL.md` content from a GitHub repo's default branch.

  Returns `{:ok, manifest, body}` or `{:error, reason}`.
  """
  @spec fetch_manifest(String.t(), keyword()) :: {:ok, map(), String.t()} | {:error, term()}
  def fetch_manifest(owner_repo, opts \\ []) when is_binary(owner_repo) do
    token = Keyword.get(opts, :github_token, Secrets.fetch_value("GITHUB_TOKEN"))
    url = skill_md_url(owner_repo)
    headers = build_headers(token)

    case HttpClient.impl().fetch(url, headers) do
      {:ok, body} ->
        case Manifest.parse_and_validate(body) do
          {:ok, manifest, md_body} -> {:ok, manifest, md_body}
          {:error, reason} -> {:error, {:invalid_manifest, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
