defmodule LemonSkills.Synthesis.DraftStoreTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Synthesis.DraftStore

  setup do
    dir = System.tmp_dir!() |> Path.join("draft_store_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, tmp: dir}
  end

  defp opts(ctx), do: [global: false, cwd: ctx.tmp]

  defp sample_draft(key \\ "synth-deploy-k8s") do
    %{
      key: key,
      name: "Deploy K8s",
      content: "---\nname: \"Deploy K8s\"\n---\n\n# Deploy K8s\nDeploys to Kubernetes.",
      source_doc_id: "doc-abc123"
    }
  end

  describe "put/2" do
    test "writes SKILL.md and .draft_meta.json", ctx do
      draft = sample_draft()
      assert :ok = DraftStore.put(draft, opts(ctx))

      dir = DraftStore.draft_dir(draft.key, opts(ctx))
      assert File.regular?(Path.join(dir, "SKILL.md"))
      assert File.regular?(Path.join(dir, ".draft_meta.json"))
    end

    test "SKILL.md contains the draft content", ctx do
      draft = sample_draft()
      DraftStore.put(draft, opts(ctx))
      dir = DraftStore.draft_dir(draft.key, opts(ctx))
      content = File.read!(Path.join(dir, "SKILL.md"))
      assert content == draft.content
    end

    test "meta file contains source_doc_id", ctx do
      draft = sample_draft()
      DraftStore.put(draft, opts(ctx))
      dir = DraftStore.draft_dir(draft.key, opts(ctx))
      meta = Jason.decode!(File.read!(Path.join(dir, ".draft_meta.json")))
      assert meta["source_doc_id"] == "doc-abc123"
    end

    test "returns error if draft already exists and force is false", ctx do
      DraftStore.put(sample_draft(), opts(ctx))
      assert {:error, msg} = DraftStore.put(sample_draft(), opts(ctx))
      assert msg =~ "already exists"
    end

    test "overwrites with force: true", ctx do
      DraftStore.put(sample_draft(), opts(ctx))
      updated = %{sample_draft() | content: "---\nname: \"Updated\"\n---\n\nUpdated content."}
      assert :ok = DraftStore.put(updated, Keyword.put(opts(ctx), :force, true))

      {:ok, stored} = DraftStore.get("synth-deploy-k8s", opts(ctx))
      assert stored.content =~ "Updated content"
    end

    test "returns error when key is missing", ctx do
      assert {:error, _} = DraftStore.put(%{content: "..."}, opts(ctx))
    end

    test "returns error when content is missing", ctx do
      assert {:error, _} = DraftStore.put(%{key: "synth-foo"}, opts(ctx))
    end
  end

  describe "list/1" do
    test "returns empty list when no drafts exist", ctx do
      assert {:ok, []} = DraftStore.list(opts(ctx))
    end

    test "returns all draft entries", ctx do
      DraftStore.put(sample_draft("synth-one"), opts(ctx))
      DraftStore.put(sample_draft("synth-two"), opts(ctx))
      {:ok, drafts} = DraftStore.list(opts(ctx))
      keys = Enum.map(drafts, & &1.key)
      assert "synth-one" in keys
      assert "synth-two" in keys
    end

    test "each entry has expected fields", ctx do
      DraftStore.put(sample_draft(), opts(ctx))
      {:ok, [draft_info | _]} = DraftStore.list(opts(ctx))
      assert Map.has_key?(draft_info, :key)
      assert Map.has_key?(draft_info, :path)
      assert Map.has_key?(draft_info, :created_at)
      assert Map.has_key?(draft_info, :has_skill_file)
    end

    test "has_skill_file is true when SKILL.md present", ctx do
      DraftStore.put(sample_draft(), opts(ctx))
      {:ok, [draft_info | _]} = DraftStore.list(opts(ctx))
      assert draft_info.has_skill_file == true
    end
  end

  describe "get/2" do
    test "returns draft content and meta", ctx do
      draft = sample_draft()
      DraftStore.put(draft, opts(ctx))
      {:ok, result} = DraftStore.get(draft.key, opts(ctx))
      assert result.content == draft.content
      assert result.meta["source_doc_id"] == "doc-abc123"
    end

    test "returns {:error, :not_found} for missing draft", ctx do
      assert {:error, :not_found} = DraftStore.get("nonexistent", opts(ctx))
    end
  end

  describe "delete/2" do
    test "removes the draft directory", ctx do
      draft = sample_draft()
      DraftStore.put(draft, opts(ctx))
      dir = DraftStore.draft_dir(draft.key, opts(ctx))
      assert File.dir?(dir)

      assert :ok = DraftStore.delete(draft.key, opts(ctx))
      refute File.dir?(dir)
    end

    test "returns ok even if draft does not exist", ctx do
      assert :ok = DraftStore.delete("nonexistent", opts(ctx))
    end

    test "draft no longer listed after deletion", ctx do
      draft = sample_draft()
      DraftStore.put(draft, opts(ctx))
      DraftStore.delete(draft.key, opts(ctx))
      {:ok, drafts} = DraftStore.list(opts(ctx))
      refute Enum.any?(drafts, fn d -> d.key == draft.key end)
    end
  end
end
