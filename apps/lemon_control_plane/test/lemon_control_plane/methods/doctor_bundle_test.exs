defmodule LemonControlPlane.Methods.DoctorBundleTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{DoctorBundle, Registry}

  defmodule RunningMediaSupervisor do
    def status, do: %{supervised: true, running: true, workers: 3}
  end

  defmodule PathyMediaJobs do
    def default_dir(_project_dir), do: "/Users/alice/.lemon/media"
    def default_artifacts_dir(_project_dir), do: "/Users/alice/.lemon/media/artifacts"
    def summary(_opts), do: %{count: 0}
    def recent(_opts), do: []
  end

  setup do
    previous = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.merge(previous,
        media_supervisor: RunningMediaSupervisor,
        media_jobs: PathyMediaJobs
      )
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, previous) end)
  end

  test "is a registered, admin-scoped async method" do
    assert DoctorBundle.scopes() == [:admin]
    assert "doctor.bundle" in Registry.list_methods()
    assert Registry.dispatch_mode("doctor.bundle") == :async
  end

  test "returns the daemon's redacted runtime sections" do
    assert {:ok, %{"entries" => entries}} = DoctorBundle.handle(%{}, %{})

    assert Enum.sort(Map.keys(entries)) ==
             Enum.sort(LemonCore.Doctor.SupportBundle.section_names())

    media = entries["media_diagnostics.json"]
    assert media["worker_status"]["running"] == true
    assert media["worker_status"]["workers"] == 3
    assert %{"path_hash" => _, "exists" => false} = media["jobs_dir"]

    encoded = Jason.encode!(entries)
    refute encoded =~ "/Users/alice"
    refute encoded =~ File.cwd!()
  end
end
