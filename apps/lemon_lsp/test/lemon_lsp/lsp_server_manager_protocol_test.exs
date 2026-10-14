defmodule LemonLsp.ServerManagerProtocolTest do
  use ExUnit.Case, async: false

  alias LemonLsp.ServerManager

  @env "LEMON_LSP_ELIXIR_LS_COMMAND"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lsp_protocol_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    server_path = Path.join(tmp_dir, "fake_protocol_server.exs")
    File.write!(server_path, fake_server_script())
    File.chmod!(server_path, 0o755)

    previous = System.get_env(@env)
    System.put_env(@env, server_path)
    session_id = "lsp-protocol-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = ServerManager.stop_session(session_id)
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      File.rm_rf!(tmp_dir)
    end)

    if System.find_executable("elixir") do
      {:ok, tmp_dir: tmp_dir, session_id: session_id}
    else
      {:skip, "elixir executable is not on PATH"}
    end
  end

  test "acknowledges edits only after applying them and permits reentrant manager calls", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "applied.ex")
    uri = "file://" <> URI.encode(path)
    text = "updated\n"
    receipt = %{path: path, bytes: byte_size(text)}
    File.write!(path, "original\n")

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    apply_edit = fn edit ->
      assert %{"changes" => %{^uri => [%{"newText" => ^text}]}} = edit
      assert {:ok, %{seq: 0, entry: nil}} = ServerManager.document_diagnostics(session_id, uri)

      assert {:error, :edit_request_in_progress} =
               ServerManager.request_with_edits(session_id, "workspace/executeCommand", %{},
                 timeout_ms: 2_000,
                 apply_edit: fn _ -> flunk("an overlapping operation must not capture edits") end
               )

      assert {:ok, probe} =
               ServerManager.request_session(session_id, "fake/editProbe", %{"path" => path},
                 timeout_ms: 2_000
               )

      assert probe["result"] == %{
               "applyEditAcknowledged" => false,
               "bytes" => "original\n"
             }

      File.write!(path, text)
      {:ok, receipt}
    end

    assert {:ok, response, [{:ok, ^receipt}]} =
             ServerManager.request_with_edits(
               session_id,
               "workspace/executeCommand",
               %{"command" => "fake.apply", "path" => path, "text" => text},
               timeout_ms: 20_000,
               apply_edit: apply_edit
             )

    # The server's configuration request reused the pending client id; it must
    # be answered as a server request rather than completing our call.
    assert response["result"]["configuration"] == [nil, nil]
    assert response["result"]["applyEdit"] == %{"applied" => true}
    assert response["result"]["bytesAfterAck"] == text
    assert File.read!(path) == text

    assert {:ok, plain} =
             ServerManager.request_session(
               session_id,
               "workspace/executeCommand",
               %{"path" => path, "text" => "unrequested\n"},
               timeout_ms: 20_000
             )

    assert plain["result"]["applyEdit"]["applied"] == false
    assert plain["result"]["bytesAfterAck"] == text
    assert File.read!(path) == text
  end

  test "reports callback failure to the server without changing the file", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "rejected.ex")
    uri = "file://" <> URI.encode(path)
    reason = "workspace edit rejected"
    File.write!(path, "original\n")

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    assert {:ok, response, [{:error, ^reason}]} =
             ServerManager.request_with_edits(
               session_id,
               "workspace/executeCommand",
               %{"path" => path, "text" => "rejected\n"},
               timeout_ms: 20_000,
               apply_edit: fn edit ->
                 assert %{"changes" => %{^uri => [%{"newText" => "rejected\n"}]}} = edit
                 {:error, reason}
               end
             )

    assert response["result"]["applyEdit"] == %{
             "applied" => false,
             "failureReason" => reason
           }

    assert response["result"]["bytesAfterAck"] == "original\n"
    assert File.read!(path) == "original\n"
  end

  test "keeps raw diagnostics per document while status stays redacted", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    uri = "file://#{tmp_dir}/secret.ex"

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)
    assert {:ok, %{seq: 0, entry: nil}} = ServerManager.document_diagnostics(session_id, uri)

    assert {:ok, _} = ServerManager.open_document(session_id, uri, "elixir", "x", version: 3)

    entry =
      wait_until(fn ->
        case ServerManager.document_diagnostics(session_id, uri) do
          {:ok, %{entry: %{} = entry}} -> entry
          _ -> nil
        end
      end)

    assert entry.version == 3
    assert entry.seq == 1
    assert [%{"message" => "private diagnostic text"}] = entry.diagnostics
    refute inspect(ServerManager.status()) =~ "private diagnostic text"
    refute inspect(ServerManager.status()) =~ tmp_dir
  end

  test "cancel-on-timeout keeps the session and notifies the server", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    assert {:error, :request_timeout} =
             ServerManager.request_session(session_id, "fake/slow", %{},
               timeout_ms: 200,
               on_timeout: :cancel
             )

    assert {:ok, response} =
             ServerManager.request_session(session_id, "fake/cancelled", %{}, timeout_ms: 20_000)

    assert [id] = response["result"]
    assert is_integer(id)
  end

  test "cancels an in-flight edit callback before acknowledging timeout with no late writes", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "cancelled.ex")
    File.write!(path, "original\n")
    caller = self()

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    request =
      Task.async(fn ->
        ServerManager.request_with_edits(
          session_id,
          "workspace/executeCommand",
          %{"path" => path, "text" => "late\n"},
          timeout_ms: 1_000,
          on_timeout: :cancel,
          apply_edit: fn _edit ->
            send(caller, {:callback_started, self()})

            receive do
              :finish ->
                File.write!(path, "late\n")
                {:ok, %{path: path}}
            end
          end
        )
      end)

    assert_receive {:callback_started, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:error, :request_timeout} = Task.await(request, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000

    # A released callback must not outlive the request and mutate the workspace.
    send(worker, :finish)

    assert {:ok, response} =
             ServerManager.request_session(session_id, "fake/editStatus", %{}, timeout_ms: 2_000)

    assert response["result"]["applyEdit"]["applied"] == false
    assert is_binary(response["result"]["applyEdit"]["failureReason"])
    assert response["result"]["bytesAfterAck"] == "original\n"
    assert [id] = response["result"]["cancelled"]
    assert id == response["result"]["commandId"]
    assert File.read!(path) == "original\n"
  end

  test "stops the session when its owner exits", %{tmp_dir: tmp_dir, session_id: session_id} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id,
               owner: owner
             )

    send(owner, :stop)

    assert wait_until(fn ->
             status = ServerManager.status()

             Enum.find(
               status.recent_sessions,
               &(&1.session_hash == session.session_hash and &1.status == :owner_exited)
             )
           end)

    assert {:error, :unknown_lsp_session} = ServerManager.stop_session(session_id)
  end

  defp wait_until(fun, attempts \\ 400)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      falsy when falsy in [nil, false] ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(fun, 0), do: fun.()

  defp fake_server_script do
    ~S"""
    #!/usr/bin/env elixir
    :io.setopts(:standard_io, encoding: :latin1, binary: true)

    defmodule Fake do
      def read do
        case headers(nil) do
          nil -> nil
          len -> :stdio |> IO.binread(len) |> JSON.decode!()
        end
      end

      defp headers(len) do
        case IO.binread(:stdio, :line) do
          line when is_binary(line) ->
            case String.trim(line) do
              "" -> len
              "Content-Length: " <> n -> headers(String.to_integer(n))
              _ -> headers(len)
            end

          _ ->
            nil
        end
      end

      def send(message) do
        body = JSON.encode!(Map.put(message, "jsonrpc", "2.0"))
        IO.binwrite(:stdio, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
      end

      def await_responses(ids, acc, cancelled) do
        if ids == [] do
          {acc, cancelled}
        else
          case read() do
            %{"method" => "$/cancelRequest", "params" => %{"id" => id}} ->
              await_responses(ids, acc, [id | cancelled])

            %{"method" => "fake/editProbe", "id" => id, "params" => params} ->
              send(%{
                "id" => id,
                "result" => %{
                  "applyEditAcknowledged" => Map.has_key?(acc, "edit-1"),
                  "bytes" => File.read!(params["path"])
                }
              })

              await_responses(ids, acc, cancelled)

            message ->
              id = message["id"]

              if id in ids and not Map.has_key?(message, "method") do
                await_responses(
                  List.delete(ids, id),
                  Map.put(acc, id, message["result"]),
                  cancelled
                )
              else
                await_responses(ids, acc, cancelled)
              end
          end
        end
      end

      def loop(cancelled, last_command \\ nil) do
        case read() do
          nil ->
            :ok

          %{"method" => "initialize", "id" => id} ->
            send(%{"id" => id, "result" => %{"capabilities" => %{}}})
            loop(cancelled, last_command)

          %{"method" => "workspace/executeCommand", "id" => id, "params" => params} ->
            send(%{
              "id" => id,
              "method" => "workspace/configuration",
              "params" => %{"items" => [%{}, %{}]}
            })

            send(%{
              "id" => "edit-1",
              "method" => "workspace/applyEdit",
              "params" => %{
                "edit" => %{
                  "changes" => %{
                    ("file://" <> URI.encode(params["path"])) => [
                      %{
                        "range" => %{
                          "start" => %{"line" => 0, "character" => 0},
                          "end" => %{"line" => 1, "character" => 0}
                        },
                        "newText" => params["text"]
                      }
                    ]
                  }
                }
              }
            })

            {results, cancelled} = await_responses([id, "edit-1"], %{}, cancelled)

            result = %{
              "commandId" => id,
              "configuration" => results[id],
              "applyEdit" => results["edit-1"],
              "bytesAfterAck" => File.read!(params["path"])
            }

            send(%{"id" => id, "result" => result})
            loop(cancelled, result)

          %{"method" => "fake/editProbe", "id" => id, "params" => params} ->
            send(%{
              "id" => id,
              "result" => %{
                "applyEditAcknowledged" => last_command != nil,
                "bytes" => File.read!(params["path"])
              }
            })

            loop(cancelled, last_command)

          %{"method" => "fake/editStatus", "id" => id} ->
            send(%{"id" => id, "result" => Map.put(last_command, "cancelled", cancelled)})
            loop(cancelled, last_command)

          %{"method" => "textDocument/didOpen", "params" => params} ->
            send(%{
              "method" => "textDocument/publishDiagnostics",
              "params" => %{
                "uri" => params["textDocument"]["uri"],
                "version" => params["textDocument"]["version"],
                "diagnostics" => [%{"severity" => 1, "message" => "private diagnostic text"}]
              }
            })

            loop(cancelled, last_command)

          %{"method" => "$/cancelRequest", "params" => %{"id" => cancelled_id}} ->
            loop([cancelled_id | cancelled], last_command)

          %{"method" => "fake/cancelled", "id" => id} ->
            send(%{"id" => id, "result" => cancelled})
            loop(cancelled, last_command)

          _other ->
            loop(cancelled, last_command)
        end
      end
    end

    Fake.loop([])
    """
  end
end
