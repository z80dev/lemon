defmodule LemonCore.Runtime.ProfileTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Profile

  describe "get/1" do
    test "returns runtime_min profile" do
      profile = Profile.get(:runtime_min)

      assert profile.name == :runtime_min
      assert :lemon_gateway in profile.apps
      assert :lemon_router in profile.apps
      assert :lemon_channels in profile.apps
      assert :lemon_control_plane in profile.apps
      refute :lemon_web in profile.apps
      refute :lemon_sim_ui in profile.apps
    end

    test "returns runtime_full profile" do
      profile = Profile.get(:runtime_full)

      assert profile.name == :runtime_full
      assert :lemon_gateway in profile.apps
      assert :lemon_web in profile.apps
      assert :lemon_sim_ui in profile.apps
      assert :lemon_skills in profile.apps
    end

    test "raises for unknown profile" do
      assert_raise ArgumentError, ~r/Unknown runtime profile/, fn ->
        Profile.get(:nonexistent)
      end
    end
  end

  describe "app_list/1" do
    test "returns list of atoms for runtime_min" do
      apps = Profile.app_list(:runtime_min)
      assert is_list(apps)
      assert Enum.all?(apps, &is_atom/1)
      assert length(apps) >= 4
    end

    test "runtime_full has more apps than runtime_min" do
      min_apps = Profile.app_list(:runtime_min)
      full_apps = Profile.app_list(:runtime_full)
      assert length(full_apps) > length(min_apps)
    end
  end

  describe "names/0" do
    test "returns both known profiles" do
      names = Profile.names()
      assert :runtime_min in names
      assert :runtime_full in names
    end
  end
end
