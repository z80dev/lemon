defmodule LemonSkills.AgentSkillsConformanceTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Manifest, Registry}

  @fixtures Path.expand("../fixtures/agentskills", __DIR__)

  @moduletag :tmp_dir

  test "spec optional fields and resource directories survive project discovery", %{tmp_dir: cwd} do
    root = Path.join(cwd, ".agents/skills")
    File.mkdir_p!(root)
    File.cp_r!(Path.join(@fixtures, "pdf-processing"), Path.join(root, "pdf-processing"))

    assert {:ok, entry} = Registry.get("pdf-processing", cwd: cwd)
    manifest = entry.manifest
    assert manifest["name"] == "pdf-processing"
    assert manifest["description"] == "Extract PDF text and merge files. Use when handling PDFs."
    assert manifest["license"] == "Apache-2.0"
    assert manifest["compatibility"] == "Requires Python 3.14+ and uv"

    assert manifest["metadata"] == %{
             "author" => "example-org",
             "version" => "1.0",
             "lemon" => "portable-string-value"
           }

    assert manifest["allowed-tools"] == "Bash(git:*) Bash(jq:*) Read"

    for resource <- ["scripts/extract.sh", "references/REFERENCE.md", "assets/template.txt"] do
      assert File.read!(Path.join(entry.path, resource)) ==
               File.read!(Path.join([@fixtures, "pdf-processing", resource]))
    end
  end

  test "minimal skills and specification character boundaries parse unchanged" do
    for name <- ["a", "pdf-processing", "data-analysis", "code-review", String.duplicate("a", 64)],
        description <- ["Use for PDFs.", String.duplicate("é", 1024)] do
      content = "---\nname: #{name}\ndescription: #{description}\n---\n# Instructions"
      assert {:ok, manifest, "# Instructions"} = Manifest.parse_and_validate(content)
      assert manifest["name"] == name
      assert manifest["description"] == description
    end
  end

  test "legacy name leniency includes spec-invalid names without crashing" do
    for name <- [
          "PDF-Processing",
          "-pdf",
          "pdf-",
          "pdf--processing",
          "pdf_processing",
          String.duplicate("a", 65)
        ] do
      assert {:ok, manifest, _} =
               Manifest.parse_and_validate(
                 "---\nname: #{name}\ndescription: Use for PDFs.\n---\nBody"
               )

      assert manifest["name"] == name
    end

    assert {:ok, _, _} = Manifest.parse_and_validate("No frontmatter")
    assert {:ok, _, _} = Manifest.parse_and_validate("---\nname: legacy\n---\nBody")
  end

  test "directory mismatch is deliberately lenient", %{tmp_dir: cwd} do
    dir = Path.join(cwd, ".agents/skills/directory-name")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: different-name\ndescription: Use for PDFs.\n---\nBody"
    )

    assert {:ok, entry} = Registry.get("directory-name", cwd: cwd)
    assert entry.manifest["name"] == "different-name"
  end

  test "malformed required fields and YAML fail safely" do
    for content <- [
          "---\nname: [broken\n---\nBody",
          "---\nname: pdf\ndescription: ''\n---\nBody",
          "---\nname: 42\ndescription: Use for PDFs.\n---\nBody",
          "---\nname: pdf\ndescription: [not, a, string]\n---\nBody",
          "---\nname: pdf\nmetadata: []\n---\nBody",
          "---\nname: pdf\ndescription: #{String.duplicate("a", 1025)}\n---\nBody"
        ] do
      assert {:error, _} = Manifest.parse_and_validate(content)
    end
  end

  test "experimental and advisory values are retained, not interpreted as permissions" do
    manifest = %{
      "name" => "pdf",
      "description" => "Use for PDFs.",
      "compatibility" => String.duplicate("x", 501),
      "allowed-tools" => ["Read"],
      "metadata" => %{"custom" => %{"nested" => true}}
    }

    assert {:ok, normalized} = Manifest.validate(manifest)
    assert Map.take(normalized, Map.keys(manifest)) == manifest
  end
end
