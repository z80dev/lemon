defmodule LemonSkills.DiscoveryTest do
  @moduledoc """
  Tests for the LemonSkills.Discovery module.

  These tests verify that online skill discovery works correctly,
  including GitHub search, URL validation, and result deduplication.

  Note: Many tests are skipped in the test environment because the HTTP
  client (:httpc) requires the :http_util module which is not available
  in test mode. These tests can be run manually in a live environment.
  """

  use ExUnit.Case, async: false

  alias LemonSkills.Discovery

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

    @tag :skip
    test "returns results within timeout" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("test", timeout: 5_000, max_results: 5)

      # Should return a list (may be empty if GitHub is unavailable)
      assert is_list(results)
      assert length(results) <= 5
    end

    @tag :skip
    test "respects max_results option" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("github", timeout: 5_000, max_results: 3)
      assert length(results) <= 3
    end

    @tag :skip
    test "returns results with correct structure" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("test", timeout: 5_000, max_results: 1)

      if length(results) > 0 do
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
  end

  # ============================================================================
  # validate_skill/1 Tests
  # ============================================================================

  describe "validate_skill/1" do
    @tag :skip
    test "returns nil for invalid URL" do
      # Skipped: requires HTTP client in test environment
      result = Discovery.validate_skill("https://invalid.example.com/nonexistent")
      assert result == nil
    end

    @tag :skip
    test "returns nil for non-existent skill" do
      # Skipped: requires HTTP client in test environment
      result = Discovery.validate_skill("https://raw.githubusercontent.com/nonexistent/repo/main/SKILL.md")
      assert result == nil
    end

    @tag :skip
    test "handles malformed URLs gracefully" do
      # Skipped: requires HTTP client in test environment
      result = Discovery.validate_skill("not-a-valid-url")
      assert result == nil
    end
  end

  # ============================================================================
  # Scoring Tests
  # ============================================================================

  describe "scoring" do
    @tag :skip
    test "results are sorted by discovery score" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("github", timeout: 5_000, max_results: 5)

      if length(results) >= 2 do
        scores = Enum.map(results, fn r ->
          get_in(r.entry.manifest, ["_discovery_metadata", "discovery_score"]) || 0
        end)
        assert scores == Enum.sort(scores, :desc)
      end
    end

    @tag :skip
    test "higher star counts contribute to higher scores" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("api", timeout: 5_000, max_results: 10)

      if length(results) >= 2 do
        # Check that entries with more stars tend to have higher scores
        star_score_pairs =
          Enum.map(results, fn r ->
            stars = get_in(r.entry.manifest, ["_discovery_metadata", "github_stars"]) || 0
            score = get_in(r.entry.manifest, ["_discovery_metadata", "discovery_score"]) || 0
            {stars, score}
          end)

        # The highest starred entry should generally be near the top
        {max_stars, _} = Enum.max_by(star_score_pairs, fn {s, _} -> s end)
        {_, max_score} = Enum.max_by(star_score_pairs, fn {_, s} -> s end)

        # Entry with max stars should have a reasonably high score
        {max_star_entry_score, _} =
          Enum.find(star_score_pairs, fn {s, _} -> s == max_stars end)

        assert max_star_entry_score >= max_score * 0.5
      end
    end
  end

  # ============================================================================
  # Deduplication Tests
  # ============================================================================

  describe "deduplication" do
    @tag :skip
    test "results do not contain duplicate URLs" do
      # Skipped: requires HTTP client in test environment
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
    @tag :skip
    test "handles network timeouts gracefully" do
      # Skipped: requires HTTP client in test environment
      # Use a very short timeout to force timeout errors
      results = Discovery.discover("test", timeout: 1, max_results: 5)

      # Should return empty list or partial results, not crash
      assert is_list(results)
    end

    @tag :skip
    test "handles missing GitHub token gracefully" do
      # Skipped: requires HTTP client in test environment
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
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("github", timeout: 10_000, max_results: 5)

      # Should find at least one result for a common term
      if length(results) > 0 do
        # Check that results have GitHub-related metadata
        first = hd(results)
        assert first.source == :github
        assert is_number(get_in(first.entry.manifest, ["_discovery_metadata", "github_stars"]))
        assert is_binary(get_in(first.entry.manifest, ["_discovery_metadata", "github_url"]))
      end
    end

    @tag :integration
    test "entry structure is complete" do
      # Skipped: requires HTTP client in test environment
      results = Discovery.discover("api", timeout: 10_000, max_results: 3)

      for result <- results do
        entry = result.entry

        # Required fields
        assert is_binary(entry.key)
        assert is_binary(entry.name)
        assert is_binary(entry.description)
        assert is_binary(entry.path)

        # Metadata stored in manifest
        assert is_map(entry.manifest)
        assert is_number(get_in(entry.manifest, ["_discovery_metadata", "discovery_score"]))
      end
    end
  end
end
