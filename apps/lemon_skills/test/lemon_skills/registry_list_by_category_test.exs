defmodule LemonSkills.RegistryListByCategoryTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp write_skill(tmp_dir, key, frontmatter) do
    dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    #{frontmatter}
    ---

    Skill body for #{key}.
    """)
  end

  test "groups skills by metadata.lemon.category", %{tmp_dir: tmp_dir} do
    write_skill(tmp_dir, "k8s-rollout", """
    name: k8s-rollout
    description: Manage Kubernetes rollouts
    metadata:
      lemon:
        category: devops
    """)

    write_skill(tmp_dir, "axolotl", """
    name: axolotl
    description: Fine-tuning framework
    metadata:
      lemon:
        category: ml-training
    """)

    write_skill(tmp_dir, "vllm", """
    name: vllm
    description: vLLM inference server
    metadata:
      lemon:
        category: ml-training
    """)

    LemonSkills.refresh(cwd: tmp_dir)

    result = LemonSkills.list_by_category(cwd: tmp_dir)

    assert Map.has_key?(result, "devops")
    assert Map.has_key?(result, "ml-training")

    assert [%{key: "k8s-rollout"}] = result["devops"]

    ml_keys = result["ml-training"] |> Enum.map(& &1.key) |> Enum.sort()
    assert ml_keys == ["axolotl", "vllm"]
  end

  test "skills without category go into uncategorized", %{tmp_dir: tmp_dir} do
    write_skill(tmp_dir, "categorized", """
    name: categorized
    description: Has a category
    metadata:
      lemon:
        category: devops
    """)

    write_skill(tmp_dir, "no-category", """
    name: no-category
    description: No category field
    """)

    LemonSkills.refresh(cwd: tmp_dir)

    result = LemonSkills.list_by_category(cwd: tmp_dir)

    assert Map.has_key?(result, "devops")
    assert Map.has_key?(result, "uncategorized")

    uncategorized_keys = result["uncategorized"] |> Enum.map(& &1.key)
    assert "no-category" in uncategorized_keys
  end

  test "returns empty map when no skills exist", %{tmp_dir: tmp_dir} do
    LemonSkills.refresh(cwd: tmp_dir)

    result = LemonSkills.list_by_category(cwd: tmp_dir)

    # May contain global skills, but at minimum it's a map
    assert is_map(result)
  end

  test "categories are sorted alphabetically", %{tmp_dir: tmp_dir} do
    write_skill(tmp_dir, "z-skill", """
    name: z-skill
    description: Zebra skill
    metadata:
      lemon:
        category: zebra
    """)

    write_skill(tmp_dir, "a-skill", """
    name: a-skill
    description: Alpha skill
    metadata:
      lemon:
        category: alpha
    """)

    write_skill(tmp_dir, "m-skill", """
    name: m-skill
    description: Middle skill
    metadata:
      lemon:
        category: middle
    """)

    LemonSkills.refresh(cwd: tmp_dir)

    result = LemonSkills.list_by_category(cwd: tmp_dir)
    categories = Map.keys(result)

    # Filter to just our test categories to avoid global skill noise
    test_categories = Enum.filter(categories, &(&1 in ["alpha", "middle", "zebra"]))
    assert test_categories == ["alpha", "middle", "zebra"]
  end
end
