defmodule LemonChannels.Adapters.Telegram.OutboundTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Outbound
  alias LemonChannels.OutboundPayload

  defmodule MockApiCapture do
    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
      send(self(), {:send_message, chat_id, text, reply_to_or_opts, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 123}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      send(self(), {:edit_message_text, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def send_document(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_document, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 321}}}
    end

    def send_photo(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_photo, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 654}}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
  end

  defmodule MockApiDocumentOnly do
    def send_document(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_document, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 999}}}
    end
  end

  defmodule MockApiNotFound do
    def delete_message(_token, _chat_id, _message_id) do
      body =
        Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: message to delete not found"
        })

      {:error, {:http_error, 400, body}}
    end
  end

  defmodule MockApiOther400 do
    def delete_message(_token, _chat_id, _message_id) do
      body =
        Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: chat not found"
        })

      {:error, {:http_error, 400, body}}
    end
  end

  setup do
    old = Application.get_env(:lemon_gateway, :telegram)

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:lemon_gateway, :telegram)
      else
        Application.put_env(:lemon_gateway, :telegram, old)
      end
    end)

    :ok
  end

  test "text: renders markdown into Telegram entities by default" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiCapture})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :text,
        content: "**zeebot**"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_message, 123, "zeebot", opts, nil}
    assert is_map(opts)
    assert is_list(opts[:entities])
    assert Enum.any?(opts[:entities], &(&1["type"] == "bold"))
  end

  test "text: respects use_markdown = false and sends literal markdown" do
    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "token",
      api_mod: MockApiCapture,
      use_markdown: false
    })

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :text,
        content: "**zeebot**"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_message, 123, "**zeebot**", opts, nil}
    assert is_map(opts)
    refute Map.has_key?(opts, :entities)
  end

  test "edit: renders markdown into Telegram entities by default" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiCapture})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :edit,
        content: %{message_id: "456", text: "Hi **zeebot**"}
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:edit_message_text, 123, 456, "Hi zeebot", opts}
    assert is_map(opts)
    assert is_list(opts[:entities])
    assert Enum.any?(opts[:entities], &(&1["type"] == "bold"))
  end

  test "delete: 400 message to delete not found is treated as success" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiNotFound})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :delete,
        content: %{message_id: "456"}
      }

    assert {:ok, :already_deleted} = Outbound.deliver(payload)
  end

  test "delete: other 400s are returned as errors" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiOther400})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :delete,
        content: %{message_id: 456}
      }

    assert {:error, {:http_error, 400, _body}} = Outbound.deliver(payload)
  end

  test "file: image paths use send_photo when available" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiCapture})

    path =
      Path.join(System.tmp_dir!(), "outbound-image-#{System.unique_integer([:positive])}.png")

    File.write!(path, "png")
    on_exit(fn -> File.rm(path) end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: "777"},
        kind: :file,
        content: %{path: path, caption: "Generated image"},
        reply_to: "456"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_photo, 123, ^path, opts}
    assert opts[:caption] == "Generated image"
    assert opts[:reply_to_message_id] == 456
    assert opts[:message_thread_id] == 777
  end

  test "file: non-image paths fallback to send_document" do
    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "token",
      api_mod: MockApiDocumentOnly
    })

    path = Path.join(System.tmp_dir!(), "outbound-text-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :file,
        content: %{path: path}
      }

    assert {:ok, _} = Outbound.deliver(payload)
    assert_receive {:send_document, 123, ^path, opts}
    refute Map.has_key?(opts, :caption)
  end
end
