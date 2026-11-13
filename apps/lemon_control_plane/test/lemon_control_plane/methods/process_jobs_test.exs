defmodule LemonControlPlane.Methods.ProcessJobsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    ProcessJobsCancel,
    ProcessJobsInspect,
    ProcessJobsList,
    Registry
  }

  alias LemonControlPlane.Protocol.Schemas

  defmodule Runtime do
    @moduledoc false

    def session_jobs("agent:t:main") do
      send(self(), {:jobs, "agent:t:main"})

      {:ok,
       %{
         root_id: "root-1",
         now_ms: 5_000,
         jobs: [
           %{
             id: "job-1",
             status: :running,
             owner_id: "root-1",
             command: String.duplicate("a", 5_000) <> " --token=sk-private-token-123456",
             started_ms: 1_000,
             exit_code: nil,
             launch: :accepted,
             env: %{"API_KEY" => "must-not-leak"},
             full_output_path: "/Users/alice/secret/out.log"
           },
           %{id: "bad id/\u0000", status: :bogus}
         ],
         agents: [%{id: "child-1", parent_id: "root-1", name: "reviewer"}],
         total: 2,
         truncated: false
       }}
    end

    def session_jobs("agent:many:main") do
      jobs = for n <- 1..130, do: %{id: "job-#{n}", status: :completed, owner_id: "r"}
      {:ok, %{root_id: "r", jobs: jobs, agents: [], total: 130, truncated: true}}
    end

    def session_jobs("agent:cold:main"), do: {:ok, %{root_id: nil, jobs: [], agents: []}}
    def session_jobs("agent:broken:main"), do: {:ok, %{jobs: :nope}}
    def session_jobs(_key), do: {:error, :unavailable}

    def session_job("agent:t:main", "job-1", opts) do
      send(self(), {:inspect, opts})

      {:ok,
       %{
         id: "job-1",
         status: :running,
         owner_id: "root-1",
         command: "make",
         cwd: "/work",
         pids: [10, -3, "x"],
         output:
           String.duplicate("o", 100_000) <> "\nAuthorization: Bearer abcdef123456789012345",
         output_truncated: true,
         output_bytes: 100_042
       }}
    end

    def session_job(_key, _id, _opts), do: {:error, :not_found}

    def session_job_cancel("agent:t:main", "job-1") do
      send(self(), :cancel_called)
      {:ok, %{id: "job-1", status: :killed, owner_id: "root-1", command: "make"}}
    end

    def session_job_cancel("agent:t:main", "done"), do: {:error, :already_terminal}
    def session_job_cancel("agent:t:main", "stuck"), do: {:error, :outcome_unknown}
    def session_job_cancel("agent:t:main", "crash"), do: raise("boom")
    def session_job_cancel("agent:t:main", "garbage"), do: :ok
    def session_job_cancel(_key, _id), do: {:error, :not_found}
  end

  setup do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Runtime)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)
  end

  test "registers the jobs methods with schemas and scopes" do
    for {name, module, scopes} <- [
          {"process.jobs.list", ProcessJobsList, [:read]},
          {"process.jobs.inspect", ProcessJobsInspect, [:read]},
          {"process.jobs.cancel", ProcessJobsCancel, [:write]}
        ] do
      assert {:ok, ^module} = Registry.lookup(name)
      assert module.scopes() == scopes
      assert Schemas.get(name) != nil
    end

    assert :ok = Schemas.validate("process.jobs.list", %{"sessionKey" => "k"})
    assert {:error, _} = Schemas.validate("process.jobs.inspect", %{"sessionKey" => "k"})

    assert :ok =
             Schemas.validate("process.jobs.inspect", %{
               "sessionKey" => "k",
               "jobId" => "j",
               "tailBytes" => 10
             })
  end

  test "list projects bounded, redacted summaries scoped by the requested session key" do
    assert {:ok, result} = ProcessJobsList.handle(%{"sessionKey" => "agent:t:main"}, %{})
    assert_received {:jobs, "agent:t:main"}

    assert %{"live" => true, "rootId" => "root-1", "total" => 2, "truncated" => false} = result
    assert result["at"] == 5_000
    assert [job] = result["jobs"]
    assert job["id"] == "job-1"
    assert job["status"] == "running"
    assert job["ownerId"] == "root-1"
    assert job["startedAt"] == 1_000
    assert job["launch"] == "accepted"
    assert byte_size(job["command"]) <= 2_048
    refute job["command"] =~ "sk-private-token-123456"

    assert Map.keys(job) |> Enum.sort() ==
             ~w(command endedAt exitCode id launch ownerId startedAt status)

    assert result["agents"] == [
             %{"id" => "child-1", "parentId" => "root-1", "name" => "reviewer"}
           ]

    refute inspect(result) =~ "must-not-leak"
    refute inspect(result) =~ "/Users/alice"
  end

  test "list caps jobs and reports totals; a cold session is live: false" do
    assert {:ok, %{"jobs" => jobs, "total" => 130, "truncated" => true}} =
             ProcessJobsList.handle(%{"sessionKey" => "agent:many:main"}, %{})

    assert length(jobs) == 100

    assert {:ok, %{"live" => false, "rootId" => nil, "jobs" => []}} =
             ProcessJobsList.handle(%{"sessionKey" => "agent:cold:main"}, %{})
  end

  test "malformed runtime data and failures are unavailable, never an empty list" do
    assert {:error, {:unavailable, _, %{"reason" => "unavailable"}}} =
             ProcessJobsList.handle(%{"sessionKey" => "agent:broken:main"}, %{})

    assert {:error, {:unavailable, _, _}} =
             ProcessJobsList.handle(%{"sessionKey" => "agent:down:main"}, %{})

    assert {:error, {:invalid_params, _, _}} = ProcessJobsList.handle(%{}, %{})
  end

  test "inspect bounds the tail, redacts output and validates the job id" do
    params = %{"sessionKey" => "agent:t:main", "jobId" => "job-1", "tailBytes" => 65_536}
    assert {:ok, %{"job" => job}} = ProcessJobsInspect.handle(params, %{})
    assert_received {:inspect, tail_bytes: 65_536}

    assert job["cwd"] == "/work"
    assert job["pids"] == [10]
    assert job["outputTruncated"] == true
    assert job["outputBytes"] == 100_042
    assert byte_size(job["output"]) <= 65_536
    refute job["output"] =~ "abcdef123456789012345"

    assert {:ok, _} =
             ProcessJobsInspect.handle(%{"sessionKey" => "agent:t:main", "jobId" => "job-1"}, %{})

    assert_received {:inspect, tail_bytes: 16_384}

    for bad <- [%{"tailBytes" => 65_537}, %{"tailBytes" => -1}, %{"jobId" => "../x"}] do
      params = Map.merge(%{"sessionKey" => "agent:t:main", "jobId" => "job-1"}, bad)
      assert {:error, {:invalid_params, _, _}} = ProcessJobsInspect.handle(params, %{})
    end

    assert {:error, {:not_found, _, %{"reason" => "not_found"}}} =
             ProcessJobsInspect.handle(
               %{"sessionKey" => "agent:other:main", "jobId" => "job-1"},
               %{}
             )
  end

  test "cancel reports acceptance, conflicts and never retries an unknown outcome" do
    params = %{"sessionKey" => "agent:t:main", "jobId" => "job-1"}

    assert {:ok, %{"cancelled" => true, "jobId" => "job-1", "job" => %{"status" => "killed"}}} =
             ProcessJobsCancel.handle(params, %{})

    assert_received :cancel_called
    refute_received :cancel_called

    assert {:error, {:conflict, _, %{"reason" => "already_terminal"}}} =
             ProcessJobsCancel.handle(%{params | "jobId" => "done"}, %{})

    assert {:error, {:unavailable, _, %{"reason" => "outcome_unknown", "retrySafe" => false}}} =
             ProcessJobsCancel.handle(%{params | "jobId" => "stuck"}, %{})

    # A provider that crashed or answered nonsense may already have acted.
    for id <- ["crash", "garbage"] do
      assert {:error, {:unavailable, _, %{"reason" => "outcome_unknown", "retrySafe" => false}}} =
               ProcessJobsCancel.handle(%{params | "jobId" => id}, %{})
    end

    assert {:error, {:not_found, _, _}} =
             ProcessJobsCancel.handle(%{params | "sessionKey" => "agent:other:main"}, %{})
  end
end
