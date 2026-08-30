defmodule LemonCore.Update.PlanTest do
  use ExUnit.Case, async: true

  alias LemonCore.Update.Plan

  defp artifact(overrides \\ %{}) do
    Map.merge(
      %{
        "file" => "lemon.tar.gz",
        "profile" => "lemon_runtime_min",
        "platform" => "linux-x86_64",
        "sha256" => String.duplicate("a", 64),
        "size" => 123
      },
      overrides
    )
  end

  defp info(overrides \\ %{}) do
    Map.merge(
      %{
        latest: "2026.09.0",
        update_available?: true,
        channel: "stable",
        manifest_commit: String.duplicate("b", 40),
        manifest_sha256: String.duplicate("c", 64),
        artifact: artifact(),
        tui_artifact: nil
      },
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        current: "2026.08.0",
        running: "2026.08.0",
        profile: "lemon_runtime_min",
        platform: "linux-x86_64",
        now_ms: 1_700_000_000_000
      ],
      overrides
    )
  end

  test "digest binds raw manifest, current pointer, and exact artifact fields" do
    assert {:ok, first} = Plan.build(info(), opts())
    assert byte_size(first.digest) == 64

    assert {:ok, changed_manifest} =
             Plan.build(info(%{manifest_sha256: String.duplicate("d", 64)}), opts())

    assert {:ok, changed_current} = Plan.build(info(), opts(current: "2026.07.0"))

    assert {:ok, changed_artifact} =
             Plan.build(
               info(%{artifact: artifact(%{"sha256" => String.duplicate("e", 64)})}),
               opts()
             )

    refute first.digest == changed_manifest.digest
    refute first.digest == changed_current.digest
    refute first.digest == changed_artifact.digest
  end

  test "rejects unconfined names, malformed checksums, and oversized artifacts" do
    assert {:error, :invalid_artifact_file} =
             Plan.build(info(%{artifact: artifact(%{"file" => "../escape"})}), opts())

    assert {:error, :invalid_artifact_checksum} =
             Plan.build(info(%{artifact: artifact(%{"sha256" => "not-a-digest"})}), opts())

    assert {:error, :invalid_artifact_size} =
             Plan.build(
               info(%{artifact: artifact(%{"size" => 124})}),
               opts(max_artifact_bytes: 123)
             )
  end

  test "rejects receipt-bearing identifiers that could carry paths or secret-shaped content" do
    assert {:error, :invalid_channel} =
             Plan.build(info(%{channel: "../../private/token"}), opts())

    assert {:error, :invalid_profile} =
             Plan.build(info(), opts(profile: "profile/PLANTED_SECRET"))

    assert {:error, :invalid_platform} =
             Plan.build(info(), opts(platform: "platform\nPLANTED_SECRET"))
  end

  test "rollback digest binds the verified checkpoint" do
    assert {:ok, plan} = Plan.build(info(), opts())

    first =
      Plan.rollback_digest(plan, %{
        "id" => "1700000000000-aaaaaaaaaaaaaaaa",
        "launcher_sha256" => String.duplicate("1", 64)
      })

    second =
      Plan.rollback_digest(plan, %{
        "id" => "1700000000000-bbbbbbbbbbbbbbbb",
        "launcher_sha256" => String.duplicate("1", 64)
      })

    refute first == second
  end
end
