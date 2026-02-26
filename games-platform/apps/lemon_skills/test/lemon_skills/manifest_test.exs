defmodule LemonSkills.ManifestTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Manifest

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
      assert :ok = Manifest.validate(%{})
    end

    test "validates manifest with proper requires" do
      manifest = %{
        "name" => "valid",
        "requires" => %{
          "bins" => ["git"],
          "config" => ["API_KEY"]
        }
      }

      assert :ok = Manifest.validate(manifest)
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
end
