defmodule LemonSkills.DiscoveryTest do
  @moduledoc """
  Tests for the LemonSkills.Discovery module.

  These tests verify that online skill discovery works correctly,
  including GitHub search, URL validation, and result deduplication.

  All HTTP calls are handled by `LemonSkills.HttpClient.Mock`, configured
  in test_helper.exs, so no real network access is required.
  """

  use ExUnit.Case, async: false

  alias LemonSkills.Discovery
  alias LemonSkills.HttpClient.Mock, as: HttpMock

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  @github_search_one_result Jason.encode!(%{
                              "items" => [
                                %{
                                  "full_name" => "acme/lemon-skill-hello",
                                  "html_url" => "https://github.com/acme/lemon-skill-hello",
                                  "name" => "lemon-skill-hello",
                                  "description" => "A greeting skill for Lemon",
                                  "stargazers_count" => 42
                                }
                              ]
                            })

  @github_search_multi_result Jason.encode!(%{
                                "items" => [
                                  %{
                                    "full_name" => "acme/lemon-skill-alpha",
                                    "html_url" => "https://github.com/acme/lemon-skill-alpha",
                                    "name" => "lemon-skill-alpha",
                                    "description" => "Alpha skill",
                                    "stargazers_count" => 100
                                  },
                                  %{
                                    "full_name" => "acme/lemon-skill-beta",
                                    "html_url" => "https://github.com/acme/lemon-skill-beta",
                                    "name" => "lemon-skill-beta",
                                    "description" => "Beta skill",
                                    "stargazers_count" => 50
                                  },
                                  %{
                                    "full_name" => "acme/lemon-skill-gamma",
                                    "html_url" => "https://github.com/acme/lemon-skill-gamma",
                                    "name" => "lemon-skill-gamma",
                                    "description" => "Gamma skill",
                                    "stargazers_count" => 10
                                  }
                                ]
                              })

  @github_search_empty Jason.encode!(%{"items" => []})

  @valid_skill_md """
  ---
  name: hello-skill
  description: A test skill
  ---

  ## When to use

  Use for testing.
  """

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    HttpMock.reset()
    :ok
  end

  # ============================================================================
  # discover/2 Tests
  # ============================================================================

  describe "discover/2" do
    test "returns empty list for empty query" do
      results = Discovery.discover("")
      assert results == []
    end

    test "returns empty list for whitespace-only query" do
      results = Discovery.discover("   ")
      assert results == []
    end

    test "returns results within timeout" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok, @github_search_one_result}
      )

      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("test", timeout: 5_000, max_results: 5)

      assert is_list(results)
      assert length(results) <= 5
      assert length(results) >= 1
    end

    test "respects max_results option" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok, @github_search_multi_result}
      )

      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("github", timeout: 5_000, max_results: 2)
      assert length(results) <= 2
    end

    test "returns results with correct structure" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok, @github_search_one_result}
      )

      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("test", timeout: 5_000, max_results: 1)

      assert length(results) > 0
      [first | _] = results

      # Check structure
      assert is_map(first)
      assert Map.has_key?(first, :entry)
      assert Map.has_key?(first, :source)
      assert Map.has_key?(first, :validated)
      assert Map.has_key?(first, :url)

      # Source should be an atom
      assert is_atom(first.source)
      assert first.source in [:github, :registry, :url]

      # Validated should be boolean
      assert is_boolean(first.validated)

      # URL should be string
      assert is_binary(first.url)
    end
  end

  # ============================================================================
  # validate_skill/1 Tests
  # ============================================================================

  describe "validate_skill/1" do
    test "returns nil for invalid URL" do
      HttpMock.stub("https://invalid.example.com/nonexistent", {:error, :nxdomain})

      result = Discovery.validate_skill("https://invalid.example.com/nonexistent")
      assert result == nil
    end

    test "returns nil for non-existent skill" do
      HttpMock.stub(
        "https://raw.githubusercontent.com/nonexistent/repo/main/SKILL.md",
        {:error, {:http_error, 404}}
      )

      result =
        Discovery.validate_skill(
          "https://raw.githubusercontent.com/nonexistent/repo/main/SKILL.md"
        )

      assert result == nil
    end

    test "handles malformed URLs gracefully" do
      HttpMock.stub("not-a-valid-url", {:error, :invalid_url})

      result = Discovery.validate_skill("not-a-valid-url")
      assert result == nil
    end

    test "returns entry for valid SKILL.md" do
      HttpMock.stub(
        "https://raw.githubusercontent.com/acme/skill/main/SKILL.md",
        {:ok, @valid_skill_md}
      )

      result =
        Discovery.validate_skill("https://raw.githubusercontent.com/acme/skill/main/SKILL.md")

      assert result != nil
      assert result.name == "hello-skill"
      assert result.description == "A test skill"
    end
  end

  # ============================================================================
  # Scoring Tests
  # ============================================================================

  describe "scoring" do
    test "results are sorted by discovery score" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok, @github_search_multi_result}
      )

      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("github", timeout: 5_000, max_results: 5)

      if length(results) >= 2 do
        scores =
          Enum.map(results, fn r ->
            get_in(r.entry.manifest, ["_discovery_metadata", "discovery_score"]) || 0
          end)

        assert scores == Enum.sort(scores, :desc)
      end
    end

    test "higher star counts contribute to higher scores" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok, @github_search_multi_result}
      )

      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("api", timeout: 5_000, max_results: 10)

      assert length(results) >= 2

      star_score_pairs =
        Enum.map(results, fn r ->
          stars = get_in(r.entry.manifest, ["_discovery_metadata", "github_stars"]) || 0
          score = get_in(r.entry.manifest, ["_discovery_metadata", "discovery_score"]) || 0
          {stars, score}
        end)

      # The highest starred entry should have the highest score
      {max_stars, _} = Enum.max_by(star_score_pairs, fn {s, _} -> s end)
      {_, max_score} = Enum.max_by(star_score_pairs, fn {_, s} -> s end)

      # Entry with max stars should have a reasonably high score
      {_, max_star_entry_score} =
        Enum.find(star_score_pairs, fn {s, _} -> s == max_stars end)

      assert max_star_entry_score >= max_score * 0.5
    end
  end

  # ============================================================================
  # Deduplication Tests
  # ============================================================================

  describe "deduplication" do
    test "results do not contain duplicate URLs" do
      # Return items that would produce duplicate URLs
      duplicate_items =
        Jason.encode!(%{
          "items" => [
            %{
              "full_name" => "acme/lemon-skill-test",
              "html_url" => "https://github.com/acme/lemon-skill-test",
              "name" => "lemon-skill-test",
              "description" => "Test skill",
              "stargazers_count" => 5
            },
            %{
              "full_name" => "other/lemon-skill-test2",
              "html_url" => "https://github.com/other/lemon-skill-test2",
              "name" => "lemon-skill-test2",
              "description" => "Test skill 2",
              "stargazers_count" => 3
            }
          ]
        })

      HttpMock.stub("https://api.github.com/search/repositories", {:ok, duplicate_items})
      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("test", timeout: 5_000, max_results: 20)

      urls = Enum.map(results, fn r -> r.url end)
      unique_urls = Enum.uniq(urls)

      assert length(urls) == length(unique_urls)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles network timeouts gracefully" do
      # Stub all sources to return timeout errors
      HttpMock.stub("https://api.github.com/search/repositories", {:error, :timeout})
      HttpMock.stub("https://skills.lemon.agent/", {:error, :timeout})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :timeout}
      )

      results = Discovery.discover("test", timeout: 5_000, max_results: 5)

      # Should return empty list, not crash
      assert is_list(results)
      assert results == []
    end

    test "handles missing GitHub token gracefully" do
      # Stub GitHub to return an auth error (simulating no token)
      HttpMock.stub("https://api.github.com/search/repositories", {:error, {:http_error, 403}})
      HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})

      HttpMock.stub(
        "https://raw.githubusercontent.com/lemon-agent/skills/main/",
        {:error, :nxdomain}
      )

      results = Discovery.discover("test", timeout: 5_000, max_results: 3)
      assert is_list(results)
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration" do
    @tag :integration
    test "can discover GitHub-related skills" do
      results = Discovery.discover("github", timeout: 10_000, max_results: 5)

      if length(results) > 0 do
        first = hd(results)
        assert first.source == :github
        assert is_number(get_in(first.entry.manifest, ["_discovery_metadata", "github_stars"]))
        assert is_binary(get_in(first.entry.manifest, ["_discovery_metadata", "github_url"]))
      end
    end

    @tag :integration
    test "entry structure is complete" do
      results = Discovery.discover("api", timeout: 10_000, max_results: 3)

      for result <- results do
        entry = result.entry

        assert is_binary(entry.key)
        assert is_binary(entry.name)
        assert is_binary(entry.description)
        assert is_binary(entry.path)

        assert is_map(entry.manifest)
        assert is_number(get_in(entry.manifest, ["_discovery_metadata", "discovery_score"]))
      end
    end
  end
end
