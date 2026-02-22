defmodule LemonSkills.Discovery do
  @moduledoc """
  Online skill discovery for finding skills not in the local registry.

  Inspired by Ironclaw's extension discovery system, this module provides
  multi-tier search for skills:

  1. Search GitHub repositories with "lemon-skill" or "lemon-agent-skill" topics
  2. Probe well-known URL patterns for skill registries
  3. Validate discovered skills via SKILL.md manifest

  All sources run concurrently with per-source timeouts.

  ## Usage

      # Discover skills matching a query
      results = LemonSkills.Discovery.discover("github")

      # Each result is a skill entry that can be installed
      [%LemonSkills.Entry{}, ...]

  ## Configuration

  Configure discovery sources in `~/.lemon/config.toml`:

      [skills.discovery]
      enabled = true
      github_token = "${GITHUB_TOKEN}"  # Optional, for higher rate limits
      timeout_ms = 10000

  ## HTTP Client

  The HTTP layer is abstracted behind `LemonSkills.HttpClient`. The default
  implementation (`LemonSkills.HttpClient.Httpc`) uses Erlang's `:httpc`.
  Override via application config to inject a mock for testing:

      config :lemon_skills, :http_client, LemonSkills.HttpClient.Mock
  """

  require Logger

  alias LemonSkills.{Entry, HttpClient, Manifest}

  @default_timeout_ms 10_000
  @user_agent "LemonAgent/1.0"

  @typedoc "Discovery result with metadata"
  @type discovery_result :: %{
          entry: Entry.t(),
          source: :github | :registry | :url,
          validated: boolean(),
          url: String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Run the full discovery pipeline for a query.

  Searches multiple sources concurrently, deduplicates, validates,
  and returns skill entries that can be installed.

  ## Parameters

  - `query` - Search query string (e.g., "github", "web search")

  ## Options

  - `:timeout` - Overall timeout in milliseconds (default: 10000)
  - `:github_token` - GitHub personal access token for higher rate limits
  - `:max_results` - Maximum results to return (default: 10)

  ## Returns

  List of discovery results, sorted by relevance score.
  """
  @spec discover(String.t(), keyword()) :: [discovery_result()]
  def discover(query, opts \\ []) when is_binary(query) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    max_results = Keyword.get(opts, :max_results, 10)

    query_clean = String.trim(String.downcase(query))

    if query_clean == "" do
      []
    else
      # Run all discovery sources concurrently
      tasks = [
        Task.async(fn -> search_github(query_clean, opts) end),
        Task.async(fn -> probe_registry_urls(query_clean, opts) end)
      ]

      # Collect results with timeout
      results =
        tasks
        |> Task.yield_many(timeout)
        |> Enum.flat_map(fn {_task, result} ->
          case result do
            {:ok, entries} -> entries
            _ -> []
          end
        end)

      # Deduplicate by URL
      deduplicated = deduplicate_by_url(results)

      # Sort by relevance and limit results
      deduplicated
      |> Enum.sort_by(fn result ->
        # Get score from manifest's discovery metadata
        get_in(result.entry.manifest, ["_discovery_metadata", "discovery_score"]) || 0
      end, :desc)
      |> Enum.take(max_results)
    end
  end

  @doc """
  Validate a discovered skill by fetching and parsing its SKILL.md.

  Returns the entry if valid, nil otherwise.
  """
  @spec validate_skill(String.t()) :: Entry.t() | nil
  def validate_skill(url) do
    case fetch_skill_manifest(url) do
      {:ok, manifest} ->
        # Validate that the manifest has required fields
        if valid_manifest?(manifest) do
          Entry.from_manifest(manifest, url)
        else
          Logger.warning("Invalid skill manifest at #{url}: missing required fields")
          nil
        end

      {:error, reason} ->
        Logger.debug("Failed to validate skill at #{url}: #{inspect(reason)}")
        nil
    end
  end

  # Validate that a manifest has the minimum required fields
  defp valid_manifest?(manifest) when is_map(manifest) do
    # Must have at least a name or key
    has_name = is_binary(Map.get(manifest, "name")) and Map.get(manifest, "name") != ""
    has_key = is_binary(Map.get(manifest, "key")) and Map.get(manifest, "key") != ""

    has_name or has_key
  end

  defp valid_manifest?(_), do: false

  # ============================================================================
  # GitHub Discovery
  # ============================================================================

  defp search_github(query, opts) do
    token = Keyword.get(opts, :github_token, System.get_env("GITHUB_TOKEN"))

    # Build search query for repositories with lemon-skill topic
    search_query = build_github_search_query(query)

    headers = [
      {"User-Agent", @user_agent},
      {"Accept", "application/vnd.github.v3+json"}
    ]

    headers =
      if token do
        [{"Authorization", "token #{token}"} | headers]
      else
        headers
      end

    url = "https://api.github.com/search/repositories?q=#{URI.encode_www_form(search_query)}&sort=stars&order=desc&per_page=10"

    case fetch_json(url, headers) do
      {:ok, %{"items" => items}} when is_list(items) ->
        Enum.flat_map(items, fn repo ->
          parse_github_repo(repo, query)
        end)

      {:ok, _} ->
        []

      {:error, reason} ->
        Logger.warning("GitHub search failed: #{inspect(reason)}")
        []
    end
  end

  defp build_github_search_query(query) do
    # Search for repos with lemon-skill topic and query in name/description
    "topic:lemon-skill #{query} in:name,description,readme"
  end

  defp parse_github_repo(repo, query) do
    repo_name = repo["full_name"] || ""
    repo_url = repo["html_url"] || ""
    description = repo["description"] || ""
    stars = repo["stargazers_count"] || 0

    # Calculate relevance score based on stars and match quality
    score = calculate_github_score(repo_name, description, query, stars)

    # Construct raw URL for SKILL.md
    skill_url = construct_skill_url(repo_url)

    [
      %{
        entry: Entry.from_manifest(
          %{
            "key" => String.replace(repo_name, "/", "-"),
            "name" => repo["name"] || repo_name,
            "description" => description
          },
          skill_url,
          source: :github,
          metadata: %{
            "discovery_score" => score,
            "github_stars" => stars,
            "github_url" => repo_url
          }
        ),
        source: :github,
        validated: false,
        url: skill_url
      }
    ]
  end

  defp construct_skill_url(repo_url) do
    # Convert GitHub repo URL to raw SKILL.md URL
    # https://github.com/user/repo -> https://raw.githubusercontent.com/user/repo/main/SKILL.md
    repo_url
    |> String.replace("github.com", "raw.githubusercontent.com")
    |> Kernel.<>("/main/SKILL.md")
  end

  defp calculate_github_score(name, description, query, stars) do
    score = min(stars, 100)  # Cap stars contribution at 100

    query_lower = String.downcase(query)
    name_lower = String.downcase(name)
    desc_lower = String.downcase(description)

    # Boost for exact name match
    score =
      if String.contains?(name_lower, query_lower) do
        score + 50
      else
        score
      end

    # Boost for description match
    score =
      if String.contains?(desc_lower, query_lower) do
        score + 20
      else
        score
      end

    score
  end

  # ============================================================================
  # Registry URL Discovery
  # ============================================================================

  defp probe_registry_urls(query, _opts) do
    # Probe well-known patterns for skill registries
    patterns = [
      "https://skills.lemon.agent/#{query}",
      "https://raw.githubusercontent.com/lemon-agent/skills/main/#{query}/SKILL.md"
    ]

    # Try each pattern concurrently
    tasks = Enum.map(patterns, fn url ->
      Task.async(fn ->
        case validate_skill(url) do
          nil -> []
          entry ->
            [
              %{
                entry: entry,
                source: :registry,
                validated: true,
                url: url
              }
            ]
        end
      end)
    end)

    # Collect results with 5 second timeout per pattern
    tasks
    |> Task.yield_many(5_000)
    |> Enum.flat_map(fn {_task, result} ->
      case result do
        {:ok, entries} -> entries
        _ -> []
      end
    end)
  end

  # ============================================================================
  # HTTP Helpers
  # ============================================================================

  defp fetch_json(url, headers) do
    case fetch(url, headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_skill_manifest(url) do
    case fetch(url, [{"User-Agent", @user_agent}]) do
      {:ok, body} ->
        case Manifest.parse(body) do
          {:ok, manifest, _body} -> {:ok, manifest}
          :error -> {:error, :invalid_manifest}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(url, headers) do
    HttpClient.impl().fetch(url, headers)
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  defp deduplicate_by_url(results) do
    {unique, _seen} =
      Enum.reduce(results, {[], MapSet.new()}, fn result, {acc, seen} ->
        url = result.url

        if MapSet.member?(seen, url) do
          {acc, seen}
        else
          {[result | acc], MapSet.put(seen, url)}
        end
      end)

    Enum.reverse(unique)
  end
end
