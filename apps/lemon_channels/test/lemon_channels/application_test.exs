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
      assert is_pid(Process.whereis(TestAdapter))

      on_exit(fn ->
        Application.stop_adapter(TestAdapter)
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

  # #699: WhatsApp shipped in the adapter list with no config path that could
  # start it, yet status reported it as configured. It was retired; these pin
  # that every shipped adapter stays startable from canonical config.
  describe "shipped adapter list" do
    @root Path.expand("../../../..", __DIR__)

    setup do
      config = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)

      config_ids =
        for module <- get_in(config, [:lemon_core, :gateway_channels]),
            Code.ensure_loaded?(module),
            do: Atom.to_string(module.id())

      # Email reads its `[gateway.email]` block through `Email.Config` rather
      # than the per-platform registry.
      %{adapters: get_in(config, [:lemon_channels, :adapters]), startable: ["email" | config_ids]}
    end

    test "every shipped adapter has a canonical config path that can start it", ctx do
      assert ctx.adapters != []

      for adapter <- ctx.adapters do
        assert adapter.id() in ctx.startable,
               "#{inspect(adapter)} ships without a [gateway.#{adapter.id()}] config path"
      end
    end

    test "status reports no shipped channel that cannot start as configured", ctx do
      registered =
        for adapter <- ctx.adapters, LemonChannels.Registry.register(adapter) == :ok, do: adapter

      on_exit(fn -> Enum.each(registered, &LemonChannels.Registry.unregister(&1.id())) end)

      %{configured: configured} = LemonChannels.Registry.status()
      shipped = Enum.map(ctx.adapters, & &1.id())

      assert shipped -- configured == []
      assert Enum.all?(shipped, &(&1 in ctx.startable))
      refute "whatsapp" in configured
    end
  end
end
