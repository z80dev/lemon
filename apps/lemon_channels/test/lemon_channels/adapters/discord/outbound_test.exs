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
    old_config_test_mode = Application.get_env(:lemon_core, :config_test_mode)
    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: MockMessageApi}
    })

    on_exit(fn ->
      restore_env(:lemon_core, :config_test_mode, old_config_test_mode)

      if old == nil do
        Application.delete_env(:lemon_gateway, @gateway_config_key)
      else
        Application.put_env(:lemon_gateway, @gateway_config_key, old)
      end
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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
    assert_receive {:create, 456, %{content: "hello", allowed_mentions: allowed_mentions}}
    assert allowed_mentions == :none
  end

  test "text delivery disables Discord mention parsing and reply pings" do
    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: nil},
        kind: :text,
        content: "@everyone <@123> <@&456> @here",
        reply_to: "777"
      }

    assert {:ok, %{message_id: 4444}} = Outbound.deliver(payload)

    assert_receive {:create, 123,
                    %{
                      content: "@everyone <@123> <@&456> @here",
                      message_reference: %{message_id: 777},
                      allowed_mentions: :none
                    }}
  end

  test "text delivery chunks long Discord content" do
    long_text = String.duplicate("a", 4_100)

    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: nil},
        kind: :text,
        content: long_text
      }

    assert {:ok, %{message_id: 4444, extra_message_ids: [4444, 4444]}} =
             Outbound.deliver(payload)

    assert_receive {:create, 123, %{content: first, allowed_mentions: first_mentions}}
    assert_receive {:create, 123, %{content: second, allowed_mentions: second_mentions}}
    assert_receive {:create, 123, %{content: third, allowed_mentions: third_mentions}}
    assert String.length(first) == 1_900
    assert String.length(second) == 1_900
    assert String.length(third) == 300
    assert first_mentions == :none
    assert second_mentions == :none
    assert third_mentions == :none
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
                      allowed_mentions: :none,
                      files: [%{body: "artifact", name: "artifact.txt"}]
                    }}
  end

  test "file delivery uploads a bounded file batch" do
    first =
      Path.join(System.tmp_dir!(), "discord-outbound-#{System.unique_integer([:positive])}-1.txt")

    second =
      Path.join(System.tmp_dir!(), "discord-outbound-#{System.unique_integer([:positive])}-2.txt")

    File.write!(first, "one")
    File.write!(second, "two")
    on_exit(fn -> Enum.each([first, second], &File.rm/1) end)

    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: "456"},
        kind: :file,
        content: %{
          files: [
            %{path: first, filename: "one.txt"},
            %{path: second, filename: "two.txt"}
          ],
          caption: "bundle ready"
        }
      }

    assert {:ok, %{message_id: 4444}} = Outbound.deliver(payload)

    assert_receive {:create, 456,
                    %{
                      content: "bundle ready",
                      allowed_mentions: :none,
                      files: [
                        %{body: "one", name: "one.txt"},
                        %{body: "two", name: "two.txt"}
                      ]
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
                      allowed_mentions: :none,
                      components: [%{type: 1, components: [%{type: 2, custom_id: "x"}]}]
                    }}
  end

  test "edit delivery chunks long Discord content" do
    long_text = String.duplicate("b", 4_100)

    payload =
      %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: nil},
        kind: :edit,
        content: %{message_id: "777", text: long_text}
      }

    assert {:ok, %{message_id: 777, extra_message_ids: [4444, 4444]}} =
             Outbound.deliver(payload)

    assert_receive {:edit, 123, 777, %{content: first}}
    assert_receive {:create, 123, %{content: second}}
    assert_receive {:create, 123, %{content: third}}
    assert String.length(first) == 1_900
    assert String.length(second) == 1_900
    assert String.length(third) == 300
  end
end
