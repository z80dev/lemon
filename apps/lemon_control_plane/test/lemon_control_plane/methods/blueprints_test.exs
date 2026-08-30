defmodule LemonControlPlane.Methods.BlueprintsTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronStore}
  alias LemonCore.ProfileStore

  alias LemonControlPlane.Methods.{
    BlueprintsActivate,
    BlueprintsInspect,
    BlueprintsList,
    BlueprintsPreview,
    BlueprintsValidate
  }

  @tag :tmp_dir
  test "authenticated method surface previews and activates without returning content or paths",
       %{
         tmp_dir: root
       } do
    profile_id = unique_id("cp-profile")
    bundle_id = unique_id("cp-bundle")
    automation_id = unique_id("cp-job")
    profile_opts = profile_opts(root)

    assert {:ok, profile} = ProfileStore.create(%{id: profile_id}, profile_opts)
    catalog = Path.join([root, "state", "bundles"])
    File.mkdir_p!(catalog)
    bundle = write_bundle(catalog, bundle_id, automation_id)

    old_opts = Application.get_env(:lemon_control_plane, :blueprint_opts)

    Application.put_env(
      :lemon_control_plane,
      :blueprint_opts,
      profile_opts: profile_opts,
      refresh_fun: fn _ -> :ok end
    )

    on_exit(fn ->
      if old_opts do
        Application.put_env(:lemon_control_plane, :blueprint_opts, old_opts)
      else
        Application.delete_env(:lemon_control_plane, :blueprint_opts)
      end
    end)

    assert BlueprintsList.name() == "blueprints.list"
    assert BlueprintsInspect.scopes() == [:read]
    assert BlueprintsActivate.scopes() == [:admin]

    assert {:ok, %{"bundles" => listed, "summary" => list_summary}} =
             BlueprintsList.handle(%{}, %{})

    assert Enum.any?(listed, &(&1["id"] == bundle_id))
    assert list_summary["pathsReturned"] == false

    assert {:error, {:invalid_request, _}} =
             BlueprintsInspect.handle(%{"bundleId" => "../#{bundle_id}"}, %{})

    linked_id = unique_id("linked-bundle")
    File.ln_s!(bundle, Path.join(catalog, linked_id))

    assert {:error, {:invalid_request, _}} =
             BlueprintsInspect.handle(%{"bundleId" => linked_id}, %{})

    assert {:ok, inspected} = BlueprintsInspect.handle(%{"bundleId" => bundle_id}, %{})
    assert inspected["id"] == bundle_id

    assert {:ok, validated} = BlueprintsValidate.handle(%{"bundleId" => bundle_id}, %{})
    assert validated["validation"]["valid"]

    assert {:ok, preview} =
             BlueprintsPreview.handle(%{"bundleId" => bundle_id, "profileId" => profile_id}, %{})

    assert preview["canActivate"]

    wire_preview = Jason.encode!(preview)
    refute wire_preview =~ bundle
    refute wire_preview =~ profile["paths"]["workspace"]
    refute wire_preview =~ "Use the cp-note skill"

    assert {:error, {:conflict, "Confirmation digest is missing, stale, or incorrect"}} =
             BlueprintsActivate.handle(
               %{
                 "bundleId" => bundle_id,
                 "profileId" => profile_id,
                 "confirmationDigest" => "wrong"
               },
               %{}
             )

    assert {:ok, activated} =
             BlueprintsActivate.handle(
               %{
                 "bundleId" => bundle_id,
                 "profileId" => profile_id,
                 "confirmationDigest" => preview["confirmationDigest"]
               },
               %{}
             )

    assert activated["automation"]["status"] == "created"
    assert activated["summary"]["promptTextReturned"] == false
    job_id = activated["automation"]["id"]

    assert CronStore.get_job(job_id).prompt ==
             "Use the cp-note skill to summarize completed work."

    assert {:ok, replay_preview} =
             BlueprintsPreview.handle(%{"bundleId" => bundle_id, "profileId" => profile_id}, %{})

    assert replay_preview["automation"]["action"] == "unchanged"

    assert {:ok, replayed} =
             BlueprintsActivate.handle(
               %{
                 "bundleId" => bundle_id,
                 "profileId" => profile_id,
                 "confirmationDigest" => replay_preview["confirmationDigest"]
               },
               %{}
             )

    assert replayed["automation"]["status"] == "unchanged"
    assert Enum.count(CronManager.list(), &(&1.id == job_id)) == 1
    refute Jason.encode!(replayed) =~ "Use the cp-note skill"

    _ = CronManager.remove(job_id)
  end

  defp write_bundle(root, bundle_id, automation_id) do
    bundle = Path.join(root, bundle_id)
    skill = Path.join([bundle, "skills", "cp-note"])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      """
      ---
      name: cp-note
      description: Summarize completed work without external changes
      ---

      # CP note

      Summarize completed work. Do not run commands or contact external services.
      """
    )

    manifest = %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "id" => bundle_id,
      "name" => "Control Plane Note",
      "description" => "A disabled harmless control-plane proof",
      "skills" => [%{"key" => "cp-note", "path" => "skills/cp-note"}],
      "automations" => [
        %{
          "id" => automation_id,
          "kind" => "cron",
          "name" => "Control plane note",
          "schedule" => "0 0 1 1 *",
          "prompt" => "Use the cp-note skill to summarize completed work.",
          "enabled" => false,
          "timezone" => "UTC"
        }
      ]
    }

    File.write!(Path.join(bundle, "bundle.json"), Jason.encode!(manifest, pretty: true))
    bundle
  end

  defp profile_opts(root) do
    state = Path.join(root, "state")
    [home_state_dir: state, config_path: Path.join(state, "config.toml")]
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
