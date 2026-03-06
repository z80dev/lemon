defmodule LemonChannels.Adapters.Telegram.RendererTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Renderer
  alias LemonChannels.{PresentationState, Registry}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  defmodule TelegramRendererPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "telegram"

    @impl true
    def meta do
      %{
        label: "Telegram Renderer Test",
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
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:delivered, payload})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => 3101}}}
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :persistent_term.put({TelegramRendererPlugin, :notify_pid}, self())

    existing = Registry.get_plugin("telegram")
    _ = Registry.unregister("telegram")
    :ok = Registry.register(TelegramRendererPlugin)

    on_exit(fn ->
      :persistent_term.erase({TelegramRendererPlugin, :notify_pid})

      if is_pid(Process.whereis(Registry)) do
        _ = Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = Registry.register(existing)
        end
      end
    end)

    :ok
  end

  test "dispatch/1 truncates long telegram text before delivery" do
    route = route("321")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("a", 5_500)

    assert :ok = Renderer.dispatch(intent(run_id, route, :final_text, %{text: long_text}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: delivered_text
                    }},
                   1_000

    assert is_binary(delivered_text)
    assert String.length(delivered_text) <= 4_096
  end

  test "dispatch/1 sends then edits answer text using channels-owned presentation state" do
    route = route("654")
    run_id = "run-#{System.unique_integer([:positive])}"

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :stream_snapshot, %{text: "hello", seq: 1}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: "hello",
                      peer: %{id: "654"}
                    }},
                   1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3101
           end)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello world", seq: 2})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      content: %{message_id: "3101", text: text}
                    }},
                   1_000

    assert String.contains?(text, "hello world")
  end

  defp route(peer_id) do
    %DeliveryRoute{
      channel_id: "telegram",
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
