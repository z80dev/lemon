defmodule LemonChannels.Adapters.Discord.RendererTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Renderer
  alias LemonChannels.{PresentationState, Registry}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  @gateway_config_key :"Elixir.LemonGateway.Config"

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

  test "dispatch/1 truncates Discord stream snapshots to one editable message" do
    route = route("peer-stream")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("s", 2_500)

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:snapshot",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :stream_snapshot,
        body: %{text: long_text, seq: 1}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: delivered_text,
                      meta: %{run_id: ^run_id}
                    }},
                   1_000

    assert String.length(delivered_text) == 1_900
    refute_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 150
  end

  test "dispatch/1 splits long Discord final edits into edit plus ordered follow-ups" do
    route = route("peer-final")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("f", 2_500)

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3301)

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:final",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: long_text, seq: 2},
        meta: %{user_msg_id: "origin-1"}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3301", text: first_chunk},
                      meta: %{run_id: ^run_id}
                    }},
                   1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: second_chunk,
                      reply_to: "origin-1",
                      meta: %{run_id: ^run_id}
                    }},
                   1_000

    assert String.length(first_chunk) == 1_900
    assert String.length(second_chunk) == 600
    assert first_chunk <> second_chunk == long_text
  end

  test "dispatch/1 suppresses repeated identical Discord final text with newer seq" do
    route = route("peer-repeat")
    run_id = "run-#{System.unique_integer([:positive])}"

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:final-a",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: "stable final", seq: 2}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "stable final"
                    }},
                   1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3301
           end)

    assert :ok =
             Renderer.dispatch(%DeliveryIntent{
               intent
               | intent_id: "#{run_id}:final-b",
                 body: %{text: "stable final", seq: 3}
             })

    refute_receive {:delivered, %LemonChannels.OutboundPayload{kind: :edit}}, 150
    refute_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 150
  end

  test "dispatch/1 does not suppress same Discord final text when files are added" do
    route = route("peer-repeat-file")
    run_id = "run-#{System.unique_integer([:positive])}"
    path = temp_file!("discord-renderer-late-file", "artifact")

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:final-a",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: "stable final", seq: 2}
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3301
           end)

    assert :ok =
             Renderer.dispatch(%DeliveryIntent{
               intent
               | intent_id: "#{run_id}:final-b",
                 body: %{text: "stable final", seq: 3},
                 meta: %{auto_send_files: [%{path: path, filename: "late.txt"}]}
             })

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{text: "stable final"}
                    }},
                   1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{path: ^path, filename: "late.txt"}
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

  test "dispatch/1 requires opt-in before auto-sending generated Discord files" do
    route = route("peer-5")
    run_id = "run-#{System.unique_integer([:positive])}"
    path = temp_file!("discord-renderer-generated-file", "hello")

    intent =
      %DeliveryIntent{
        intent_id: "#{run_id}:final",
        run_id: run_id,
        session_key: "agent:test:main",
        route: route,
        kind: :final_text,
        body: %{text: "done"},
        meta: %{
          auto_send_files: [
            %{
              "path" => path,
              "filename" => "generated.png",
              "caption" => "artifact",
              "source" => "generated"
            }
          ]
        }
      }

    assert :ok = Renderer.dispatch(intent)

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000
    refute_receive {:delivered, %LemonChannels.OutboundPayload{kind: :file}}, 150
  end

  test "dispatch/1 bounds generated Discord file auto-send by config" do
    route = route("peer-6")
    run_id = "run-#{System.unique_integer([:positive])}"
    first_path = temp_file!("discord-renderer-generated-first", "ok")
    second_path = temp_file!("discord-renderer-generated-second", "ok")
    oversized_path = temp_file!("discord-renderer-generated-oversized", "too-large")

    with_discord_files_config(
      %{
        enabled: true,
        auto_send_generated_images: true,
        auto_send_generated_max_files: 2,
        max_download_bytes: 3
      },
      fn ->
        intent =
          %DeliveryIntent{
            intent_id: "#{run_id}:final",
            run_id: run_id,
            session_key: "agent:test:main",
            route: route,
            kind: :final_text,
            body: %{text: "done"},
            meta: %{
              auto_send_files: [
                %{path: first_path, filename: "first.png", source: :generated},
                %{path: second_path, filename: "second.png", source: :generated},
                %{path: oversized_path, filename: "oversized.png", source: :generated}
              ]
            }
          }

        assert :ok = Renderer.dispatch(intent)
      end
    )

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{path: ^second_path, filename: "second.png"}
                    }},
                   1_000

    refute_receive {:delivered, %LemonChannels.OutboundPayload{kind: :file}}, 150
  end

  test "dispatch/1 auto-sends generated Discord media files behind files config" do
    route = route("peer-7")
    run_id = "run-#{System.unique_integer([:positive])}"
    path = temp_file!("discord-renderer-generated-video", "mp4")

    with_discord_files_config(
      %{
        enabled: true,
        auto_send_generated_files: true,
        auto_send_generated_max_files: 1,
        max_download_bytes: 20
      },
      fn ->
        intent =
          %DeliveryIntent{
            intent_id: "#{run_id}:final",
            run_id: run_id,
            session_key: "agent:test:main",
            route: route,
            kind: :final_text,
            body: %{text: "done"},
            meta: %{
              auto_send_files: [
                %{
                  path: path,
                  filename: "generated-preview.mp4",
                  caption: "video artifact",
                  source: :generated
                }
              ]
            }
          }

        assert :ok = Renderer.dispatch(intent)
      end
    )

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{
                        path: ^path,
                        filename: "generated-preview.mp4",
                        caption: "video artifact"
                      }
                    }},
                   1_000
  end

  test "dispatch/1 auto-sends generated Discord media files when final text edits existing message" do
    route = route("peer-8")
    run_id = "run-#{System.unique_integer([:positive])}"
    path = temp_file!("discord-renderer-generated-edit", "wav")

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3301)

    with_discord_files_config(
      %{
        enabled: true,
        auto_send_generated_files: true,
        auto_send_generated_max_files: 1,
        max_download_bytes: 20
      },
      fn ->
        intent =
          %DeliveryIntent{
            intent_id: "#{run_id}:final-edit",
            run_id: run_id,
            session_key: "agent:test:main",
            route: route,
            kind: :final_text,
            body: %{text: "done", seq: 2},
            meta: %{
              auto_send_files: [
                %{
                  path: path,
                  filename: "generated-preview.wav",
                  caption: "speech artifact",
                  source: :generated
                }
              ]
            }
          }

        assert :ok = Renderer.dispatch(intent)
      end
    )

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :edit}}, 1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :file,
                      content: %{
                        path: ^path,
                        filename: "generated-preview.wav",
                        caption: "speech artifact"
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

  defp temp_file!(prefix, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp with_discord_files_config(files_config, fun) do
    previous = Application.get_env(:lemon_gateway, @gateway_config_key)
    config = previous || %{}
    discord = Map.get(config, :discord) || Map.get(config, "discord") || %{}
    next = Map.put(config, :discord, Map.put(discord, :files, files_config))

    try do
      Application.put_env(:lemon_gateway, @gateway_config_key, next)
      fun.()
    after
      if previous == nil do
        Application.delete_env(:lemon_gateway, @gateway_config_key)
      else
        Application.put_env(:lemon_gateway, @gateway_config_key, previous)
      end
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts <= 0, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
