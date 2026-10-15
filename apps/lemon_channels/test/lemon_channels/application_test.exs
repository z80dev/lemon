defmodule LemonChannels.ApplicationTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Application

  @moduledoc """
  Tests for LemonChannels.Application adapter startup functionality.
  """

  describe "register_and_start_adapter/2" do
    test "registers adapter plugin" do
      defmodule TestAdapter do
        @behaviour LemonChannels.Plugin

        @impl true
        def id, do: "application-test-adapter"

        @impl true
        def meta do
          %{
            label: "Test Adapter",
            capabilities: %{chunk_limit: 4096},
            docs: nil
          }
        end

        @impl true
        def child_spec(_opts) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> %{} end, [name: __MODULE__]]},
            type: :worker
          }
        end

        @impl true
        def normalize_inbound(_raw), do: {:error, :not_implemented}

        @impl true
        def deliver(_payload), do: {:error, :not_implemented}

        @impl true
        def gateway_methods, do: []
      end

      assert :ok = Application.register_and_start_adapter(TestAdapter)
      pid = Process.whereis(TestAdapter)

      on_exit(fn ->
        DynamicSupervisor.terminate_child(LemonChannels.AdapterSupervisor, pid)
        LemonChannels.Registry.unregister(TestAdapter.id())
      end)

      assert LemonChannels.Registry.get_plugin(TestAdapter.id()) == TestAdapter
    end
  end

  describe "stop_adapter/1" do
    test "returns error for non-running adapter" do
      defmodule NonRunningAdapterWorker do
        use GenServer

        def start_link(_opts) do
          GenServer.start_link(__MODULE__, :ok)
        end

        @impl true
        def init(:ok), do: {:ok, %{}}
      end

      defmodule NonRunningAdapter do
        @behaviour LemonChannels.Plugin

        @impl true
        def id, do: "non-running-adapter"

        @impl true
        def meta, do: %{label: "Non-Running", capabilities: %{}, docs: nil}

        @impl true
        def child_spec(_opts),
          do: %{id: __MODULE__, start: {NonRunningAdapterWorker, :start_link, [[]]}}

        @impl true
        def normalize_inbound(_raw), do: {:error, :not_implemented}

        @impl true
        def deliver(_payload), do: {:error, :not_implemented}

        @impl true
        def gateway_methods, do: []
      end

      result = Application.stop_adapter(NonRunningAdapter)

      assert result == {:error, :not_running}
    end
  end
end
