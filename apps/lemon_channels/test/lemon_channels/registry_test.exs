defmodule LemonChannels.RegistryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Registry

  describe "get_plugin/1 resilience" do
    test "returns nil when registry process is not running" do
      # Stop the Registry if it's currently running so we can test the
      # catch :exit fallback that protects the message-routing hot path.
      #
      # We stop the entire application supervisor tree to prevent automatic
      # restarts, then call get_plugin while the process is down.
      stop_registry!()

      # With the Registry down, get_plugin must return nil (not crash).
      assert Registry.get_plugin("nonexistent_plugin") == nil

      # Restart the Registry so other tests are not affected.
      ensure_registry_started()
    end

    test "returns nil for unknown plugin when registry is running" do
      ensure_registry_started()

      assert Registry.get_plugin("unknown_plugin_id_#{System.unique_integer()}") == nil
    end
  end

  describe "get_meta/1 resilience" do
    test "returns nil when registry process is not running" do
      stop_registry!()

      # get_meta delegates to get_plugin, so it should also return nil
      # when the registry is unavailable.
      assert Registry.get_meta("nonexistent_plugin") == nil

      ensure_registry_started()
    end
  end

  describe "get_capabilities/1 resilience" do
    test "returns nil when registry process is not running" do
      stop_registry!()

      # get_capabilities delegates through get_meta -> get_plugin, so it
      # should also return nil when the registry is unavailable.
      assert Registry.get_capabilities("nonexistent_plugin") == nil

      ensure_registry_started()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Temporarily unregister the Registry name so GenServer.call exits with
  # :noproc.  We cannot simply GenServer.stop because the supervision tree
  # restarts it immediately.
  defp stop_registry! do
    pid = Process.whereis(Registry)

    if pid do
      Process.unregister(Registry)
      # The process itself is still alive under its supervisor, but calling
      # GenServer.call(Registry, ...) will now fail with :noproc because the
      # name is unregistered.  We'll re-register in ensure_registry_started.
    end
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      pid when is_pid(pid) ->
        # Already registered and running, nothing to do.
        :ok

      nil ->
        # The process may still be alive under the supervisor but unnamed.
        # Walk the supervisor children to find it and re-register.
        children =
          try do
            Supervisor.which_children(LemonChannels.Supervisor)
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end

        registry_child =
          Enum.find(children, fn
            {LemonChannels.Registry, pid, _, _} when is_pid(pid) -> Process.alive?(pid)
            _ -> false
          end)

        case registry_child do
          {_, pid, _, _} ->
            try do
              Process.register(pid, Registry)
            rescue
              ArgumentError -> :ok
            end

          nil ->
            # Process was terminated; start fresh.
            case Registry.start_link([]) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
            end
        end
    end
  end
end
