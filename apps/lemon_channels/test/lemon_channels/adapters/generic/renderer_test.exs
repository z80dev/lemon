defmodule LemonChannels.Adapters.Generic.RendererTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Generic.Renderer
  alias LemonChannels.{PresentationState, Registry}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  defmodule GenericTextPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "generic-renderer-text"

    @impl true
    def meta do
      %{
        label: "Generic Renderer Text Test",
        capabilities: %{
          edit_support: false,
          chunk_limit: 4096
        },
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(payload) do
      maybe_notify(payload)
      {:ok, %{"ok" => true, "result" => %{"message_id" => 2101}}}
    end

    @impl true
    def gateway_methods, do: []

    defp maybe_notify(payload) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:delivered, payload})
      end
    end
  end

  defmodule GenericEditPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "generic-renderer-edit"

    @impl true
    def meta do
      %{
        label: "Generic Renderer Edit Test",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        },
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(payload) do
      maybe_notify(payload)
      {:ok, %{"ok" => true, "result" => %{"message_id" => 2201}}}
    end

    @impl true
    def gateway_methods, do: []

    defp maybe_notify(payload) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:delivered, payload})
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :persistent_term.put({GenericTextPlugin, :notify_pid}, self())
    :persistent_term.put({GenericEditPlugin, :notify_pid}, self())

    for plugin <- [GenericTextPlugin, GenericEditPlugin] do
      case Registry.register(plugin) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
      end
    end

    on_exit(fn ->
      :persistent_term.erase({GenericTextPlugin, :notify_pid})
      :persistent_term.erase({GenericEditPlugin, :notify_pid})
      _ = Registry.unregister(GenericTextPlugin.id())
      _ = Registry.unregister(GenericEditPlugin.id())
    end)

    :ok
  end

  test "dispatch/1 sends semantic text intent through the generic renderer" do
    route = route("generic-renderer-text", "peer-1")
    run_id = "run-#{System.unique_integer([:positive])}"

    intent =
      intent(run_id, route, :final_text, %{text: "hello generic"})

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "generic-renderer-text",
                      kind: :text,
                      content: "hello generic",
                      peer: %{id: "peer-1"}
                    }},
                   1_000
  end

  test "dispatch/1 uses edit delivery after the first create on edit-capable channels" do
    route = route("generic-renderer-edit", "peer-2")
    run_id = "run-#{System.unique_integer([:positive])}"

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :stream_snapshot, %{text: "hello", seq: 1}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "generic-renderer-edit",
                      kind: :text,
                      content: "hello"
                    }},
                   1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 2201
           end)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello again", seq: 2})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "generic-renderer-edit",
                      kind: :edit,
                      content: %{message_id: "2201", text: "hello again"}
                    }},
                   1_000
  end

  defp route(channel_id, peer_id) do
    %DeliveryRoute{
      channel_id: channel_id,
      account_id: "default",
      peer_kind: :dm,
      peer_id: peer_id
    }
  end

  defp intent(run_id, route, kind, body) do
    %DeliveryIntent{
      intent_id: "#{run_id}:#{kind}:#{System.unique_integer([:positive])}",
      run_id: run_id,
      session_key: "agent:test:main",
      route: route,
      kind: kind,
      body: body
    }
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts <= 0, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
