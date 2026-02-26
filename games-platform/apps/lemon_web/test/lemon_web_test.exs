defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  test "application starts successfully" do
    # The application should be running
    assert Application.started_applications()
           |> Enum.any?(fn {app, _, _} -> app == :lemon_web end)
  end

  test "endpoint configuration exists" do
    config = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    assert is_list(config)
    assert config[:url] || config[:http]
  end

  test "router is configured" do
    # The router module should exist and be loadable
    assert Code.ensure_loaded?(LemonWeb.Router)
  end

  test "session live module exists" do
    # The SessionLive module should exist
    assert Code.ensure_loaded?(LemonWeb.SessionLive)
  end
end
