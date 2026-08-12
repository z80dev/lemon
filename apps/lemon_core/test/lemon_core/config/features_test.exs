defmodule LemonCore.Config.FeaturesTest do
  # async: false — tests manipulate LEMON_FEATURE_* environment variables.
  use ExUnit.Case, async: false

  alias LemonCore.Config.Features

  @env_var "LEMON_FEATURE_SESSION_SEARCH"

  setup do
    original = System.get_env(@env_var)
    System.delete_env(@env_var)

    on_exit(fn ->
      if is_nil(original) do
        System.delete_env(@env_var)
      else
        System.put_env(@env_var, original)
      end
    end)

    :ok
  end

  describe "resolve/1 defaults" do
    test "session_search defaults to default-on" do
      features = Features.resolve(%{})
      assert features.session_search == :"default-on"
      assert Features.enabled?(features, :session_search)
    end

    test "adaptive flags default to opt-in" do
      features = Features.resolve(%{})
      assert features.routing_feedback == :"opt-in"
      assert features.skill_synthesis_drafts == :"opt-in"
      refute Features.enabled?(features, :routing_feedback)
      refute Features.enabled?(features, :skill_synthesis_drafts)
    end

    test "struct defaults match resolve defaults" do
      assert %Features{} == Features.resolve(%{})
    end
  end

  describe "resolve/1 parsing" do
    test "TOML value overrides the default" do
      features = Features.resolve(%{"features" => %{"session_search" => "off"}})
      assert features.session_search == :off
      refute Features.enabled?(features, :session_search)
    end

    test "on parses to default-on" do
      features = Features.resolve(%{"features" => %{"session_search" => "on"}})
      assert features.session_search == :"default-on"
    end

    test "unknown values parse to off (fail-closed)" do
      features = Features.resolve(%{"features" => %{"session_search" => "banana"}})
      assert features.session_search == :off
    end

    test "environment variable kill switch wins over TOML" do
      System.put_env(@env_var, "off")
      features = Features.resolve(%{"features" => %{"session_search" => "default-on"}})
      assert features.session_search == :off
      refute Features.enabled?(features, :session_search)
    end
  end

  describe "enabled?/3" do
    test "opt-in is inactive unless opt_in: true is passed" do
      features = %Features{session_search: :"opt-in"}
      refute Features.enabled?(features, :session_search)
      assert Features.enabled?(features, :session_search, opt_in: true)
    end

    test "off stays off even with opt_in: true" do
      features = %Features{session_search: :off}
      refute Features.enabled?(features, :session_search, opt_in: true)
    end
  end

  describe "validate/1" do
    test "default struct validates" do
      assert Features.validate(%Features{}) == :ok
    end

    test "invalid state is reported" do
      assert {:error, [error]} = Features.validate(%Features{session_search: :banana})
      assert error =~ "session_search"
    end
  end
end
