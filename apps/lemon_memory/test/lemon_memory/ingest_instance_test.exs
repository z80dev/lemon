defmodule LemonMemory.IngestInstanceTest do
  @moduledoc """
  Two `LemonMemory.Ingest` workers must be able to run side by side in one node:
  distinct registered names, per-instance feature-flag caches, and documents
  landing only in the store the instance was handed.
  """

  use ExUnit.Case, async: false

  alias LemonCore.Config.Features
  alias LemonMemory.Ingest
  alias LemonMemory.Store

  @moduletag :tmp_dir

  describe "two named ingest workers in one node" do
    setup %{tmp_dir: tmp_dir} do
      alpha_store = start_store(tmp_dir, :ingest_instance_alpha_store)
      beta_store = start_store(tmp_dir, :ingest_instance_beta_store)

      alpha_counter = :counters.new(1, [:atomics])
      beta_counter = :counters.new(1, [:atomics])

      alpha =
        start_ingest(:ingest_instance_alpha,
          memory_store: alpha_store,
          config_loader: counting_loader(alpha_counter)
        )

      beta =
        start_ingest(:ingest_instance_beta,
          memory_store: beta_store,
          config_loader: counting_loader(beta_counter)
        )

      %{
        alpha: alpha,
        beta: beta,
        alpha_store: alpha_store,
        beta_store: beta_store,
        alpha_counter: alpha_counter,
        beta_counter: beta_counter
      }
    end

    test "each worker registers under its own name", %{alpha: alpha, beta: beta} do
      alpha_pid = Process.whereis(alpha)
      beta_pid = Process.whereis(beta)

      assert is_pid(alpha_pid)
      assert is_pid(beta_pid)
      assert alpha_pid != beta_pid
    end

    test "documents land only in the instance's own store", %{
      alpha: alpha,
      alpha_store: alpha_store,
      beta_store: beta_store
    } do
      {run_id, record, summary} = make_ingest_args("alpha")

      Ingest.ingest(alpha, run_id, record, summary)
      :sys.get_state(Process.whereis(alpha))

      assert [doc] = Store.get_by_session(alpha_store, summary.session_key, limit: 10)
      assert doc.run_id == run_id
      assert Store.get_by_session(beta_store, summary.session_key, limit: 10) == []
    end

    test "the finalize-run hook routes to the bound instance", %{
      beta_store: beta_store,
      alpha_store: alpha_store
    } do
      {run_id, record, summary} = make_ingest_args("beta")

      # This is the shape a second instance registers with LemonCore.Store.Hooks:
      # {LemonMemory.Ingest, :handle_finalize_run, [:ingest_instance_beta]}.
      assert :ok =
               Ingest.handle_finalize_run(:ingest_instance_beta, %{
                 run_id: run_id,
                 record: record,
                 summary: summary
               })

      :sys.get_state(Process.whereis(:ingest_instance_beta))

      assert [doc] = Store.get_by_session(beta_store, summary.session_key, limit: 10)
      assert doc.run_id == run_id
      assert Store.get_by_session(alpha_store, summary.session_key, limit: 10) == []
    end

    test "feature-flag caches are per instance", %{
      alpha: alpha,
      beta: beta,
      alpha_counter: alpha_counter,
      beta_counter: beta_counter
    } do
      for i <- 1..3 do
        {_run_id, record, summary} = make_ingest_args("alpha")
        Ingest.ingest(alpha, "run_alpha_#{i}", record, summary)
      end

      {_run_id, record, summary} = make_ingest_args("beta")
      Ingest.ingest(beta, "run_beta_1", record, summary)

      :sys.get_state(Process.whereis(alpha))
      :sys.get_state(Process.whereis(beta))

      # One TTL-cached load each: neither worker sees the other's cache.
      assert :counters.get(alpha_counter, 1) == 1
      assert :counters.get(beta_counter, 1) == 1
    end
  end

  describe "configuration" do
    test "falls back to the application env", %{tmp_dir: tmp_dir} do
      env_store = start_store(tmp_dir, :ingest_instance_env_store)

      Application.put_env(:lemon_memory, Ingest, memory_store: env_store)
      on_exit(fn -> Application.delete_env(:lemon_memory, Ingest) end)

      name =
        start_ingest(:ingest_instance_env,
          config_loader: counting_loader(:counters.new(1, [:atomics]))
        )

      {run_id, record, summary} = make_ingest_args("env")
      Ingest.ingest(name, run_id, record, summary)
      :sys.get_state(Process.whereis(name))

      assert [doc] = Store.get_by_session(env_store, summary.session_key, limit: 10)
      assert doc.run_id == run_id
    end

    test "start_link opts win over the application env", %{tmp_dir: tmp_dir} do
      env_store = start_store(tmp_dir, :ingest_instance_precedence_env_store)
      opts_store = start_store(tmp_dir, :ingest_instance_precedence_opts_store)

      Application.put_env(:lemon_memory, Ingest, memory_store: env_store)
      on_exit(fn -> Application.delete_env(:lemon_memory, Ingest) end)

      name =
        start_ingest(:ingest_instance_precedence,
          memory_store: opts_store,
          config_loader: counting_loader(:counters.new(1, [:atomics]))
        )

      {run_id, record, summary} = make_ingest_args("precedence")
      Ingest.ingest(name, run_id, record, summary)
      :sys.get_state(Process.whereis(name))

      assert [doc] = Store.get_by_session(opts_store, summary.session_key, limit: 10)
      assert doc.run_id == run_id
      assert Store.get_by_session(env_store, summary.session_key, limit: 10) == []
    end

    test "config_ttl_ms is honoured per instance", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir, :ingest_instance_ttl_store)
      counter = :counters.new(1, [:atomics])

      name =
        start_ingest(:ingest_instance_ttl,
          memory_store: store,
          config_loader: counting_loader(counter),
          config_ttl_ms: 0
        )

      for i <- 1..3 do
        {_run_id, record, summary} = make_ingest_args("ttl")
        Ingest.ingest(name, "run_ttl_#{i}", record, summary)
      end

      :sys.get_state(Process.whereis(name))

      assert :counters.get(counter, 1) == 3
    end
  end

  describe "addressing an instance is unambiguous" do
    test "the default worker keeps the module name" do
      assert is_pid(Process.whereis(Ingest))
    end

    test "a second worker cannot claim the default name" do
      assert {:error, {:already_started, pid}} = Ingest.start_link([])
      assert pid == Process.whereis(Ingest)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_store(tmp_dir, name) do
    spec =
      Supervisor.child_spec({Store, name: name, path: Path.join(tmp_dir, to_string(name))},
        id: name
      )

    start_supervised!(spec)
    name
  end

  defp start_ingest(name, opts) do
    spec = Supervisor.child_spec({Ingest, Keyword.put(opts, :name, name)}, id: name)
    start_supervised!(spec)
    name
  end

  # Counts loads so a test can prove one worker's TTL cache is not the other's.
  defp counting_loader(counter) do
    fn ->
      :counters.add(counter, 1, 1)
      %{features: %Features{session_search: :"default-on", routing_feedback: :off}}
    end
  end

  defp make_ingest_args(tag) do
    run_id = "run_ingest_instance_#{tag}_#{:erlang.unique_integer([:positive])}"

    record = %{events: [], started_at: System.system_time(:millisecond)}

    summary = %{
      session_key: "agent:ingest_instance_#{tag}:main",
      agent_id: "ingest_instance_#{tag}",
      prompt: "implement the feature",
      completed: %{ok: true, answer: "Done."},
      provider: "anthropic",
      model: "claude-sonnet-4-6"
    }

    {run_id, record, summary}
  end
end
