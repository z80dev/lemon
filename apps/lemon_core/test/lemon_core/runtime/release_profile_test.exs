defmodule LemonCore.Runtime.ReleaseProfileTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Verifies runtime profile membership and the separation of minimal and
  full-only applications.
  """

  alias LemonCore.Runtime.Profile

  @min_apps [:coding_agent, :lemon_gateway, :lemon_router, :lemon_channels, :lemon_control_plane]
  @full_extras [:lemon_automation, :lemon_skills, :lemon_web, :lemon_sim_ui]

  describe "lemon_runtime_min profile" do
    test "includes all headless-runtime apps" do
      apps = Profile.app_list(:runtime_min)

      for app <- @min_apps do
        assert app in apps,
               "Expected :#{app} in runtime_min apps, got: #{inspect(apps)}"
      end
    end

    test "does not include full-only extras" do
      apps = Profile.app_list(:runtime_min)

      for app <- @full_extras do
        refute app in apps,
               "Expected :#{app} to be absent from runtime_min, but it was present"
      end
    end
  end

  describe "lemon_runtime_full profile" do
    test "includes all min-profile apps" do
      apps = Profile.app_list(:runtime_full)

      for app <- @min_apps do
        assert app in apps,
               "Expected :#{app} in runtime_full apps (inherited from min), got: #{inspect(apps)}"
      end
    end

    test "also includes full-only extras" do
      apps = Profile.app_list(:runtime_full)

      for app <- @full_extras do
        assert app in apps,
               "Expected :#{app} in runtime_full apps, got: #{inspect(apps)}"
      end
    end

    test "full has strictly more apps than min" do
      assert length(Profile.app_list(:runtime_full)) > length(Profile.app_list(:runtime_min))
    end
  end
end
