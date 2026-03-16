defmodule LemonSkills.ManifestTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Manifest
  alias LemonSkills.Manifest.{Parser, Validator}

  describe "parse/1" do
    test "parses content with YAML frontmatter" do
      content = """
      ---
      name: test-skill
      description: A test skill for testing
      ---

      ## Usage

      This is the skill content.
      """

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest["name"] == "test-skill"
      assert manifest["description"] == "A test skill for testing"
      assert String.contains?(body, "This is the skill content")
    end

    test "parses frontmatter with list values" do
      content = """
      ---
      name: k8s-skill
      description: Kubernetes operations
      requires:
        bins:
          - kubectl
          - helm
        config:
          - KUBECONFIG
      ---

      Content here.
      """

      assert {:ok, manifest, _body} = Manifest.parse(content)
      assert manifest["name"] == "k8s-skill"
      assert Manifest.required_bins(manifest) == ["kubectl", "helm"]
      assert Manifest.required_config(manifest) == ["KUBECONFIG"]
    end

    test "parses content without frontmatter" do
      content = """
      # Just Markdown

      No frontmatter here, just content.
      """

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest == %{}
      assert String.contains?(body, "Just Markdown")
    end

    test "handles empty frontmatter" do
      content = """
      ---
      ---

      Body content only.
      """

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest == %{}
      assert String.contains?(body, "Body content only")
    end

    test "handles frontmatter with no body" do
      content = """
      ---
      name: minimal
      description: Minimal skill
      ---
      """

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest["name"] == "minimal"
      assert body == ""
    end

    test "returns error for unclosed frontmatter" do
      content = """
      ---
      name: broken
      This never closes
      """

      assert :error = Manifest.parse(content)
    end

    test "handles CRLF line endings" do
      content = "---\r\nname: crlf-skill\r\ndescription: Windows style\r\n---\r\n\r\nBody here."

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest["name"] == "crlf-skill"
      assert String.contains?(body, "Body here")
    end

    test "parses TOML frontmatter" do
      content = """
      +++
      name = "toml-skill"
      description = "Using TOML"
      +++

      TOML body content.
      """

      assert {:ok, manifest, body} = Manifest.parse(content)
      assert manifest["name"] == "toml-skill"
      assert manifest["description"] == "Using TOML"
      assert String.contains?(body, "TOML body content")
    end

    test "parses TOML arrays" do
      content = """
      +++
      name = "toml-arrays"
      tags = ["elixir", "testing"]
      +++

      Content.
      """

      assert {:ok, manifest, _body} = Manifest.parse(content)
      assert manifest["tags"] == ["elixir", "testing"]
    end

    test "handles comments in YAML" do
      content = """
      ---
      # This is a comment
      name: commented-skill
      # Another comment
      description: Has comments
      ---

      Body.
      """

      assert {:ok, manifest, _body} = Manifest.parse(content)
      assert manifest["name"] == "commented-skill"
      assert manifest["description"] == "Has comments"
    end
  end

  describe "parse_frontmatter/1" do
    test "returns only the manifest" do
      content = """
      ---
      name: frontmatter-only
      description: Test
      ---

      Body is ignored.
      """

      assert {:ok, manifest} = Manifest.parse_frontmatter(content)
      assert manifest["name"] == "frontmatter-only"
    end

    test "returns error for invalid content" do
      assert :error = Manifest.parse_frontmatter("---\nunclosed")
    end
  end

  describe "parse_body/1" do
    test "returns only the body" do
      content = """
      ---
      name: ignored
      ---

      Only this body.
      """

      body = Manifest.parse_body(content)
      assert body == "Only this body."
    end

    test "returns full content when no frontmatter" do
      content = "Just plain content"
      assert Manifest.parse_body(content) == content
    end
  end

  describe "validate/1" do
    test "validates empty manifest" do
      assert {:ok, _} = Manifest.validate(%{})
    end

    test "validates manifest with proper requires" do
      manifest = %{
        "name" => "valid",
        "requires" => %{
          "bins" => ["git"],
          "config" => ["API_KEY"]
        }
      }

      assert {:ok, _} = Manifest.validate(manifest)
    end

    test "rejects non-map requires" do
      manifest = %{"requires" => "invalid"}
      assert {:error, _} = Manifest.validate(manifest)
    end

    test "rejects non-list tags" do
      manifest = %{"tags" => "not-a-list"}
      assert {:error, _} = Manifest.validate(manifest)
    end
  end

  describe "required_bins/1" do
    test "returns empty list when no requires" do
      assert Manifest.required_bins(%{}) == []
    end

    test "returns empty list when no bins" do
      assert Manifest.required_bins(%{"requires" => %{}}) == []
    end

    test "returns bins list" do
      manifest = %{"requires" => %{"bins" => ["git", "npm"]}}
      assert Manifest.required_bins(manifest) == ["git", "npm"]
    end
  end

  describe "required_config/1" do
    test "returns empty list when no requires" do
      assert Manifest.required_config(%{}) == []
    end

    test "returns config list" do
      manifest = %{"requires" => %{"config" => ["API_KEY", "SECRET"]}}
      assert Manifest.required_config(manifest) == ["API_KEY", "SECRET"]
    end
  end

  # ---------------------------------------------------------------------------
  # v2 field accessors
  # ---------------------------------------------------------------------------

  describe "validate/1 - v2 defaults" do
    test "returns ok with defaults for empty manifest" do
      assert {:ok, normalised} = Manifest.validate(%{})
      assert normalised["platforms"] == ["any"]
      assert normalised["requires_tools"] == []
      assert normalised["fallback_for_tools"] == []
      assert normalised["required_environment_variables"] == []
      assert normalised["references"] == []
    end

    test "promotes requires.config into required_environment_variables" do
      manifest = %{"requires" => %{"config" => ["MY_TOKEN"]}}
      assert {:ok, normalised} = Manifest.validate(manifest)
      assert normalised["required_environment_variables"] == ["MY_TOKEN"]
    end

    test "does not overwrite explicit required_environment_variables" do
      manifest = %{
        "requires" => %{"config" => ["LEGACY"]},
        "required_environment_variables" => ["EXPLICIT"]
      }

      assert {:ok, normalised} = Manifest.validate(manifest)
      assert normalised["required_environment_variables"] == ["EXPLICIT"]
    end

    test "accepts valid platforms" do
      manifest = %{"platforms" => ["linux", "darwin"]}
      assert {:ok, normalised} = Manifest.validate(manifest)
      assert normalised["platforms"] == ["linux", "darwin"]
    end

    test "rejects unknown platform values" do
      assert {:error, msg} = Manifest.validate(%{"platforms" => ["fooOS"]})
      assert msg =~ "unknown values"
    end

    test "rejects non-list platforms" do
      assert {:error, _} = Manifest.validate(%{"platforms" => "linux"})
    end

    test "accepts valid verification map" do
      manifest = %{"verification" => %{"command" => "kubectl version", "expect_exit" => "0"}}
      assert {:ok, _} = Manifest.validate(manifest)
    end

    test "rejects non-map verification" do
      assert {:error, _} = Manifest.validate(%{"verification" => "bad"})
    end

    test "accepts string references" do
      manifest = %{"references" => ["path/to/file.md"]}
      assert {:ok, normalised} = Manifest.validate(manifest)
      assert normalised["references"] == ["path/to/file.md"]
    end

    test "accepts map references with path key" do
      manifest = %{"references" => [%{"path" => "examples/deploy.md"}]}
      assert {:ok, _} = Manifest.validate(manifest)
    end

    test "accepts map references with url key" do
      manifest = %{"references" => [%{"url" => "https://example.com/docs"}]}
      assert {:ok, _} = Manifest.validate(manifest)
    end

    test "rejects invalid reference entries" do
      manifest = %{"references" => [%{"not_a_key" => "value"}]}
      assert {:error, _} = Manifest.validate(manifest)
    end

    test "rejects non-list references" do
      assert {:error, _} = Manifest.validate(%{"references" => "bad"})
    end

    test "rejects non-list requires_tools" do
      assert {:error, _} = Manifest.validate(%{"requires_tools" => "kubectl"})
    end
  end

  describe "version/1" do
    test "returns :v1 for legacy manifest" do
      manifest = %{"name" => "old", "requires" => %{"bins" => ["git"]}}
      assert Manifest.version(manifest) == :v1
    end

    test "returns :v2 when platforms present" do
      assert Manifest.version(%{"platforms" => ["linux"]}) == :v2
    end

    test "returns :v2 when requires_tools present" do
      assert Manifest.version(%{"requires_tools" => []}) == :v2
    end

    test "returns :v2 when metadata.lemon present" do
      manifest = %{"metadata" => %{"lemon" => %{"category" => "devops"}}}
      assert Manifest.version(manifest) == :v2
    end
  end

  describe "platforms/1" do
    test "returns any for legacy manifest" do
      assert Manifest.platforms(%{}) == ["any"]
    end

    test "returns declared platforms" do
      assert Manifest.platforms(%{"platforms" => ["linux", "darwin"]}) == ["linux", "darwin"]
    end
  end

  describe "required_environment_variables/1" do
    test "returns empty list when absent" do
      assert Manifest.required_environment_variables(%{}) == []
    end

    test "falls back to requires.config" do
      manifest = %{"requires" => %{"config" => ["TOKEN"]}}
      assert Manifest.required_environment_variables(manifest) == ["TOKEN"]
    end

    test "prefers explicit field over legacy" do
      manifest = %{
        "required_environment_variables" => ["EXPLICIT"],
        "requires" => %{"config" => ["LEGACY"]}
      }

      assert Manifest.required_environment_variables(manifest) == ["EXPLICIT"]
    end
  end

  describe "lemon_category/1" do
    test "returns nil when absent" do
      assert Manifest.lemon_category(%{}) == nil
    end

    test "returns category when present" do
      manifest = %{"metadata" => %{"lemon" => %{"category" => "devops"}}}
      assert Manifest.lemon_category(manifest) == "devops"
    end
  end

  describe "references/1" do
    test "returns empty list when absent" do
      assert Manifest.references(%{}) == []
    end

    test "returns references list" do
      manifest = %{"references" => ["path/to/file.md"]}
      assert Manifest.references(manifest) == ["path/to/file.md"]
    end
  end

  # ---------------------------------------------------------------------------
  # Parser module direct tests
  # ---------------------------------------------------------------------------

  describe "Parser.parse/1" do
    test "delegates correctly from Manifest.parse/1" do
      content = "---\nname: x\n---\nbody"
      assert {:ok, m, b} = Parser.parse(content)
      assert m["name"] == "x"
      assert b == "body"
    end
  end

  # ---------------------------------------------------------------------------
  # Validator module direct tests
  # ---------------------------------------------------------------------------

  describe "Validator.validate/1" do
    test "validates legacy manifest without v2 fields" do
      manifest = %{"name" => "old-skill", "description" => "A skill", "requires" => %{"bins" => ["git"]}}
      assert {:ok, _} = Validator.validate(manifest)
    end
  end
end
