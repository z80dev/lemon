defmodule LemonMemory.ApplicationTest do
  use ExUnit.Case, async: true

  describe "supervision tree" do
    test "starts the provider registry and the SQLite-backed store" do
      children = Supervisor.which_children(LemonMemory.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert LemonMemory.Providers in child_ids

      # exqlite is a direct dependency of this app, so the store and its ingest
      # pipeline are expected to be running.
      assert Code.ensure_loaded?(Exqlite.Sqlite3)
      assert LemonMemory.Store in child_ids
      assert LemonMemory.Ingest in child_ids

      for {_id, pid, type, _modules} <- children do
        assert is_pid(pid)
        assert type == :worker
      end
    end

    test "the store reads its configuration under the :lemon_memory app" do
      # The extraction moved this key out of :lemon_core; config/test.exs points
      # it at a per-run tmp dir so suites never touch the developer's database.
      assert Application.get_env(:lemon_memory, LemonMemory.Store, [])[:path] != nil
    end
  end
end
