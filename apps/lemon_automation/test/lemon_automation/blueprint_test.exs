defmodule LemonAutomation.BlueprintTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{Blueprint, CronManager, CronStore}
  alias LemonCore.ProfileStore

  @tag :tmp_dir
  test "previews, confirms, enables, and replays one bundle without duplicates", %{tmp_dir: root} do
    profile_id = unique_id("operator")
    bundle_id = unique_id("daily-bundle")
    automation_id = unique_id("daily-check")
    profile_opts = profile_opts(root)

    assert {:ok, profile} =
             ProfileStore.create(%{id: profile_id, name: "Operator"}, profile_opts)

    bundle = write_bundle(root, bundle_id, automation_id)
    opts = [profile_opts: profile_opts, refresh_fun: fn _ -> :ok end]

    assert {:ok, inspected} = Blueprint.inspect(bundle)
    assert inspected["id"] == bundle_id
    assert inspected["summary"]["promptTextReturned"] == false
    assert inspected["validation"]["trustLevel"] == "untrusted"

    assert {:ok, validated} = Blueprint.validate(bundle)
    assert validated["validation"]["valid"]
    assert validated["validation"]["commandJobsAllowed"] == false

    assert {:ok, preview} = Blueprint.preview(bundle, profile_id, opts)
    assert preview["canActivate"]
    assert [%{"action" => "create"}] = preview["skills"]
    assert preview["automation"]["action"] == "create"
    assert preview["automation"]["promptTextReturned"] == false
    assert preview["commandPolicy"]["commandsAllowed"] == false

    refute File.exists?(Path.join(profile["paths"]["skills"], "daily-note"))
    assert CronStore.get_job(preview["automation"]["id"]) == nil

    assert {:error, {:confirmation_mismatch, _}} =
             Blueprint.activate(bundle, profile_id, "wrong", opts)

    refute File.exists?(Path.join(profile["paths"]["skills"], "daily-note"))
    assert CronStore.get_job(preview["automation"]["id"]) == nil

    assert {:ok, activated} =
             Blueprint.activate(bundle, profile_id, preview["confirmationDigest"], opts)

    assert activated["automation"]["status"] == "created"
    assert [%{"status" => "created"}] = activated["skills"]
    assert activated["summary"]["secretValuesReturned"] == false

    destination = Path.join(profile["paths"]["skills"], "daily-note")
    assert File.regular?(Path.join(destination, "SKILL.md"))

    config =
      profile["paths"]["workspace"]
      |> LemonSkills.Config.project_config_file()
      |> File.read!()
      |> Jason.decode!()

    refute "daily-note" in config["disabled"]

    job_id = activated["automation"]["id"]
    job = CronStore.get_job(job_id)
    assert job.agent_id == profile_id
    assert job.session_key == profile["canonicalSessionKey"]
    assert job.command == nil
    assert get_in(job.meta, ["blueprint", "bundleId"]) == bundle_id
    assert get_in(job.meta, ["blueprint", "automationId"]) == automation_id
    assert get_in(job.meta, ["blueprint", "profileId"]) == profile_id
    assert byte_size(get_in(job.meta, ["blueprint", "definitionDigest"])) == 64

    assert {:ok, replay_preview} = Blueprint.preview(bundle, profile_id, opts)
    assert replay_preview["skills"] |> Enum.all?(&(&1["action"] == "unchanged"))
    assert replay_preview["automation"]["action"] == "unchanged"

    assert {:ok, replayed} =
             Blueprint.activate(
               bundle,
               profile_id,
               replay_preview["confirmationDigest"],
               opts
             )

    assert replayed["automation"]["status"] == "unchanged"
    assert Enum.count(CronManager.list(), &(&1.id == job_id)) == 1

    on_exit(fn -> _ = CronManager.remove(job_id) end)
  end

  @tag :tmp_dir
  test "stale confirmation binds content and current destination state", %{tmp_dir: root} do
    profile_id = unique_id("stale-profile")
    bundle_id = unique_id("stale-bundle")
    automation_id = unique_id("stale-job")
    profile_opts = profile_opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: profile_id}, profile_opts)
    bundle = write_bundle(root, bundle_id, automation_id)
    opts = [profile_opts: profile_opts, refresh_fun: fn _ -> :ok end]

    assert {:ok, preview} = Blueprint.preview(bundle, profile_id, opts)

    collision = Path.join(profile["paths"]["skills"], "daily-note")
    File.mkdir_p!(collision)
    File.write!(Path.join(collision, "SKILL.md"), safe_skill("different"))

    assert {:error, {:conflict, _}} =
             Blueprint.activate(bundle, profile_id, preview["confirmationDigest"], opts)

    assert CronStore.get_job(preview["automation"]["id"]) == nil
  end

  @tag :tmp_dir
  test "revalidates staged skill bytes before any profile or cron commit", %{tmp_dir: root} do
    profile_id = unique_id("stage-profile")
    bundle_id = unique_id("stage-bundle")
    automation_id = unique_id("stage-job")
    profile_opts = profile_opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: profile_id}, profile_opts)
    bundle = write_bundle(root, bundle_id, automation_id)

    base_opts = [profile_opts: profile_opts, refresh_fun: fn _ -> :ok end]
    assert {:ok, preview} = Blueprint.preview(bundle, profile_id, base_opts)

    mutation = fn stage ->
      File.write!(Path.join([stage, "daily-note", "SKILL.md"]), safe_skill("mutated"))
      :ok
    end

    opts = Keyword.put(base_opts, :after_stage_fun, mutation)

    assert {:error, {:staged_bundle_changed, _}} =
             Blueprint.activate(bundle, profile_id, preview["confirmationDigest"], opts)

    refute File.exists?(Path.join(profile["paths"]["skills"], "daily-note"))
    assert CronStore.get_job(preview["automation"]["id"]) == nil
  end

  @tag :tmp_dir
  test "rejects command fields, secret values, symlinks, and archives without echoing values", %{
    tmp_dir: root
  } do
    bundle = write_bundle(root, unique_id("unsafe-bundle"), unique_id("unsafe-job"))
    manifest_path = Path.join(bundle, "bundle.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    secret = "sk-super-secret-value-123456"

    File.write!(
      manifest_path,
      Jason.encode!(put_in(manifest, ["automations", Access.at(0), "prompt"], secret))
    )

    assert {:error, {:secret_value_not_allowed, message}} = Blueprint.validate(bundle)
    refute message =~ secret

    command_manifest =
      manifest
      |> put_in(["automations", Access.at(0), "command"], "printf should-not-run")

    File.write!(manifest_path, Jason.encode!(command_manifest))
    assert {:error, {:command_policy_violation, _}} = Blueprint.validate(bundle)

    File.write!(manifest_path, Jason.encode!(manifest))
    skill = Path.join([bundle, "skills", "daily-note"])
    File.write!(Path.join(skill, "assets.zip"), "not extracted")
    assert {:error, {:archive_not_supported, _}} = Blueprint.validate(bundle)

    File.rm!(Path.join(skill, "assets.zip"))
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "outside")
    File.mkdir_p!(Path.join(skill, "references"))
    File.ln_s!(outside, Path.join([skill, "references", "escape.txt"]))
    assert {:error, {:symlink_not_allowed, _}} = Blueprint.validate(bundle)
  end

  test "CronManager add_new never replaces an existing stable ID" do
    id = "cron_blueprint_test_#{System.unique_integer([:positive, :monotonic])}"

    params = %{
      id: id,
      name: "claimed blueprint",
      schedule: "0 0 1 1 *",
      enabled: false,
      agent_id: "claimed",
      session_key: "agent:claimed:main",
      prompt: "first"
    }

    assert {:ok, first} = CronManager.add_new(params)
    assert {:error, :already_exists} = CronManager.add_new(%{params | prompt: "second"})
    assert CronStore.get_job(id).prompt == "first"
    assert Enum.count(CronManager.list(), &(&1.id == id)) == 1

    _ = CronManager.remove(first.id)
  end

  defp write_bundle(root, bundle_id, automation_id) do
    bundle = Path.join(root, bundle_id)
    skill = Path.join([bundle, "skills", "daily-note"])
    File.mkdir_p!(skill)
    File.write!(Path.join(skill, "SKILL.md"), safe_skill("daily-note"))

    manifest = %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "id" => bundle_id,
      "name" => "Daily Note Bundle",
      "description" => "A harmless disabled daily note automation",
      "skills" => [%{"key" => "daily-note", "path" => "skills/daily-note"}],
      "automations" => [
        %{
          "id" => automation_id,
          "kind" => "cron",
          "name" => "Daily note preview",
          "schedule" => "0 0 1 1 *",
          "prompt" => "Use the daily-note skill to summarize completed work.",
          "enabled" => false,
          "timezone" => "UTC"
        }
      ]
    }

    File.write!(Path.join(bundle, "bundle.json"), Jason.encode!(manifest, pretty: true))
    bundle
  end

  defp safe_skill(name) do
    """
    ---
    name: #{name}
    description: Summarize completed work without making external changes
    ---

    # Daily note

    Summarize completed work from the current conversation. Do not run commands
    or contact external services.
    """
  end

  defp profile_opts(root) do
    state = Path.join(root, "state")
    [home_state_dir: state, config_path: Path.join(state, "config.toml")]
  end

  defp unique_id(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{suffix}"
  end
end
