defmodule CodingAgent.SkillUrlAuthorizationTest do
  @moduledoc """
  `skill://` shares the read gate of `read_skill`: a bundle is readable only
  while an operator-side grant matches its exact live bytes. Repository
  lockfiles and audit caches never authorize loading.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.InternalUrls
  alias LemonSkills.{Bundle, Config, Lockfile}
  alias LemonSkills.Audit.State

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

  test "an unrecorded repository skill is not readable through skill://", %{cwd: cwd} do
    bundle = write_skill!(cwd, "dropped")

    :ok =
      Lockfile.put({:project, cwd}, %{
        "key" => "dropped",
        "audit_status" => "pass",
        "bundle_hash" => elem(Bundle.compute_hash(bundle), 1)
      })

    LemonSkills.refresh(cwd: cwd)
    assert {:error, message} = InternalUrls.resolve("skill://dropped", cwd: cwd)
    assert message =~ "not authorized"
  end

  test "a grant authorizes exactly the granted bytes", %{cwd: cwd} do
    bundle = write_skill!(cwd, "granted")
    File.mkdir_p!(Path.join(bundle, "references"))
    File.write!(Path.join([bundle, "references", "guide.md"]), "guide")
    {:ok, hash} = Bundle.compute_hash(bundle)
    :ok = State.authorize({:project, cwd}, "granted", hash, :pass)
    LemonSkills.refresh(cwd: cwd)

    assert {:ok, path} = InternalUrls.resolve("skill://granted/references/guide.md", cwd: cwd)
    assert path == Path.join([bundle, "references", "guide.md"])

    File.write!(Path.join([bundle, "references", "guide.md"]), "swapped guide")
    assert {:error, _} = InternalUrls.resolve("skill://granted/references/guide.md", cwd: cwd)
  end

  defp write_skill!(cwd, key) do
    bundle = Path.join(Config.project_skills_dir(cwd), key)
    File.mkdir_p!(bundle)

    File.write!(Path.join(bundle, "SKILL.md"), """
    ---
    name: #{key}
    description: skill:// authorization fixture
    ---

    Repository instructions.
    """)

    bundle
  end
end
