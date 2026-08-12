defmodule LemonCore.SubagentRegistryTest do
  use ExUnit.Case, async: false

  alias LemonCore.EngineCatalog
  alias LemonCore.SubagentRegistry
  alias LemonCore.SubagentRunner

  doctest LemonCore.SubagentRunner

  defmodule Good do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-good"

    @impl true
    def describe, do: %{summary: "A test runner", caveats: ["ignores everything"]}

    @impl true
    def routable?, do: false

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: [{:completed, "done", ok: true}]
  end

  defmodule Replacement do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-good"

    @impl true
    def describe, do: %{summary: "The replacement", caveats: []}

    @impl true
    def routable?, do: false

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule Restricted do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-restricted"

    @impl true
    def describe, do: %{summary: "Runs elsewhere"}

    @impl true
    def routable?, do: false

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule Privileged do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-privileged"

    @impl true
    def describe, do: %{summary: "Runs here"}

    @impl true
    def default_policy, do: :full_access

    @impl true
    def routable?, do: false

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule Routable do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-routable"

    @impl true
    def describe, do: %{summary: "Also a gateway engine"}

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule ReservedId do
    @behaviour SubagentRunner

    @impl true
    def id, do: "help"

    @impl true
    def describe, do: %{summary: "Squats a reserved id"}

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule BadDescription do
    @behaviour SubagentRunner

    @impl true
    def id, do: "test-bad-description"

    @impl true
    def describe, do: %{summary: "line one\nline two"}

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  defmodule Raises do
    @behaviour SubagentRunner

    @impl true
    def id, do: raise("boom")

    @impl true
    def describe, do: %{summary: "never gets asked"}

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def events(_session), do: []
  end

  setup do
    original = Application.fetch_env(:lemon_core, :subagent_runners)
    original_engines = Application.fetch_env(:lemon_core, :known_engines)
    registered_before = MapSet.new(SubagentRegistry.list_ids())

    on_exit(fn ->
      Enum.each(SubagentRegistry.list_ids(), fn id ->
        unless MapSet.member?(registered_before, id), do: SubagentRegistry.unregister(id)
      end)

      restore(:subagent_runners, original)
      restore(:known_engines, original_engines)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:lemon_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:lemon_core, key)

  describe "register/1" do
    test "makes a runner findable by id, with its own description" do
      assert SubagentRegistry.register(Good) == :ok
      assert SubagentRegistry.module("test-good") == Good
      assert "test-good" in SubagentRegistry.list_ids()

      assert {:ok, entry} = SubagentRegistry.fetch("test-good")
      assert entry.summary == "A test runner"
      assert entry.caveats == ["ignores everything"]
    end

    test "is idempotent" do
      assert SubagentRegistry.register(Good) == :ok
      assert SubagentRegistry.register(Good) == :ok

      assert Enum.count(SubagentRegistry.list_ids(), &(&1 == "test-good")) == 1
    end

    test "replaces the module holding an id" do
      assert SubagentRegistry.register(Good) == :ok
      assert SubagentRegistry.register(Replacement) == :ok

      assert SubagentRegistry.module("test-good") == Replacement
      assert Enum.count(SubagentRegistry.list_ids(), &(&1 == "test-good")) == 1
    end

    test "preserves registration order" do
      assert SubagentRegistry.register(Good) == :ok
      assert SubagentRegistry.register(Restricted) == :ok
      assert SubagentRegistry.register(Privileged) == :ok

      ids = SubagentRegistry.list_ids()

      assert Enum.find_index(ids, &(&1 == "test-good")) <
               Enum.find_index(ids, &(&1 == "test-restricted"))

      assert Enum.find_index(ids, &(&1 == "test-restricted")) <
               Enum.find_index(ids, &(&1 == "test-privileged"))
    end

    test "persists the module list so a registry restart rebuilds it" do
      assert SubagentRegistry.register(Good) == :ok
      assert Good in Application.get_env(:lemon_core, :subagent_runners, [])
    end

    test "rejects a reserved id" do
      assert {:error, {:reserved_id, "help"}} = SubagentRegistry.register(ReservedId)
      refute "help" in SubagentRegistry.list_ids()
    end

    test "rejects a description the tool prose cannot render" do
      assert {:error, {:multiline, :summary}} = SubagentRegistry.register(BadDescription)
      refute "test-bad-description" in SubagentRegistry.list_ids()
    end

    test "survives a runner that raises in id/0" do
      assert {:error, {:invalid_id, nil}} = SubagentRegistry.register(Raises)
      assert Process.alive?(Process.whereis(SubagentRegistry))
    end

    test "rejects a module that is not a runner at all" do
      assert {:error, :not_loaded} = SubagentRegistry.register(NoSuchRunnerModule)
    end
  end

  describe "policy/1" do
    test "defaults to :subagent_restricted" do
      assert SubagentRegistry.register(Restricted) == :ok
      assert SubagentRegistry.policy("test-restricted") == :subagent_restricted
      assert SubagentRunner.default_policy() == :subagent_restricted
    end

    test "honours a runner's override" do
      assert SubagentRegistry.register(Privileged) == :ok
      assert SubagentRegistry.policy("test-privileged") == :full_access
    end

    test "is nil for an unregistered id" do
      assert SubagentRegistry.policy("nope") == nil
    end
  end

  describe "engine catalog sync" do
    test "a routable runner's id becomes a known engine" do
      refute EngineCatalog.known?("test-routable")

      assert SubagentRegistry.register(Routable) == :ok

      assert EngineCatalog.known?("test-routable")
    end

    test "a non-routable runner's id stays out of the catalog" do
      assert SubagentRegistry.register(Restricted) == :ok

      refute EngineCatalog.known?("test-restricted")
    end

    test "the static catalog stays the floor" do
      assert SubagentRegistry.register(Routable) == :ok

      assert EngineCatalog.known?("lemon")
      assert EngineCatalog.known?("codex")
    end
  end

  describe "unregister/1" do
    test "removes the runner" do
      assert SubagentRegistry.register(Good) == :ok
      assert SubagentRegistry.unregister("test-good") == :ok

      assert SubagentRegistry.module("test-good") == nil
      assert SubagentRegistry.fetch("test-good") == :error
    end

    test "is fine for an id that was never registered" do
      assert SubagentRegistry.unregister("never-registered") == :ok
    end
  end

  describe "fetch/1" do
    test "answers :error for a non-binary id" do
      assert SubagentRegistry.fetch(:codex) == :error
      assert SubagentRegistry.fetch(nil) == :error
    end
  end
end
