defmodule CodingAgent.SkillFileResolverAgreementTest do
  @moduledoc """
  `skill://` and `read_skill` must resolve bundle files through the same
  lstat-checked, regular-file-only, size-capped and status-gated resolver, so
  the same input is either readable through both or refused by both.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.InternalUrls
  alias LemonSkills.Config
  alias LemonSkills.Tools.ReadSkill

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

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      LemonSkills.refresh(cwd: cwd)
    end)

    %{cwd: cwd}
  end

  test "skill:// and read_skill agree on every input", %{cwd: cwd, tmp_dir: tmp_dir} do
    bundle = create_skill(Config.project_skills_dir(cwd), "agree")
    refs = Path.join(bundle, "references")
    File.mkdir_p!(refs)
    secret = Path.join(tmp_dir, "secret.txt")
    File.write!(secret, "SECRET-VALUE")
    File.write!(Path.join(refs, "ok.md"), "ok")
    File.write!(Path.join(refs, ".hidden.md"), "hidden")
    File.write!(Path.join(bundle, "notes.md"), "out of layout")
    File.write!(Path.join(refs, "big.md"), String.duplicate("B", 2 * 1_048_576))
    File.ln_s!(secret, Path.join(refs, "link.md"))
    {_, 0} = System.cmd("mkfifo", [Path.join(refs, "pipe")])

    create_skill(Config.project_skills_dir(cwd), "agree-off")
    authorize_skill!(bundle, {:project, cwd})
    authorize_skill!(Path.join(Config.project_skills_dir(cwd), "agree-off"), {:project, cwd})
    assert :ok = Config.disable("agree-off", global: false, cwd: cwd)
    LemonSkills.refresh(cwd: cwd)

    cases = [
      {"agree", "SKILL.md", true},
      {"agree", "references/ok.md", true},
      {"agree", "references/.hidden.md", false},
      {"agree", "notes.md", false},
      {"agree", "references/big.md", false},
      {"agree", "references/link.md", false},
      {"agree", "references/pipe", false},
      {"agree", "references", false},
      {"agree", "references/missing.md", false},
      {"agree-off", "SKILL.md", false}
    ]

    for {key, path, readable?} <- cases do
      url_ok? = match?({:ok, _}, InternalUrls.resolve("skill://#{key}/#{path}", cwd: cwd))

      task =
        Task.async(fn ->
          ReadSkill.execute(
            "call",
            %{"key" => key, "view" => "file", "path" => path},
            nil,
            nil,
            cwd
          )
        end)

      assert {:ok, result} = Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill),
             "read_skill hung on #{key}/#{path}"

      read_ok? = not Map.has_key?(result.details, :error)
      text = Enum.map_join(result.content, "", & &1.text)

      assert url_ok? == readable?, "skill:// #{key}/#{path}"
      assert read_ok? == readable?, "read_skill #{key}/#{path}: #{String.slice(text, 0, 200)}"
      refute text =~ "SECRET-VALUE"
    end
  end

  defp authorize_skill!(dir, scope) do
    {:ok, hash} = LemonSkills.Bundle.compute_hash(dir)
    :ok = LemonSkills.Audit.State.authorize(scope, Path.basename(dir), hash, :pass)
  end

  defp create_skill(root, key) do
    bundle = Path.join(root, key)
    File.mkdir_p!(bundle)

    File.write!(Path.join(bundle, "SKILL.md"), """
    ---
    name: #{key}
    description: Resolver agreement fixture
    ---

    body
    """)

    bundle
  end
end
