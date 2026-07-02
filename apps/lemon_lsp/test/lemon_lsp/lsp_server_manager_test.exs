defmodule LemonLsp.ServerManagerTest do
  use ExUnit.Case, async: false

  alias LemonLsp.ServerManager, as: LspServerManager

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lsp_server_manager_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "reports supervised registry status" do
    status = LspServerManager.status()

    assert status.supervised == true
    assert status.running == true
    assert status.mode == :registry_and_sessions
    assert status.active_count == 0
    assert status.active_servers == []
    assert status.registry.count == 6
    assert status.registry.available_count + status.registry.missing_count == 6
    assert :server_registry in status.capabilities
    assert :json_rpc_diagnostics in status.planned_capabilities
    assert status.cleanup.includes_executable_paths == false
    assert status.cleanup.includes_workspace_roots == false
    assert status.cleanup.includes_file_contents == false
    assert status.cleanup.includes_diagnostics_output == false
    assert status.cleanup.includes_server_io == false
    assert status.cleanup.includes_raw_session_ids == false
  end

  test "refresh updates registry metadata" do
    before = LspServerManager.status()
    after_refresh = LspServerManager.refresh()

    assert after_refresh.registry.count == 6
    assert after_refresh.refresh_count >= before.refresh_count
    assert is_binary(after_refresh.refreshed_at)
  end

  test "starts and stops a redacted supervised stdio session", %{tmp_dir: tmp_dir} do
    cat = System.find_executable("cat")

    if cat == nil do
      :skip
    else
      previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      session_id = "lsp-session-test-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = LspServerManager.stop_session(session_id)

        if previous do
          System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
        else
          System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        end
      end)

      System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", cat)

      assert {:ok, session} =
               LspServerManager.start_session(:elixir_ls,
                 cwd: tmp_dir,
                 session_id: session_id
               )

      assert session.session_id == session_id
      assert session.server_id == :elixir_ls
      assert session.status == :running
      assert session.command == "cat"
      assert session.cwd_hash != nil
      assert session.session_hash != nil
      assert session.supervised == true
      refute Map.has_key?(session, :port)
      refute inspect(session) =~ tmp_dir
      refute inspect(session) =~ cat

      status = LspServerManager.status()
      assert status.active_count == 1
      active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))
      assert active != nil
      refute Map.has_key?(active, :session_id)

      assert {:ok, stopped} = LspServerManager.stop_session(session_id)
      assert stopped.status == :stopped

      status = LspServerManager.status()
      assert status.active_count == 0
      recent = Enum.find(status.recent_sessions, &(&1.session_hash == session.session_hash))
      assert recent != nil
      refute Map.has_key?(recent, :session_id)
    end
  end

  test "sends and receives a JSON-RPC request over a supervised stdio session", %{
    tmp_dir: tmp_dir
  } do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_lsp_server")
    session_id = "lsp-json-rpc-test-#{System.unique_integer([:positive])}"

    File.write!(server_path, fake_lsp_server_script())
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, response} =
             LspServerManager.request_session(
               session_id,
               "initialize",
               %{"capabilities" => %{}},
               timeout_ms: 1_000
             )

    assert response["jsonrpc"] == "2.0"
    assert is_integer(response["id"])
    assert response["result"]["capabilities"]["textDocumentSync"] == 1

    status = LspServerManager.status()
    active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))
    assert active.pending_request_count == 0
    assert active.request_count == 1
    assert active.response_count == 1
    assert is_binary(active.last_response_at)
    refute inspect(active) =~ session_id
    refute inspect(active) =~ server_path
  end

  test "keeps noisy language-server stderr inside the supervised parser", %{tmp_dir: tmp_dir} do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_noisy_lsp_server")
    session_id = "lsp-noisy-stderr-test-#{System.unique_integer([:positive])}"
    private_log = "private stderr path #{tmp_dir}/secret.ex"

    File.write!(server_path, fake_noisy_lsp_server_script(private_log))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, response} =
             LspServerManager.request_session(
               session_id,
               "initialize",
               %{"capabilities" => %{}},
               timeout_ms: 1_000
             )

    assert response["result"]["capabilities"]["textDocumentSync"] == 1

    status = LspServerManager.status()
    active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))
    assert active.pending_request_count == 0
    assert active.request_count == 1
    assert active.response_count == 1
    refute inspect(active) =~ private_log
    refute inspect(active) =~ tmp_dir
    refute inspect(active) =~ session_id
  end

  test "stops child processes spawned by language-server wrappers", %{tmp_dir: tmp_dir} do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_child_lsp_server")
    child_pid_path = Path.join(tmp_dir, "child.pid")
    session_id = "lsp-child-cleanup-test-#{System.unique_integer([:positive])}"

    File.write!(server_path, fake_child_lsp_server_script(child_pid_path))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, _session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, response} =
             LspServerManager.request_session(
               session_id,
               "initialize",
               %{"capabilities" => %{}},
               timeout_ms: 1_000
             )

    assert response["result"]["capabilities"]["textDocumentSync"] == 1

    child_pid =
      child_pid_path
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert os_process_alive?(child_pid)
    assert {:ok, stopped} = LspServerManager.stop_session(session_id)
    assert stopped.status == :stopped
    assert wait_until(fn -> not os_process_alive?(child_pid) end)
  end

  test "request timeouts terminate stuck language-server wrappers and children", %{
    tmp_dir: tmp_dir
  } do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_timeout_child_lsp_server")
    child_pid_path = Path.join(tmp_dir, "timeout_child.pid")
    session_id = "lsp-timeout-cleanup-test-#{System.unique_integer([:positive])}"

    File.write!(server_path, fake_timeout_child_lsp_server_script(child_pid_path))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert wait_until(fn -> File.exists?(child_pid_path) end)

    child_pid =
      child_pid_path
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert os_process_alive?(child_pid)

    assert {:error, :request_timeout} =
             LspServerManager.request_session(
               session_id,
               "initialize",
               %{"capabilities" => %{}},
               timeout_ms: 100
             )

    assert wait_until(fn -> not os_process_alive?(child_pid) end, 80)

    status = LspServerManager.status()
    assert status.active_count == 0
    recent = Enum.find(status.recent_sessions, &(&1.session_hash == session.session_hash))
    assert recent.status == :request_timeout
    assert recent.pending_request_count == 0
  end

  test "initializes a session and captures redacted diagnostics notifications", %{
    tmp_dir: tmp_dir
  } do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_diagnostic_lsp_server")
    session_id = "lsp-diagnostics-test-#{System.unique_integer([:positive])}"
    raw_uri = "file:///private/project/lib/secret.ex"
    raw_message = "secret compiler message"

    File.write!(server_path, fake_diagnostic_lsp_server_script(raw_uri, raw_message))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, response} =
             LspServerManager.initialize_session(
               session_id,
               %{"capabilities" => %{}, "rootUri" => raw_uri},
               timeout_ms: 1_000
             )

    assert response["result"]["capabilities"]["textDocumentSync"] == 1

    active =
      wait_until(fn ->
        status = LspServerManager.status()
        active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))

        if active && active.diagnostic_count == 2 do
          active
        end
      end)

    assert active.initialized == true
    assert is_binary(active.initialized_at)
    assert active.notification_count == 1
    assert active.diagnostic_count == 2
    assert active.diagnostic_batch_count == 1
    assert is_binary(active.last_diagnostic_at)

    assert [
             %{
               uri_hash: uri_hash,
               version: 4,
               diagnostic_count: 2,
               severities: %{error: 1, warning: 1}
             }
           ] = active.last_diagnostics

    assert is_binary(uri_hash)
    refute inspect(active) =~ raw_uri
    refute inspect(active) =~ raw_message
    refute inspect(active) =~ session_id
    refute inspect(active) =~ server_path
  end

  test "captures redacted pull diagnostics responses", %{tmp_dir: tmp_dir} do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_pull_diagnostic_lsp_server")
    session_id = "lsp-pull-diagnostics-test-#{System.unique_integer([:positive])}"
    raw_uri = "file:///private/project/lib/pull_secret.ex"
    raw_message = "private pull diagnostic"

    File.write!(server_path, fake_pull_diagnostic_lsp_server_script(raw_message))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, _response} =
             LspServerManager.initialize_session(
               session_id,
               %{"capabilities" => %{}, "rootUri" => raw_uri},
               timeout_ms: 1_000
             )

    assert {:ok, response} =
             LspServerManager.request_session(
               session_id,
               "textDocument/diagnostic",
               %{"textDocument" => %{"uri" => raw_uri}},
               timeout_ms: 1_000
             )

    assert response["result"]["kind"] == "full"

    status = LspServerManager.status()
    active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))
    assert active.diagnostic_count == 1
    assert active.diagnostic_batch_count == 1
    assert [%{severities: %{error: 1}, uri_hash: uri_hash}] = active.last_diagnostics
    assert is_binary(uri_hash)
    refute inspect(active) =~ raw_uri
    refute inspect(active) =~ raw_message
  end

  test "sends document open change and close notifications with redacted status", %{
    tmp_dir: tmp_dir
  } do
    previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
    server_path = Path.join(tmp_dir, "fake_document_lsp_server")
    log_path = Path.join(tmp_dir, "document_notifications.log")
    session_id = "lsp-document-test-#{System.unique_integer([:positive])}"
    raw_uri = "file:///private/project/lib/document_secret.ex"
    raw_text = "defmodule Secret do\nend\n"
    changed_text = "defmodule Secret do\n  def hidden, do: :ok\nend\n"

    File.write!(server_path, fake_document_lsp_server_script(log_path))
    File.chmod!(server_path, 0o755)

    on_exit(fn ->
      _ = LspServerManager.stop_session(session_id)

      if previous do
        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

    assert {:ok, session} =
             LspServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id
             )

    assert {:ok, _response} =
             LspServerManager.initialize_session(
               session_id,
               %{"capabilities" => %{}, "rootUri" => raw_uri},
               timeout_ms: 1_000
             )

    assert {:ok, opened} =
             LspServerManager.open_document(session_id, raw_uri, "elixir", raw_text, version: 1)

    assert opened.status == :open
    assert opened.language_id == "elixir"
    assert opened.version == 1
    assert opened.text_bytes == byte_size(raw_text)

    assert {:ok, changed} =
             LspServerManager.change_document(session_id, raw_uri, changed_text, version: 2)

    assert changed.status == :changed
    assert changed.version == 2
    assert changed.text_bytes == byte_size(changed_text)
    assert changed.change_count == 1

    assert {:ok, closed} = LspServerManager.close_document(session_id, raw_uri)
    assert closed.status == :closed

    assert wait_until(fn ->
             if File.exists?(log_path) and File.read!(log_path) =~ "textDocument/didClose" do
               true
             end
           end)

    status = LspServerManager.status()
    active = Enum.find(status.active_servers, &(&1.session_hash == session.session_hash))
    assert active.notification_count == 4
    assert active.document_count == 1
    assert active.open_document_count == 0

    assert [
             %{
               uri_hash: uri_hash,
               status: :closed,
               language_id: "elixir",
               version: 2,
               text_bytes: byte_count,
               change_count: 1,
               notification_count: 3
             }
           ] = active.recent_documents

    assert is_binary(uri_hash)
    assert byte_count == byte_size(changed_text)
    refute inspect(active) =~ raw_uri
    refute inspect(active) =~ raw_text
    refute inspect(active) =~ changed_text
    refute inspect(active) =~ session_id
    refute inspect(active) =~ server_path
  end

  defp fake_lsp_server_script do
    """
    #!/bin/sh
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    sleep 30
    """
  end

  defp fake_noisy_lsp_server_script(private_log) do
    """
    #!/bin/sh
    printf '%s\\n' "#{private_log}" >&2
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    sleep 30
    """
  end

  defp fake_child_lsp_server_script(child_pid_path) do
    """
    #!/bin/sh
    sleep 30 &
    printf '%s' "$!" > #{child_pid_path}
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    sleep 30
    """
  end

  defp fake_timeout_child_lsp_server_script(child_pid_path) do
    """
    #!/bin/sh
    sleep 30 &
    printf '%s' "$!" > #{child_pid_path}
    while true; do
      sleep 30
    done
    """
  end

  defp fake_diagnostic_lsp_server_script(raw_uri, raw_message) do
    diagnostics =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "textDocument/publishDiagnostics",
        "params" => %{
          "uri" => raw_uri,
          "version" => 4,
          "diagnostics" => [
            %{"severity" => 1, "message" => raw_message},
            %{"severity" => 2, "message" => "second private diagnostic"}
          ]
        }
      })

    """
    #!/bin/sh
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    diagnostic='#{diagnostics}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#diagnostic}" "$diagnostic"
    sleep 30
    """
  end

  defp fake_pull_diagnostic_lsp_server_script(raw_message) do
    diagnostic =
      Jason.encode!(%{
        "kind" => "full",
        "items" => [
          %{
            "severity" => 1,
            "message" => raw_message,
            "range" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 1}
            }
          }
        ]
      })

    """
    #!/bin/sh
    while true; do
      IFS= read -r header || exit 0
      len=$(printf '%s' "$header" | tr -dc '0-9')
      IFS= read -r _blank || true
      request=$(dd bs=1 count="$len" 2>/dev/null)
      id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$request" in
        *'"method":"initialize"'*)
          body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":2,"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false}}}}'
          printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
          ;;
        *'"method":"textDocument/diagnostic"'*)
          result='#{diagnostic}'
          body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":'"$result"'}'
          printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
          ;;
      esac
    done
    """
  end

  defp fake_document_lsp_server_script(log_path) do
    """
    #!/bin/sh
    while true; do
      IFS= read -r header || exit 0
      len=$(printf '%s' "$header" | tr -dc '0-9')
      IFS= read -r _blank || true
      request=$(dd bs=1 count="$len" 2>/dev/null)
      printf '%s\\n' "$request" >> #{log_path}
      case "$request" in
        *'"method":"initialize"'*)
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":2}}}'
          printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
          ;;
      esac
    done
    """
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(fun, 0), do: fun.()

  defp os_process_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {status, 0} ->
        status = String.trim(status)
        status != "" and not String.starts_with?(status, "Z")

      {_output, _status} ->
        false
    end
  end
end
