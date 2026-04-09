defmodule LemonChannels.Adapters.Discord.RendererTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Renderer
  alias LemonChannels.Registry
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  defmodule FakeDiscordPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "discord"

    @impl true
    def meta do
      %{
        label: "Discord Renderer Test",
        capabilities: %{
          edit_support: true,
          delete_support: true,
          chunk_limit: 2000,
          reaction_support: true,
          thread_support: true
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

      {:ok, %{message_id: 3301}}
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :persistent_term.put({FakeDiscordPlugin, :notify_pid}, self())

    _ = Registry.unregister("discord")

    case Registry.register(FakeDiscordPlugin) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    on_exit(fn ->
      :persistent_term.erase({FakeDiscordPlugin, :notify_pid})
      _ = Registry.unregister("discord")
    end)

    :ok
  end

  test "dispatch/1 adds Discord status components to routed status messages" do
    route = route("peer-1")
    run_id = "run-#{System.unique_integer([:positive])}"

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:status",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :tool_status_snapshot,
        controls: %{allow_cancel?: true},
        body: %{text: "Working", seq: 1}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text, meta: meta}}, 1_000
    assert [%{components: [%{custom_id: custom_id}]}] = meta[:components]
    assert custom_id == "lemon:cancel:" <> run_id
  end

  test "dispatch/1 preserves thread routing for Discord outbound payloads" do
    route = route("peer-2", "thread-9")
    run_id = "run-#{System.unique_integer([:positive])}"

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:answer",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: "Hello thread"}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      peer: %{id: "peer-2", thread_id: "thread-9"}
                    }},
                   1_000
  end

  test "dispatch/1 enqueues Discord file payloads for attachments" do
    route = route("peer-3")
    run_id = "run-#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "discord-renderer-file-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:files",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :file_batch,
        attachments: [%{path: path, filename: "out.txt", caption: "artifact"}]
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{path: ^path, filename: "out.txt", caption: "artifact"}
                    }},
                   1_000
  end

  test "dispatch/1 auto-sends files from finalize metadata" do
    route = route("peer-4")
    run_id = "run-#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "discord-renderer-auto-file-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:final",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: "done"},
        meta: %{
          auto_send_files: [%{path: path, filename: "discord_file_test.txt", caption: "artifact"}]
        }
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{
                        path: ^path,
                        filename: "discord_file_test.txt",
                        caption: "artifact"
                      }
                    }},
                   1_000
  end

  defp route(peer_id, thread_id \\ nil) do
    %DeliveryRoute{
      channel_id: "discord",
      account_id: "default",
      peer_kind: :group,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end
end
