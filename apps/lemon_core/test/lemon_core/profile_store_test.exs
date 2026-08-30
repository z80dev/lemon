defmodule LemonCore.ProfileStoreTest do
  use ExUnit.Case, async: true

  alias LemonCore.ProfileStore

  @tag :tmp_dir
  test "creates, lists, renames, exports, and recoverably deletes a profile", %{tmp_dir: root} do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)

    original = """
    # user comment must survive lifecycle edits
    [custom]
    unknown = "keep-me"
    """

    File.mkdir_p!(Path.dirname(config))
    File.write!(config, original)

    assert {:ok, profile} =
             ProfileStore.create(
               %{
                 id: "research-bot",
                 name: "Research Bot",
                 description: "isolated researcher",
                 model: "openai:gpt-5",
                 system_prompt: "Be rigorous"
               },
               opts
             )

    assert profile["canonicalSessionKey"] == "agent:research-bot:main"

    assert profile["paths"]["workspace"] ==
             Path.join([root, "state", "profiles", "research-bot", "workspace"])

    assert File.dir?(profile["paths"]["memory"])
    assert File.dir?(profile["paths"]["skills"])
    assert File.regular?(profile["paths"]["manifest"])
    assert [%{"id" => "research-bot"}] = Enum.map(ProfileStore.list(opts), &Map.take(&1, ["id"]))

    assert {:ok, renamed} = ProfileStore.rename("research-bot", "Research Prime", opts)
    assert renamed["name"] == "Research Prime"
    assert renamed["canonicalSessionKey"] == profile["canonicalSessionKey"]

    export_path = Path.join(root, "research-profile.json")
    assert {:ok, %{"fileCount" => count}} = ProfileStore.export("research-bot", export_path, opts)
    assert count >= 2
    assert {:error, :destination_exists} = ProfileStore.export("research-bot", export_path, opts)

    assert %{"format" => "lemon-profile", "profile" => %{"id" => "research-bot"}} =
             export_path |> File.read!() |> Jason.decode!()

    assert {:error, :confirmation_required} = ProfileStore.delete("research-bot", opts)

    assert {:ok, %{"homeMoved" => true, "trashPath" => trash}} =
             ProfileStore.delete("research-bot", Keyword.put(opts, :confirm, "research-bot"))

    assert File.dir?(trash)
    refute File.exists?(profile["paths"]["home"])
    assert {:error, :not_found} = ProfileStore.get("research-bot", opts)

    final_config = File.read!(config)
    assert final_config =~ "# user comment must survive lifecycle edits"
    assert final_config =~ ~s([custom]\nunknown = "keep-me")
    refute final_config =~ "[profiles.research-bot]"
  end

  @tag :tmp_dir
  test "clone copies regular memory and skills but rejects symlinks", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, source} = ProfileStore.create(%{id: "source", name: "Source"}, opts)
    File.write!(Path.join(source["paths"]["memory"], "MEMORY.md"), "remember")
    File.write!(Path.join(source["paths"]["skills"], "SKILL.md"), "skill")

    assert {:ok, clone} =
             ProfileStore.clone("source", %{id: "copy", name: "Copy"}, opts)

    assert File.read!(Path.join(clone["paths"]["memory"], "MEMORY.md")) == "remember"
    assert File.read!(Path.join(clone["paths"]["skills"], "SKILL.md")) == "skill"
    assert clone["canonicalSessionKey"] == "agent:copy:main"

    outside = Path.join(root, "outside")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(source["paths"]["workspace"], "unsafe-link"))

    assert {:error, {:unsafe_profile_entry, _}} =
             ProfileStore.clone("source", %{id: "unsafe-copy"}, opts)

    assert {:error, :not_found} = ProfileStore.get("unsafe-copy", opts)
  end

  @tag :tmp_dir
  test "rejects invalid ids, reserved ids, collisions, and symlinked homes", %{tmp_dir: root} do
    opts = opts(root)

    assert {:error, :invalid_id} = ProfileStore.create(%{id: "../escape"}, opts)
    assert {:error, :reserved_profile} = ProfileStore.create(%{id: "default"}, opts)
    assert {:ok, _} = ProfileStore.create(%{id: "one", name: "One"}, opts)
    assert {:error, :already_exists} = ProfileStore.create(%{id: "one", name: "Other"}, opts)

    {:ok, paths} = ProfileStore.paths("linked", opts)
    File.mkdir_p!(Path.dirname(paths["home"]))
    outside = Path.join(root, "outside-home")
    File.mkdir_p!(outside)
    File.ln_s!(outside, paths["home"])

    assert {:error, :unsafe_profile_home} =
             ProfileStore.create(%{id: "linked", name: "Linked"}, opts)
  end

  @tag :tmp_dir
  test "create rolls config back when the prepared home cannot commit", %{tmp_dir: root} do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "# original\n")
    {:ok, paths} = ProfileStore.paths("raced", opts)

    writer = fn path, content ->
      :ok = File.write(path, content)
      :ok = File.write(paths["home"], "collision")
      :ok
    end

    assert {:error, {:home_commit_failed, _}} =
             ProfileStore.create(
               %{id: "raced", name: "Raced"},
               Keyword.put(opts, :atomic_write_fun, writer)
             )

    assert File.read!(config) == "# original\n"
    assert {:error, :not_found} = ProfileStore.get("raced", opts)
  end

  @tag :tmp_dir
  test "rename and delete restore config and home on commit failures", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: "safe", name: "Safe"}, opts)

    File.rm!(profile["paths"]["manifest"])
    File.mkdir_p!(profile["paths"]["manifest"])
    assert {:error, _} = ProfileStore.rename("safe", "Changed", opts)
    assert {:ok, %{"name" => "Safe"}} = ProfileStore.get("safe", opts)

    failing_writer = fn _path, _content -> {:error, :forced_write_failure} end

    assert {:error, :forced_write_failure} =
             ProfileStore.delete(
               "safe",
               opts
               |> Keyword.put(:confirm, "safe")
               |> Keyword.put(:atomic_write_fun, failing_writer)
             )

    assert File.dir?(profile["paths"]["home"])
    assert {:ok, %{"id" => "safe"}} = ProfileStore.get("safe", opts)
  end

  @tag :tmp_dir
  test "delete refuses a symlinked managed home", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: "linked-delete"}, opts)
    File.rm_rf!(profile["paths"]["home"])
    outside = Path.join(root, "outside-delete")
    File.mkdir_p!(outside)
    File.ln_s!(outside, profile["paths"]["home"])

    assert {:error, :unsafe_profile_home} =
             ProfileStore.delete("linked-delete", Keyword.put(opts, :confirm, "linked-delete"))

    assert File.dir?(outside)
  end

  test "default profile deletion is always guarded" do
    assert {:error, :reserved_profile} = ProfileStore.delete("default", confirm: "default")
  end

  defp opts(root) do
    state = Path.join(root, "state")
    [home_state_dir: state, config_path: Path.join(state, "config.toml")]
  end
end
