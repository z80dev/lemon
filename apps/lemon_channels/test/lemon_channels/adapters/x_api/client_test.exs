defmodule LemonChannels.Adapters.XAPI.Client.MediaUploadTest do
  @moduledoc """
  Tests for the X API chunked media upload flow (INIT / APPEND / FINALIZE).
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.XAPI
  alias LemonChannels.Adapters.XAPI.Client
  alias LemonChannels.Adapters.XAPI.TokenManager
  alias LemonChannels.OutboundPayload

  @x_api_env_keys [
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_TOKEN_EXPIRES_AT",
    "X_DEFAULT_ACCOUNT_ID",
    "X_DEFAULT_ACCOUNT_USERNAME"
  ]

  setup do
    previous_req_defaults = Req.default_options()
    previous_config = Application.get_env(:lemon_channels, XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)

    previous_env =
      Enum.into(@x_api_env_keys, %{}, fn key ->
        {key, System.get_env(key)}
      end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Enum.each(@x_api_env_keys, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:lemon_channels, XAPI)
      else
        Application.put_env(:lemon_channels, XAPI, previous_config)
      end

      if is_nil(previous_use_secrets) do
        Application.delete_env(:lemon_channels, :x_api_use_secrets)
      else
        Application.put_env(:lemon_channels, :x_api_use_secrets, previous_use_secrets)
      end

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Req.default_options(previous_req_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  # ── chunk_binary/2 unit tests ─────────────────────────────────────────

  describe "chunk_binary/2" do
    test "returns a single chunk when data fits within chunk_size" do
      data = String.duplicate("a", 100)
      assert [^data] = Client.chunk_binary(data, 100)
    end

    test "returns a single chunk when data is smaller than chunk_size" do
      data = "hello"
      assert ["hello"] = Client.chunk_binary(data, 1024)
    end

    test "splits data into equal-sized chunks" do
      data = String.duplicate("x", 9)
      chunks = Client.chunk_binary(data, 3)

      assert length(chunks) == 3
      assert Enum.all?(chunks, &(byte_size(&1) == 3))
      assert IO.iodata_to_binary(chunks) == data
    end

    test "last chunk can be smaller than chunk_size" do
      data = String.duplicate("y", 10)
      chunks = Client.chunk_binary(data, 3)

      assert length(chunks) == 4
      assert byte_size(List.last(chunks)) == 1
      assert IO.iodata_to_binary(chunks) == data
    end

    test "handles empty binary" do
      assert [] = Client.chunk_binary(<<>>, 5)
    end

    test "handles chunk_size of 1" do
      data = "abc"
      chunks = Client.chunk_binary(data, 1)
      assert chunks == ["a", "b", "c"]
    end

    test "preserves binary data integrity for large payloads" do
      # Simulate a ~12 MB binary split into 5 MB chunks
      data = :crypto.strong_rand_bytes(12 * 1024 * 1024)
      chunk_size = 5 * 1024 * 1024
      chunks = Client.chunk_binary(data, chunk_size)

      assert length(chunks) == 3
      assert byte_size(Enum.at(chunks, 0)) == chunk_size
      assert byte_size(Enum.at(chunks, 1)) == chunk_size
      assert byte_size(Enum.at(chunks, 2)) == 2 * 1024 * 1024
      assert IO.iodata_to_binary(chunks) == data
    end
  end

  # ── Full upload flow tests ───────────────────────────────────────────

  describe "deliver/1 with :file payload (media upload)" do
    test "successful upload: INIT -> APPEND -> FINALIZE -> tweet" do
      configure_oauth2()
      start_token_manager!()
      test_pid = self()

      image_data = :crypto.strong_rand_bytes(1024)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn.request_path, body, conn.method})

        case {conn.request_path, body} do
          {"/2/oauth2/token", _} ->
            oauth_refresh_response(conn)

          {"/1.1/media/upload.json", body_str} ->
            cond do
              String.contains?(body_str, "command=INIT") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  200,
                  Jason.encode!(%{
                    "media_id" => 710_511_363_345_354_753,
                    "media_id_string" => "710511363345354753",
                    "expires_after_secs" => 86400
                  })
                )

              String.contains?(body_str, "APPEND") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(204, "")

              String.contains?(body_str, "command=FINALIZE") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  200,
                  Jason.encode!(%{
                    "media_id" => 710_511_363_345_354_753,
                    "media_id_string" => "710511363345354753",
                    "size" => byte_size(image_data),
                    "expires_after_secs" => 86400
                  })
                )

              true ->
                conn
                |> Plug.Conn.send_resp(400, "unexpected upload request")
            end

          {"/2/tweets", _} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              201,
              Jason.encode!(%{
                "data" => %{
                  "id" => "1234567890",
                  "text" => "uploaded media"
                }
              })
            )

          _ ->
            conn
            |> Plug.Conn.send_resp(404, "not found")
        end
      end)

      payload = %OutboundPayload{
        channel_id: "x-channel",
        account_id: "x-account",
        peer: %{kind: :channel, id: "x-peer", thread_id: nil},
        kind: :file,
        content: %{data: image_data, mime_type: "image/png", text: "uploaded media"},
        reply_to: nil,
        meta: %{}
      }

      assert {:ok, %{tweet_id: "1234567890", media_id: "710511363345354753"}} =
               Client.deliver(payload)

      # Verify the sequence of requests
      assert_receive {:req, "/1.1/media/upload.json", init_body, "POST"}
      assert init_body =~ "command=INIT"
      assert init_body =~ "media_type=image%2Fpng"

      assert_receive {:req, "/1.1/media/upload.json", append_body, "POST"}
      assert append_body =~ "APPEND"

      assert_receive {:req, "/1.1/media/upload.json", finalize_body, "POST"}
      assert finalize_body =~ "command=FINALIZE"
      assert finalize_body =~ "media_id=710511363345354753"

      assert_receive {:req, "/2/tweets", _tweet_body, "POST"}
    end

    test "multi-chunk upload sends one APPEND per chunk" do
      configure_oauth2()
      start_token_manager!()
      test_pid = self()

      # 11 MB of data -> 3 chunks at 5 MB each (5 + 5 + 1)
      image_data = :crypto.strong_rand_bytes(11 * 1024 * 1024)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

        # Identify command by checking form-encoded fields or multipart markers
        command =
          cond do
            conn.request_path != "/1.1/media/upload.json" -> conn.request_path
            String.contains?(body, "command=INIT") -> :init
            String.contains?(body, "command=FINALIZE") -> :finalize
            true -> :append
          end

        send(test_pid, {:upload_step, command})

        case command do
          "/2/oauth2/token" ->
            oauth_refresh_response(conn)

          :init ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              202,
              Jason.encode!(%{"media_id_string" => "999888777", "media_id" => 999_888_777})
            )

          :append ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(204, "")

          :finalize ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              201,
              Jason.encode!(%{"media_id_string" => "999888777", "media_id" => 999_888_777})
            )

          "/2/tweets" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              201,
              Jason.encode!(%{"data" => %{"id" => "tweet-multi", "text" => "multi chunk"}})
            )
        end
      end)

      payload = %OutboundPayload{
        channel_id: "x-channel",
        account_id: "x-account",
        peer: %{kind: :channel, id: "x-peer", thread_id: nil},
        kind: :file,
        content: %{data: image_data, mime_type: "image/jpeg", text: "multi chunk"},
        reply_to: nil,
        meta: %{}
      }

      assert {:ok, %{tweet_id: "tweet-multi", media_id: "999888777"}} =
               Client.deliver(payload)

      # Collect all step messages and count APPENDs
      steps = receive_all_messages()

      append_count =
        Enum.count(steps, fn
          {:upload_step, :append} -> true
          _ -> false
        end)

      # 11 MB / 5 MB = 3 chunks (5 + 5 + 1)
      assert append_count == 3
    end
  end

  # ── Error handling tests ─────────────────────────────────────────────

  describe "upload error handling" do
    test "INIT failure returns error tuple" do
      configure_oauth2()
      start_token_manager!()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/2/oauth2/token" ->
            oauth_refresh_response(conn)

          "/1.1/media/upload.json" ->
            if String.contains?(body, "command=INIT") do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                403,
                Jason.encode!(%{"errors" => [%{"message" => "Forbidden"}]})
              )
            end
        end
      end)

      payload = %OutboundPayload{
        channel_id: "x-channel",
        account_id: "x-account",
        peer: %{kind: :channel, id: "x-peer", thread_id: nil},
        kind: :file,
        content: %{data: "fake-image", mime_type: "image/png", text: "test"},
        reply_to: nil,
        meta: %{}
      }

      assert {:error, {:upload_init_failed, 403, _body}} = Client.deliver(payload)
    end

    test "APPEND failure returns error and halts further chunks" do
      configure_oauth2()
      start_token_manager!()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, conn.request_path, body})

        case conn.request_path do
          "/2/oauth2/token" ->
            oauth_refresh_response(conn)

          "/1.1/media/upload.json" ->
            cond do
              String.contains?(body, "command=INIT") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  200,
                  Jason.encode!(%{
                    "media_id_string" => "111222333",
                    "media_id" => 111_222_333
                  })
                )

              String.contains?(body, "APPEND") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  500,
                  Jason.encode!(%{"errors" => [%{"message" => "Internal error"}]})
                )

              true ->
                conn |> Plug.Conn.send_resp(400, "unexpected")
            end
        end
      end)

      payload = %OutboundPayload{
        channel_id: "x-channel",
        account_id: "x-account",
        peer: %{kind: :channel, id: "x-peer", thread_id: nil},
        kind: :file,
        content: %{data: "small-image-data", mime_type: "image/png", text: "test"},
        reply_to: nil,
        meta: %{}
      }

      assert {:error, {:upload_append_failed, 0, 500, _body}} = Client.deliver(payload)

      # Ensure FINALIZE was never called
      messages = receive_all_messages()

      finalize_messages =
        Enum.filter(messages, fn
          {:req, "/1.1/media/upload.json", body} -> String.contains?(body, "command=FINALIZE")
          _ -> false
        end)

      assert finalize_messages == []
    end

    test "FINALIZE failure returns error tuple" do
      configure_oauth2()
      start_token_manager!()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/2/oauth2/token" ->
            oauth_refresh_response(conn)

          "/1.1/media/upload.json" ->
            cond do
              String.contains?(body, "command=INIT") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  200,
                  Jason.encode!(%{
                    "media_id_string" => "444555666",
                    "media_id" => 444_555_666
                  })
                )

              String.contains?(body, "APPEND") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(204, "")

              String.contains?(body, "command=FINALIZE") ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(
                  400,
                  Jason.encode!(%{
                    "errors" => [%{"message" => "InvalidMediaId", "code" => 324}]
                  })
                )
            end
        end
      end)

      payload = %OutboundPayload{
        channel_id: "x-channel",
        account_id: "x-account",
        peer: %{kind: :channel, id: "x-peer", thread_id: nil},
        kind: :file,
        content: %{data: "test-data", mime_type: "image/png", text: "test"},
        reply_to: nil,
        meta: %{}
      }

      assert {:error, {:upload_finalize_failed, 400, _body}} = Client.deliver(payload)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp oauth_refresh_response(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "refreshed-access-token",
        "refresh_token" => "refreshed-refresh-token",
        "token_type" => "Bearer",
        "expires_in" => 7200
      })
    )
  end

  defp configure_oauth2(opts \\ []) do
    now = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    config = [
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      access_token: "test-access-token",
      refresh_token: "test-refresh-token",
      token_expires_at: now
    ]

    config =
      Enum.reduce(opts, config, fn {key, value}, acc ->
        Keyword.put(acc, key, value)
      end)

    Application.put_env(:lemon_channels, XAPI, config)
  end

  defp start_token_manager! do
    case Process.whereis(TokenManager) do
      pid when is_pid(pid) ->
        pid

      _ ->
        case start_supervised({TokenManager, []}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp receive_all_messages(acc \\ []) do
    receive do
      msg -> receive_all_messages([msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
