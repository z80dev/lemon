defmodule LemonChannels.Adapters.Telegram.OutboundTest do
  use ExUnit.Case, async: false

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

    def send_media_group(_token, chat_id, files, opts) do
      send(self(), {:send_media_group, chat_id, files, opts})
      {:ok, %{"ok" => true, "result" => [%{"message_id" => 700}, %{"message_id" => 701}]}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
  end

  defmodule MockApiDocumentOnly do
    def send_document(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_document, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 999}}}
    end
  end

  defmodule MockApiNoMediaGroup do
    def send_photo(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_photo, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 111}}}
    end
  end

  defmodule MockApiMediaGroupFails do
    def send_media_group(_token, _chat_id, _files, _opts) do
      {:error, {:http_error, 400, "Bad Request: media group failed"}}
    end

    def send_photo(_token, chat_id, {:path, path}, opts) do
      send(self(), {:send_photo, chat_id, path, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 222}}}
    end
  end

  defmodule MockApiPhotoRateLimitedOnce do
    @attempt_key {__MODULE__, :attempt}

    def reset, do: :persistent_term.put(@attempt_key, 0)
    def clear, do: :persistent_term.erase(@attempt_key)

    def send_photo(_token, chat_id, {:path, path}, opts) do
      attempt = :persistent_term.get(@attempt_key, 0) + 1
      :persistent_term.put(@attempt_key, attempt)
      send(self(), {:send_photo_attempt, attempt, chat_id, path, opts})

      if attempt == 1 do
        body =
          Jason.encode!(%{
            "ok" => false,
            "error_code" => 429,
            "description" => "Too Many Requests: retry later",
            "parameters" => %{"retry_after" => 1}
          })

        {:error, {:http_error, 429, body}}
      else
        {:ok, %{"ok" => true, "result" => %{"message_id" => 333}}}
      end
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
    old = Application.get_env(:lemon_channels, :telegram)
    MockApiPhotoRateLimitedOnce.reset()

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:lemon_channels, :telegram)
      else
        Application.put_env(:lemon_channels, :telegram, old)
      end

      MockApiPhotoRateLimitedOnce.clear()
    end)

    :ok
  end

  test "text: renders markdown into Telegram entities by default" do
    put_telegram_config(%{bot_token: "token", api_mod: MockApiCapture})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :text,
        content: "**agentbot**"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_message, 123, "agentbot", opts, nil}
    assert is_map(opts)
    assert is_list(opts[:entities])
    assert Enum.any?(opts[:entities], &(&1["type"] == "bold"))
  end

  test "text: accepts api_mod configured as module path string" do
    put_telegram_config(%{
      bot_token: "token",
      api_mod: "LemonChannels.Adapters.Telegram.OutboundTest.MockApiCapture",
      use_markdown: false
    })

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :text,
        content: "string api mod"
      }

    assert {:ok, _} = Outbound.deliver(payload)
    assert_receive {:send_message, 123, "string api mod", opts, nil}
    assert is_map(opts)
  end

  test "text: respects use_markdown = false and sends literal markdown" do
    put_telegram_config(%{
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
        content: "**agentbot**"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_message, 123, "**agentbot**", opts, nil}
    assert is_map(opts)
    refute Map.has_key?(opts, :entities)
  end

  test "edit: renders markdown into Telegram entities by default" do
    put_telegram_config(%{bot_token: "token", api_mod: MockApiCapture})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :edit,
        content: %{message_id: "456", text: "Hi **agentbot**"}
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:edit_message_text, 123, 456, "Hi agentbot", opts}
    assert is_map(opts)
    assert is_list(opts[:entities])
    assert Enum.any?(opts[:entities], &(&1["type"] == "bold"))
  end

  test "delete: 400 message to delete not found is treated as success" do
    put_telegram_config(%{bot_token: "token", api_mod: MockApiNotFound})

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
    put_telegram_config(%{bot_token: "token", api_mod: MockApiOther400})

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
    put_telegram_config(%{bot_token: "token", api_mod: MockApiCapture})

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
    put_telegram_config(%{
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

  test "file: image batches use send_media_group when available" do
    put_telegram_config(%{bot_token: "token", api_mod: MockApiCapture})

    path1 =
      Path.join(System.tmp_dir!(), "outbound-batch-1-#{System.unique_integer([:positive])}.png")

    path2 =
      Path.join(System.tmp_dir!(), "outbound-batch-2-#{System.unique_integer([:positive])}.png")

    File.write!(path1, "png1")
    File.write!(path2, "png2")

    on_exit(fn ->
      File.rm(path1)
      File.rm(path2)
    end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: "777"},
        kind: :file,
        content: %{
          files: [
            %{path: path1, caption: "Generated image 1"},
            %{path: path2}
          ]
        },
        reply_to: "456"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_media_group, 123, files, opts}
    assert Enum.map(files, & &1.path) == [path1, path2]
    assert Enum.map(files, & &1.caption) == ["Generated image 1", nil]
    assert opts[:reply_to_message_id] == 456
    assert opts[:message_thread_id] == 777
  end

  test "file: image batches fallback to sequential sends when media group API is unavailable" do
    put_telegram_config(%{
      bot_token: "token",
      api_mod: MockApiNoMediaGroup
    })

    path1 =
      Path.join(
        System.tmp_dir!(),
        "outbound-fallback-1-#{System.unique_integer([:positive])}.png"
      )

    path2 =
      Path.join(
        System.tmp_dir!(),
        "outbound-fallback-2-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path1, "png1")
    File.write!(path2, "png2")

    on_exit(fn ->
      File.rm(path1)
      File.rm(path2)
    end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: "777"},
        kind: :file,
        content: %{
          files: [
            %{path: path1, caption: "First"},
            %{path: path2, caption: "Second"}
          ]
        },
        reply_to: "456"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_photo, 123, ^path1, first_opts}
    assert first_opts[:caption] == "First"
    assert first_opts[:reply_to_message_id] == 456
    assert first_opts[:message_thread_id] == 777

    assert_receive {:send_photo, 123, ^path2, second_opts}
    assert second_opts[:caption] == "Second"
    refute Map.has_key?(second_opts, :reply_to_message_id)
    assert second_opts[:message_thread_id] == 777
  end

  test "file: image batches fallback to sequential sends when media group call fails" do
    put_telegram_config(%{
      bot_token: "token",
      api_mod: MockApiMediaGroupFails
    })

    path1 =
      Path.join(
        System.tmp_dir!(),
        "outbound-failover-1-#{System.unique_integer([:positive])}.png"
      )

    path2 =
      Path.join(
        System.tmp_dir!(),
        "outbound-failover-2-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path1, "png1")
    File.write!(path2, "png2")

    on_exit(fn ->
      File.rm(path1)
      File.rm(path2)
    end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: "777"},
        kind: :file,
        content: %{
          files: [
            %{path: path1, caption: "First"},
            %{path: path2, caption: "Second"}
          ]
        },
        reply_to: "456"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_photo, 123, ^path1, first_opts}
    assert first_opts[:caption] == "First"
    assert first_opts[:reply_to_message_id] == 456
    assert first_opts[:message_thread_id] == 777

    assert_receive {:send_photo, 123, ^path2, second_opts}
    assert second_opts[:caption] == "Second"
    refute Map.has_key?(second_opts, :reply_to_message_id)
    assert second_opts[:message_thread_id] == 777
  end

  test "file: retries send_photo when Telegram responds with 429 retry_after" do
    put_telegram_config(%{bot_token: "token", api_mod: MockApiPhotoRateLimitedOnce})

    path =
      Path.join(
        System.tmp_dir!(),
        "outbound-rate-limit-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, "png")
    on_exit(fn -> File.rm(path) end)

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: "777"},
        kind: :file,
        content: %{path: path, caption: "Retry me"},
        reply_to: "456"
      }

    assert {:ok, _} = Outbound.deliver(payload)

    assert_receive {:send_photo_attempt, 1, 123, ^path, first_opts}
    assert first_opts[:reply_to_message_id] == 456
    assert first_opts[:caption] == "Retry me"

    assert_receive {:send_photo_attempt, 2, 123, ^path, second_opts}, 2_000
    assert second_opts[:reply_to_message_id] == 456
    assert second_opts[:caption] == "Retry me"
  end

  defp put_telegram_config(config) when is_map(config) do
    base = %{files: %{outbound_send_delay_ms: 0}}
    Application.put_env(:lemon_channels, :telegram, deep_merge(base, config))
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge(left_val, right_val)
      else
        right_val
      end
    end)
  end
end
