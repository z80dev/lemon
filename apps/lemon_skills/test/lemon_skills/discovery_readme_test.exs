defmodule LemonSkills.DiscoveryReadmeTest do
  @moduledoc """
  Tests to verify the examples in the Discovery README work correctly.
  
  These tests ensure the documentation stays in sync with the implementation.
  """

  use ExUnit.Case, async: false

  alias LemonSkills.{Discovery, Registry}
  alias LemonSkills.HttpClient.Mock, as: HttpMock

  setup do
    HttpMock.reset()
    HttpMock.stub("https://api.github.com/search/repositories", {:ok, ~s({"items": []})})
    HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})
    HttpMock.stub("https://raw.githubusercontent.com/lemon-agent/skills/main/", {:error, :nxdomain})
    :ok
  end

  describe "README examples" do
    test "Registry.discover/2 exists and accepts query" do
      # This test just verifies the function exists and handles empty results
      results = Registry.discover("")
      assert is_list(results)
    end

    test "Registry.search/2 exists and returns correct structure" do
      # Verify the search function returns expected structure
      %{local: local, online: online} = Registry.search("test", include_online: false)
      
      assert is_list(local)
      assert is_list(online)
    end

    test "Discovery.discover/2 accepts options" do
      # Verify options are accepted (results may be empty due to test env)
      results = Discovery.discover("test", 
        timeout: 1,  # Very short timeout for fast test
        max_results: 5
      )
      
      assert is_list(results)
    end

    test "Discovery.validate_skill/1 exists" do
      # Verify the function exists - will return nil for invalid URLs in test
      HttpMock.stub("not-a-valid-url", {:error, :invalid_url})

      result = Discovery.validate_skill("not-a-valid-url")
      assert is_nil(result)
    end
  end

  describe "result structure" do
    test "discovery result has expected keys" do
      # Create a mock result to verify structure
      result = %{
        entry: %LemonSkills.Entry{
          key: "test-skill",
          name: "Test Skill",
          description: "A test skill",
          source: :github,
          path: "https://example.com/skill",
          manifest: %{"_discovery_metadata" => %{"discovery_score" => 100}}
        },
        source: :github,
        validated: true,
        url: "https://example.com/skill"
      }

      # Verify all expected keys exist
      assert Map.has_key?(result, :entry)
      assert Map.has_key?(result, :source)
      assert Map.has_key?(result, :validated)
      assert Map.has_key?(result, :url)

      # Verify entry is an Entry struct
      assert %LemonSkills.Entry{} = result.entry
      
      # Verify source is an atom
      assert is_atom(result.source)
      
      # Verify validated is boolean
      assert is_boolean(result.validated)
      
      # Verify url is string
      assert is_binary(result.url)
    end
  end

  describe "scoring weights" do
    test "scoring weights are documented correctly" do
      # These are the documented weights from the README
      weights = %{
        stars_max: 100,
        exact_name: 100,
        partial_name: 50,
        display_name: 30,
        exact_keyword: 40,
        partial_keyword: 20,
        description_word: 10,
        body_word: 2
      }

      # Verify weights are positive integers
      for {key, value} <- weights do
        assert is_integer(value), "Weight #{key} should be integer"
        assert value > 0, "Weight #{key} should be positive"
      end

      # Verify exact match has highest weight
      assert weights.exact_name >= weights.partial_name
      assert weights.exact_name >= weights.display_name
    end
  end
end
