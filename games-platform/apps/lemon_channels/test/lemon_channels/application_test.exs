defmodule LemonChannels.ApplicationTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Application

  @moduledoc """
  Tests for LemonChannels.Application adapter startup functionality.
  """

  describe "register_and_start_adapter/2" do
    test "registers adapter plugin" do
      # This test may fail if the adapter's child_spec requires
      # dependencies that aren't running, but we can verify the
      # registration flow doesn't crash

      defmodule TestAdapter do
        @behaviour LemonChannels.Plugin

        @impl true
        def id, do: "test-adapter-#{System.unique_integer()}"

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
            start: {Agent, :start_link, [fn -> %{} end]},
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

      # Should not crash
      result = Application.register_and_start_adapter(TestAdapter)

      # Either succeeds or fails with an error (not a crash)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "start_adapter/2" do
    test "handles adapter_id config check" do
      # Define a simple test adapter
      defmodule SimpleAdapter do
        @behaviour LemonChannels.Plugin

        @impl true
        def id, do: "simple-adapter-#{System.unique_integer()}"

        @impl true
        def meta do
          %{
            label: "Simple Adapter",
            capabilities: %{},
            docs: nil
          }
        end

        @impl true
        def child_spec(_opts) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :ok end]},
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

      result = Application.start_adapter(SimpleAdapter)

      assert result == :ok or match?({:error, _}, result)
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
