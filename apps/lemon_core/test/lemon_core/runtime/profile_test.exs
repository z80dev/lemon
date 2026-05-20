defmodule LemonCore.Runtime.ProfileTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Profile

  test "full runtime includes automation for cron restart proof" do
    assert :lemon_automation in Profile.app_list(:runtime_full)
  end

  test "minimal runtime excludes automation by design" do
    refute :lemon_automation in Profile.app_list(:runtime_min)
  end
end
