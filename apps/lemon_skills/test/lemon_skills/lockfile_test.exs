defmodule LemonSkills.LockfileTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Lockfile

  @moduletag :tmp_dir

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Resolve the lockfile path within the temp directory for :global scope.
  defp global_scope(tmp_dir), do: {:project, Path.join(tmp_dir, "global")}

  defp project_scope(tmp_dir), do: {:project, Path.join(tmp_dir, "project")}

  defp sample_record(key \\ "my-skill") do
    %{
      "key" => key,
      "source_kind" => "git",
      "source_id" => "https://github.com/acme/#{key}",
      "trust_level" => "community",
      "content_hash" => "abc123",
      "upstream_hash" => "def456",
      "installed_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-01T00:00:00Z",
      "audit_status" => "pass",
      "audit_findings" => []
    }
  end

  # ---------------------------------------------------------------------------
  # path/1
  # ---------------------------------------------------------------------------

  describe "path/1" do
    test ":global scope returns path under agent_dir" do
      path = Lockfile.path(:global)
      assert String.ends_with?(path, "skills.lock.json")
    end

    test "{:project, cwd} scope returns path under cwd/.lemon" do
      path = Lockfile.path({:project, "/home/user/myproject"})
      assert path == "/home/user/myproject/.lemon/skills.lock.json"
    end
  end

  # ---------------------------------------------------------------------------
  # read/1
  # ---------------------------------------------------------------------------

  describe "read/1" do
    test "returns empty map when lockfile does not exist", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      assert {:ok, %{}} = Lockfile.read(scope)
    end

    test "reads a valid lockfile", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record())

      assert {:ok, skills} = Lockfile.read(scope)
      assert Map.has_key?(skills, "my-skill")
    end

    test "returns empty map for lockfile with missing skills key", %{tmp_dir: tmp_dir} do
      path = Lockfile.path(global_scope(tmp_dir))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"version" => 1}))

      assert {:ok, %{}} = Lockfile.read(global_scope(tmp_dir))
    end

    test "returns error for malformed JSON", %{tmp_dir: tmp_dir} do
      path = Lockfile.path(global_scope(tmp_dir))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json {{{")

      assert {:error, {:json_decode, _}} = Lockfile.read(global_scope(tmp_dir))
    end
  end

  # ---------------------------------------------------------------------------
  # get/2
  # ---------------------------------------------------------------------------

  describe "get/2" do
    test "returns :not_found when lockfile absent", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      assert :not_found = Lockfile.get(scope, "missing-skill")
    end

    test "returns :not_found when key absent", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record("other-skill"))

      assert :not_found = Lockfile.get(scope, "missing-skill")
    end

    test "returns {:ok, record} when key present", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      record = sample_record()
      :ok = Lockfile.put(scope, record)

      assert {:ok, fetched} = Lockfile.get(scope, "my-skill")
      assert fetched["source_kind"] == "git"
      assert fetched["trust_level"] == "community"
    end
  end

  # ---------------------------------------------------------------------------
  # put/2
  # ---------------------------------------------------------------------------

  describe "put/2" do
    test "creates lockfile with single record", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record())

      assert {:ok, skills} = Lockfile.read(scope)
      assert Map.has_key?(skills, "my-skill")
    end

    test "overwrites existing record", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record())
      updated = Map.put(sample_record(), "content_hash", "newHash")
      :ok = Lockfile.put(scope, updated)

      assert {:ok, fetched} = Lockfile.get(scope, "my-skill")
      assert fetched["content_hash"] == "newHash"
    end

    test "adds multiple records independently", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record("skill-a"))
      :ok = Lockfile.put(scope, sample_record("skill-b"))

      assert {:ok, skills} = Lockfile.read(scope)
      assert Map.has_key?(skills, "skill-a")
      assert Map.has_key?(skills, "skill-b")
    end

    test "writes a versioned JSON file", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record())

      path = Lockfile.path(scope)
      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      assert decoded["version"] == 1
      assert is_map(decoded["skills"])
    end

    test "creates parent directory when absent", %{tmp_dir: tmp_dir} do
      scope = {:project, Path.join(tmp_dir, "new_project")}
      assert :ok = Lockfile.put(scope, sample_record())
      assert File.exists?(Lockfile.path(scope))
    end
  end

  # ---------------------------------------------------------------------------
  # delete/2
  # ---------------------------------------------------------------------------

  describe "delete/2" do
    test "removes an existing record", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record())
      :ok = Lockfile.delete(scope, "my-skill")

      assert :not_found = Lockfile.get(scope, "my-skill")
    end

    test "returns :ok when key does not exist", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      assert :ok = Lockfile.delete(scope, "nonexistent")
    end

    test "leaves other records intact", %{tmp_dir: tmp_dir} do
      scope = global_scope(tmp_dir)
      :ok = Lockfile.put(scope, sample_record("skill-a"))
      :ok = Lockfile.put(scope, sample_record("skill-b"))
      :ok = Lockfile.delete(scope, "skill-a")

      assert :not_found = Lockfile.get(scope, "skill-a")
      assert {:ok, _} = Lockfile.get(scope, "skill-b")
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent write safety
  # ---------------------------------------------------------------------------

  describe "concurrent writes" do
    test "all records survive when multiple tasks write simultaneously", %{tmp_dir: tmp_dir} do
      scope = {:project, Path.join(tmp_dir, "concurrent")}
      num_writers = 10
      keys = Enum.map(1..num_writers, fn i -> "concurrent-skill-#{i}" end)

      tasks = Enum.map(keys, fn key ->
        Task.async(fn -> Lockfile.put(scope, sample_record(key)) end)
      end)

      Enum.each(tasks, &Task.await/1)

      {:ok, skills} = Lockfile.read(scope)
      missing = Enum.reject(keys, &Map.has_key?(skills, &1))
      assert missing == [], "missing records after concurrent writes: #{inspect(missing)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Scope isolation
  # ---------------------------------------------------------------------------

  describe "scope isolation" do
    test "global and project scopes are independent", %{tmp_dir: tmp_dir} do
      global = global_scope(tmp_dir)
      project = project_scope(tmp_dir)

      :ok = Lockfile.put(global, sample_record("global-skill"))
      :ok = Lockfile.put(project, sample_record("project-skill"))

      assert {:ok, _} = Lockfile.get(global, "global-skill")
      assert :not_found = Lockfile.get(global, "project-skill")

      assert {:ok, _} = Lockfile.get(project, "project-skill")
      assert :not_found = Lockfile.get(project, "global-skill")
    end
  end
end
