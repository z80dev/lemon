defmodule LemonChannels.Adapters.Discord.OutboundTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Outbound
  alias LemonChannels.OutboundPayload

  defmodule MockMessageApi do
    def create(channel_id, params) do
      send(self(), {:create, channel_id, params})
      {:ok, %{id: 4444}}
    end

    def edit(channel_id, message_id, params) do
      send(self(), {:edit, channel_id, message_id, params})
      {:ok, %{id: message_id}}
    end

    def delete(channel_id, message_id) do
      send(self(), {:delete, channel_id, message_id})
      {:ok, %{}}
    end

    def react(channel_id, message_id, emoji) do
      send(self(), {:react, channel_id, message_id, emoji})
      {:ok}
    end

    def unreact(channel_id, message_id, emoji) do
      send(self(), {:unreact, channel_id, message_id, emoji})
      {:ok}
    end
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    old = Application.get_env(:lemon_gateway, @gateway_config_key)
    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: MockMessageApi}
    })

    on_exit(fn ->
      Application.delete_env(:lemon_core, :config_test_mode)

      if old == nil do
        Application.delete_env(:lemon_gateway, @gateway_config_key)
      else
        Application.put_env(:lemon_gateway, @gateway_config_key, old)
      end
    end)

    :ok
  end

  test "text delivery posts to the Discord thread channel when thread_id is present" do
    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: "456"},
        kind: :text,
        content: "hello"
      }

    assert {:ok, %{message_id: 4444}} = Outbound.deliver(payload)
    assert_receive {:create, 456, %{content: "hello"}}
  end

  test "file delivery uploads the actual file instead of sending a path notice" do
    path =
      Path.join(System.tmp_dir!(), "discord-outbound-#{System.unique_integer([:positive])}.txt")

    File.write!(path, "artifact")
    on_exit(fn -> File.rm(path) end)

    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: "456"},
        kind: :file,
        content: %{path: path, filename: "artifact.txt", caption: "artifact ready"}
      }

    assert {:ok, %{message_id: 4444}} = Outbound.deliver(payload)

    assert_receive {:create, 456,
                    %{
                      content: "artifact ready",
                      files: [%{body: "artifact", name: "artifact.txt"}]
                    }}
  end

  test "edit delivery preserves Discord components" do
    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: nil},
        kind: :edit,
        content: %{message_id: "777", text: "updated"},
        meta: %{components: [%{type: 1, components: [%{type: 2, custom_id: "x"}]}]}
      }

    assert {:ok, %{message_id: 777}} = Outbound.deliver(payload)

    assert_receive {:edit, 123, 777,
                    %{
                      content: "updated",
                      components: [%{type: 1, components: [%{type: 2, custom_id: "x"}]}]
                    }}
  end
end
