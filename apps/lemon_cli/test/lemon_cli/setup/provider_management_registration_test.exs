defmodule LemonCli.Setup.ProviderManagementRegistrationTest do
  use ExUnit.Case, async: false

  test "CLI application registers destination setup support at runtime" do
    assert {:ok, _} = Application.ensure_all_started(:lemon_cli)
    assert LemonCore.ProviderManagement.service() == LemonCli.Setup.ProviderManagement

    for profile <- [:runtime_min, :runtime_full] do
      assert :lemon_cli in LemonCore.Runtime.Profile.app_list(profile)
    end
  end

  test "normal controller runtime boot retains the destination registration" do
    before = Application.started_applications() |> Enum.map(&elem(&1, 0))

    on_exit(fn ->
      for {app, _, _} <- Application.started_applications(), app not in before do
        Application.stop(app)
      end
    end)

    assert :ok =
             LemonCore.Runtime.Boot.start(:runtime_min,
               check_running: false,
               dotenv_dir: nil
             )

    assert LemonCore.ProviderManagement.service() == LemonCli.Setup.ProviderManagement
  end

  test "one-shot version command starts no additional applications or CLI children" do
    assert {:ok, _} = Application.ensure_all_started(:lemon_cli)
    assert Supervisor.which_children(LemonCli.Supervisor) == []
    before = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    ExUnit.CaptureIO.capture_io(fn ->
      assert LemonCli.CLI.run(["--version"]) == 0
    end)

    assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == before
    assert Supervisor.which_children(LemonCli.Supervisor) == []
  end
end
