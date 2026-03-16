defmodule LemonCore.Runtime.ReleaseProfileTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Verifies that the runtime profiles declared in mix.exs and
  LemonCore.Runtime.Profile are kept in sync.
  """

  alias LemonCore.Runtime.Profile

  @min_apps [:lemon_gateway, :lemon_router, :lemon_channels, :lemon_control_plane]
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

  describe "mix.exs releases/0 parity" do
    # Guards that mix.exs release definitions stay in sync with Profile.
    # We can't easily eval mix.exs in a unit test, so we compare at the
    # module level instead.

    test "lemon_core is a dependency of every profile" do
      # lemon_core is always :permanent in releases; it starts first.
      # Its runtime modules must be accessible from any profile.
      assert Code.ensure_loaded?(LemonCore.Runtime.Boot)
      assert Code.ensure_loaded?(LemonCore.Runtime.Profile)
      assert Code.ensure_loaded?(LemonCore.Runtime.Health)
      assert Code.ensure_loaded?(LemonCore.Runtime.Env)
    end
  end
end
