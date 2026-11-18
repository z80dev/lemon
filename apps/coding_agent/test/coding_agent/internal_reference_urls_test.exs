defmodule CodingAgent.InternalReferenceUrlsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Artifacts, InternalUrls}
  alias LemonSkills.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    env = %{
      "LEMON_AGENT_DIR" => Path.join(tmp_dir, "agent"),
      "LEMON_HARNESS_SKILLS_DIR" => Path.join(tmp_dir, "harness")
    }

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    System.put_env(env)
    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(cwd)
    LemonSkills.refresh(cwd: cwd)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      LemonSkills.refresh(cwd: cwd)
    end)

    %{cwd: cwd}
  end

  test "classifies recognized schemes without treating filesystem paths as URLs", %{cwd: cwd} do
    for uri <- ["skill://Example", "artifact://abc", "skill:", "artifact:/abc", "SKILL://Example"] do
      assert InternalUrls.internal_url?(uri)
    end

    for path <- [
          "SKILL.md",
          "references/guide.md",
          "/tmp/skill://Example",
          "notes:2026",
          "./skill:notes"
        ] do
      refute InternalUrls.internal_url?(path)
      assert {:error, :unknown_protocol} = InternalUrls.resolve(path, cwd: cwd)
    end

    refute InternalUrls.internal_url?(nil)
    refute InternalUrls.internal_url?("https://example.com")
    assert {:error, :unknown_protocol} = InternalUrls.resolve("https://example.com", cwd: cwd)
  end

  test "resolves the bare bundle and project-over-global precedence", %{cwd: cwd} do
    global = create_skill(Config.global_skills_dir(), "SameKey", "global")
    project = create_skill(Config.project_skills_dir(cwd), "SameKey", "project")
    global_only = create_skill(Config.global_skills_dir(), "GlobalOnly", "global only")
    authorize_skill!(global, :global)
    authorize_skill!(project, {:project, cwd})
    authorize_skill!(global_only, :global)
    LemonSkills.refresh(cwd: cwd)

    assert {:ok, path} = InternalUrls.resolve("skill://SameKey", cwd: cwd)
    assert path == Path.join(project, "SKILL.md")
    assert File.read!(path) =~ "project"
    assert path != Path.join(global, "SKILL.md")

    assert {:ok, path} = InternalUrls.resolve("skill://GlobalOnly", cwd: cwd)
    assert path == Path.join(global_only, "SKILL.md")
    assert {:error, "Skill not found"} = InternalUrls.resolve("skill://samekey", cwd: cwd)
  end

  test "resolves case-preserving bundle files with literal or encoded spaces", %{cwd: cwd} do
    bundle = create_skill(Config.project_skills_dir(cwd), "CaseKey")
    reference = Path.join(bundle, "references/Nested/Usage Guide.md")
    File.mkdir_p!(Path.dirname(reference))
    File.write!(reference, "reference")
    authorize_skill!(bundle, {:project, cwd})
    LemonSkills.refresh(cwd: cwd)

    assert {:ok, reference} ==
             InternalUrls.resolve("skill://CaseKey/references/Nested/Usage Guide.md", cwd: cwd)

    assert {:ok, reference} ==
             InternalUrls.resolve("skill://CaseKey/references/Nested/Usage%20Guide.md", cwd: cwd)

    assert {:ok, Path.join(bundle, "SKILL.md")} ==
             InternalUrls.resolve("skill://CaseKey/SKILL.md", cwd: cwd)
  end

  test "rejects malformed recognized URLs", %{cwd: cwd} do
    for uri <- [
          "skill:",
          "skill:/demo",
          "SKILL://demo",
          "skill://",
          "skill:///demo",
          "skill://demo/",
          "skill://user@demo",
          "skill://demo:80",
          "skill://demo?query",
          "skill://demo#fragment",
          "skill://demo/file?query",
          "skill://demo/file#fragment",
          "skill://demo/%",
          "skill://demo/%2",
          "skill://demo/%GG",
          "skill://demo/%FF",
          "skill://demo/line\nbreak",
          "skill://demo/%00",
          "skill://demo/%7F",
          "skill://demo/%3Fquery",
          "skill://demo/%23fragment",
          "skill://demo/\u202Ehidden",
          "artifact:",
          "artifact:/abc"
        ] do
      assert {:error, error} = InternalUrls.resolve(uri, cwd: cwd), uri
      assert is_binary(error)
    end
  end

  test "rejects traversal and absolute relative paths before lookup", %{cwd: cwd} do
    for relative <- [
          "..",
          ".",
          "../outside",
          "references/../../outside",
          "%2e%2e/outside",
          "%2E%2E/outside",
          "%252e%252e/outside",
          "%2e%2e%2foutside",
          "references/%2e%2e/outside",
          "/etc/passwd",
          "%2Fetc/passwd",
          "references//file",
          "C:/outside",
          "C%3A/outside",
          "..\\outside",
          "%5Coutside"
        ] do
      assert {:error, _} = InternalUrls.resolve("skill://demo/" <> relative, cwd: cwd), relative
    end

    assert {:error, _} = InternalUrls.resolve("skill://%2e%2e/SKILL.md", cwd: cwd)
    assert {:error, _} = InternalUrls.resolve("skill://%2Ftmp/SKILL.md", cwd: cwd)
  end

  test "reports missing skills, missing files and directory references", %{cwd: cwd} do
    bundle = create_skill(Config.project_skills_dir(cwd), "demo")
    File.mkdir_p!(Path.join(bundle, "references"))
    authorize_skill!(bundle, {:project, cwd})
    LemonSkills.refresh(cwd: cwd)

    assert {:error, "Skill not found"} = InternalUrls.resolve("skill://absent", cwd: cwd)

    assert {:error, "Skill file not found"} =
             InternalUrls.resolve("skill://demo/missing", cwd: cwd)

    assert {:error, "Skill URL must reference a regular file"} =
             InternalUrls.resolve("skill://demo/references", cwd: cwd)
  end

  test "refuses disabled skills but reads skills that only miss requirements", %{cwd: cwd} do
    disabled = create_skill(Config.project_skills_dir(cwd), "disabled")

    not_ready =
      create_skill(
        Config.project_skills_dir(cwd),
        "not-ready",
        "body",
        "requires:\n  bins:\n    - lemon-internal-urls-nonexistent-binary"
      )

    authorize_skill!(disabled, {:project, cwd})
    authorize_skill!(not_ready, {:project, cwd})
    assert :ok = Config.save_config(%{"disabled" => ["disabled"]}, false, cwd)
    LemonSkills.refresh(cwd: cwd)

    assert {:error, "Skill is disabled, blocked or not authorized for its current content"} =
             InternalUrls.resolve("skill://disabled", cwd: cwd)

    assert {:ok, Path.join(not_ready, "SKILL.md")} ==
             InternalUrls.resolve("skill://not-ready", cwd: cwd)
  end

  test "rejects file and directory symlinks beneath the bundle", %{cwd: cwd, tmp_dir: tmp_dir} do
    bundle = create_skill(Config.project_skills_dir(cwd), "demo")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.md"), "outside")
    File.write!(Path.join(bundle, "inside.md"), "inside")
    File.ln_s!(Path.join(outside, "secret.md"), Path.join(bundle, "escape.md"))
    File.ln_s!(outside, Path.join(bundle, "references"))
    File.ln_s!(Path.join(bundle, "inside.md"), Path.join(bundle, "linked.md"))
    authorize_skill!(bundle, {:project, cwd})
    LemonSkills.refresh(cwd: cwd)

    for path <- ["escape.md", "references/secret.md", "linked.md"] do
      assert {:error, "Symlinks beneath a skill bundle are not allowed"} =
               InternalUrls.resolve("skill://demo/" <> path, cwd: cwd)
    end
  end

  test "rejects a symlinked SKILL.md", %{cwd: cwd, tmp_dir: tmp_dir} do
    bundle = Path.join(Config.project_skills_dir(cwd), "demo")
    source = create_skill(tmp_dir, "source")
    File.mkdir_p!(bundle)
    File.ln_s!(Path.join(source, "SKILL.md"), Path.join(bundle, "SKILL.md"))
    LemonSkills.refresh(cwd: cwd)

    # A symlinked SKILL.md is never read, so the bundle is not registered.
    assert {:error, "Skill not found"} =
             InternalUrls.resolve("skill://demo", cwd: cwd)
  end

  test "permits a linked bundle root in a user-owned global root only", %{
    cwd: cwd,
    tmp_dir: tmp_dir
  } do
    source = create_skill(tmp_dir, "source")
    global_root = Config.global_skills_dir()
    File.mkdir_p!(global_root)
    linked = Path.join(global_root, "linked")
    File.ln_s!(source, linked)
    project_root = Config.project_skills_dir(cwd)
    File.mkdir_p!(project_root)
    File.ln_s!(source, Path.join(project_root, "repo-linked"))
    authorize_skill!(linked, :global)
    authorize_skill!(Path.join(project_root, "repo-linked"), {:project, cwd})
    LemonSkills.refresh()
    LemonSkills.refresh(cwd: cwd)

    assert {:ok, Path.join(linked, "SKILL.md")} ==
             InternalUrls.resolve("skill://linked", cwd: cwd)

    assert {:error, "Skill not found"} = InternalUrls.resolve("skill://repo-linked", cwd: cwd)
  end

  test "dispatches artifacts with session options unchanged", %{cwd: cwd, tmp_dir: tmp_dir} do
    spill_dir = Path.join(tmp_dir, "spill")
    File.mkdir_p!(spill_dir)
    path = Path.join(spill_dir, "output.txt")
    File.write!(path, "full spilled output")
    opts = [cwd: cwd, session_id: "internal-urls", context_guardrails: %{spill_dir: spill_dir}]
    assert {:ok, uri} = Artifacts.register(path, cwd, opts)

    assert InternalUrls.internal_url?(uri)
    assert {:ok, path} == InternalUrls.resolve(uri, opts)
    assert InternalUrls.resolve(uri, cwd: cwd) == Artifacts.resolve(uri, cwd, cwd: cwd)
    assert {:error, _} = InternalUrls.resolve("artifact://../outside", opts)
  end

  defp authorize_skill!(dir, scope) do
    {:ok, hash} = LemonSkills.Bundle.compute_hash(dir)
    :ok = LemonSkills.Audit.State.authorize(scope, Path.basename(dir), hash, :pass)
  end

  defp create_skill(root, key, body \\ "body", metadata \\ "") do
    bundle = Path.join(root, key)
    File.mkdir_p!(bundle)

    File.write!(Path.join(bundle, "SKILL.md"), """
    ---
    name: #{key}
    description: Internal URL fixture
    #{metadata}
    ---

    #{body}
    """)

    bundle
  end
end
