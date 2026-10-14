defmodule CodingAgent.Tools.Lsp.Client do
  @moduledoc """
  One initialized language-server session per (scope, server, workspace root).

  The scope is the owning coding session id (or the cwd for calls made outside
  a session). The client owns a `LemonLsp.ServerManager` session: it starts and
  initializes the server on first use, keeps opened documents in sync with the
  disk (`didOpen`, then `didChange` with an incremented version whenever the
  file's bytes change) and stops the server when the owning session process
  exits, after an idle timeout, or when it is stopped explicitly. The manager
  session is also bound to this process as its owner, so even a brutal kill of
  the client cannot leak a server.

  Requests themselves go straight to the manager from the calling tool process;
  the client only serializes lifecycle and document synchronization.
  """

  use GenServer, restart: :temporary

  alias CodingAgent.Tools.Lsp.Text
  alias LemonLsp.ServerManager

  @registry CodingAgent.Tools.Lsp.Registry
  @supervisor CodingAgent.Tools.Lsp.Supervisor
  @idle_timeout_ms 10 * 60 * 1_000
  @max_open_documents 64

  @client_capabilities %{
    "general" => %{"positionEncodings" => ["utf-16"]},
    "textDocument" => %{
      "synchronization" => %{"dynamicRegistration" => false, "didSave" => false},
      "hover" => %{"dynamicRegistration" => false, "contentFormat" => ["markdown", "plaintext"]},
      "definition" => %{"dynamicRegistration" => false, "linkSupport" => true},
      "typeDefinition" => %{"dynamicRegistration" => false, "linkSupport" => true},
      "implementation" => %{"dynamicRegistration" => false, "linkSupport" => true},
      "references" => %{"dynamicRegistration" => false},
      "documentSymbol" => %{
        "dynamicRegistration" => false,
        "hierarchicalDocumentSymbolSupport" => true,
        "symbolKind" => %{"valueSet" => Enum.to_list(1..26)}
      },
      "rename" => %{"dynamicRegistration" => false, "prepareSupport" => true},
      "codeAction" => %{
        "dynamicRegistration" => false,
        "isPreferredSupport" => true,
        "disabledSupport" => true,
        "dataSupport" => true,
        "resolveSupport" => %{"properties" => ["edit"]},
        "codeActionLiteralSupport" => %{
          "codeActionKind" => %{
            "valueSet" => [
              "",
              "quickfix",
              "refactor",
              "refactor.extract",
              "refactor.inline",
              "refactor.rewrite",
              "source",
              "source.organizeImports",
              "source.fixAll"
            ]
          }
        }
      },
      "publishDiagnostics" => %{
        "relatedInformation" => true,
        "versionSupport" => true,
        "tagSupport" => %{"valueSet" => [1, 2]},
        "codeDescriptionSupport" => true,
        "dataSupport" => true
      },
      "diagnostic" => %{"dynamicRegistration" => false, "relatedDocumentSupport" => false}
    },
    "window" => %{"workDoneProgress" => true},
    "workspace" => %{
      "applyEdit" => true,
      "workspaceEdit" => %{
        "documentChanges" => true,
        "resourceOperations" => ["create", "rename", "delete"],
        "failureHandling" => "abort"
      },
      "configuration" => true,
      "workspaceFolders" => true,
      "executeCommand" => %{"dynamicRegistration" => false},
      "symbol" => %{
        "dynamicRegistration" => false,
        "symbolKind" => %{"valueSet" => Enum.to_list(1..26)}
      }
    }
  }

  @type key :: {String.t(), atom(), String.t()}

  @doc false
  def child_spec(args) do
    %{id: {__MODULE__, args.key}, start: {__MODULE__, :start_link, [args]}, restart: :temporary}
  end

  @doc false
  def start_link(args) do
    value = %{session_key: Map.get(args, :session_key), started_at: System.monotonic_time()}
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, args.key, value}})
  end

  @doc "Find or start the client for `key`."
  @spec ensure(key(), map(), pid() | nil, String.t() | nil) :: {:ok, pid()} | {:error, term()}
  def ensure({_scope, _server_id, _root} = key, server, owner, session_key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        with :ok <- CodingAgent.ToolResources.bind(pid, owner), do: {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, %{key: key, server: server, owner: owner, session_key: session_key}}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            with :ok <- CodingAgent.ToolResources.bind(pid, owner), do: {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Start and initialize the server if needed, then sync `path` (or nothing for
  `nil`) and every other open document with the disk.

  Returns the manager session id, server capabilities and, for a path, its
  URI, document version, whether this call sent `didOpen`/`didChange`, and the
  session's diagnostics sequence number from before that notification.
  """
  @spec sync(pid(), String.t() | nil, pos_integer()) :: {:ok, map()} | {:error, term()}
  def sync(pid, path, timeout_ms) do
    GenServer.call(pid, {:sync, path, timeout_ms}, timeout_ms + 5_000)
  catch
    :exit, _reason -> {:error, :session_lost}
  end

  @doc "Re-sync open documents among `paths` after the tool changed them on disk."
  @spec refresh(pid(), [String.t()]) :: :ok
  def refresh(pid, paths) do
    GenServer.call(pid, {:refresh, paths}, 15_000)
  catch
    :exit, _reason -> :ok
  end

  @doc "Stop a client and its language server."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal, 10_000)
  catch
    :exit, _reason -> :ok
  end

  @doc "List running clients for `scope` as `%{server_id, root, pid}` maps."
  @spec list(String.t()) :: [map()]
  def list(scope) do
    if Process.whereis(@registry) do
      @registry
      |> Registry.select([
        {{{:"$1", :"$2", :"$3"}, :"$4", :_}, [{:==, :"$1", scope}], [{{:"$2", :"$3", :"$4"}}]}
      ])
      |> Enum.map(fn {server_id, root, pid} -> %{server_id: server_id, root: root, pid: pid} end)
      |> Enum.sort_by(&{&1.server_id, &1.root})
    else
      []
    end
  end

  @doc "Running-client summary (open document count, initialization state)."
  @spec info(pid()) :: {:ok, map()} | {:error, :session_lost}
  def info(pid) do
    GenServer.call(pid, :info, 5_000)
  catch
    :exit, _reason -> {:error, :session_lost}
  end

  @doc false
  def documents(pid), do: GenServer.call(pid, :documents)

  @doc "LSP `languageId` for a path."
  @spec language_id(String.t()) :: String.t()
  def language_id(path) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ".heex" -> "phoenix-heex"
      ".ts" -> "typescript"
      ".tsx" -> "typescriptreact"
      ".jsx" -> "javascriptreact"
      ext when ext in [".js", ".mjs", ".cjs"] -> "javascript"
      ".py" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ext when ext in [".c", ".h"] -> "c"
      ext when ext in [".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"] -> "cpp"
      _ -> "plaintext"
    end
  end

  # Server

  @impl true
  def init(%{key: {_scope, _server_id, root} = key, server: server, owner: owner}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       key: key,
       server: server,
       root: root,
       owner_ref: if(is_pid(owner), do: Process.monitor(owner)),
       owner_pid: owner,
       session_id: nil,
       capabilities: nil,
       documents: %{},
       idle_ref: nil
     }
     |> touch()}
  end

  @impl true
  def handle_call({operation, owner}, _from, state)
      when operation in [:bind_owner, :detach_owner],
      do: CodingAgent.ToolResources.owner_reply(operation, owner, state)

  def handle_call({:sync, path, timeout_ms}, _from, state) do
    state = touch(state)

    case connect(state, timeout_ms) do
      {:ok, state} ->
        case safe_sync(state, path) do
          {:ok, document, state} ->
            {:reply, {:ok, Map.merge(connection(state), document)}, state}

          {:error, :session_lost, state} ->
            {:stop, :normal, {:error, :session_lost}, state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:refresh, _paths}, _from, %{session_id: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:refresh, paths}, _from, state) do
    expanded = MapSet.new(paths, &Path.expand/1)

    state =
      Enum.reduce(state.documents, state, fn {path, _doc}, state ->
        if MapSet.member?(expanded, path), do: resync(state, path), else: state
      end)

    {:reply, :ok, state}
  catch
    :throw, :session_lost -> {:stop, :normal, :ok, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     {:ok,
      %{
        initialized: state.session_id != nil,
        open_documents: map_size(state.documents),
        root: state.root,
        server_id: state.server.id
      }}, state}
  end

  def handle_call(:documents, _from, state), do: {:reply, state.documents, state}

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{session_id: session_id}) when is_binary(session_id) do
    _ = ServerManager.stop_session(session_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connection(state) do
    %{session_id: state.session_id, capabilities: state.capabilities, server: state.server}
  end

  defp connect(%{session_id: session_id} = state, _timeout_ms) when is_binary(session_id),
    do: {:ok, state}

  defp connect(state, timeout_ms) do
    with {:ok, %{session_id: session_id}} <-
           start_session(state),
         {:ok, response} <-
           ServerManager.initialize_session(session_id, initialize_params(state.root),
             timeout_ms: min(timeout_ms, 300_000)
           ) do
      case response do
        %{"result" => %{"capabilities" => capabilities}} when is_map(capabilities) ->
          {:ok, %{state | session_id: session_id, capabilities: capabilities}}

        %{"error" => error} ->
          _ = ServerManager.stop_session(session_id)
          {:error, {:initialize_failed, error_message(error)}, state}

        _other ->
          _ = ServerManager.stop_session(session_id)
          {:error, {:initialize_failed, "server returned no capabilities"}, state}
      end
    else
      {:error, :request_timeout} -> {:error, :initialize_timeout, state}
      {:error, reason} -> {:error, reason, state}
    end
  catch
    :exit, _reason -> {:error, :lsp_unavailable, state}
  end

  defp start_session(state) do
    ServerManager.start_session(state.server.id, cwd: state.root, owner: self())
  end

  defp initialize_params(root) do
    uri = Text.path_to_uri(root)

    %{
      "processId" => String.to_integer(System.pid()),
      "clientInfo" => %{"name" => "lemon"},
      "rootUri" => uri,
      "rootPath" => root,
      "workspaceFolders" => [%{"uri" => uri, "name" => Path.basename(root)}],
      "capabilities" => @client_capabilities,
      "initializationOptions" => %{}
    }
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)

  defp safe_sync(state, path) do
    sync_documents(state, path)
  catch
    :throw, :session_lost -> {:error, :session_lost, state}
    :exit, _reason -> {:error, :session_lost, state}
  end

  defp notify!({:ok, _info}), do: :ok
  defp notify!({:error, _reason}), do: throw(:session_lost)

  defp sync_documents(state, nil), do: {:ok, %{}, resync_open(state, nil)}

  defp sync_documents(state, path) do
    path = Path.expand(path)

    with {:ok, text} <- File.read(path),
         {:ok, %{seq: seq}} <-
           ServerManager.document_diagnostics(state.session_id, Text.path_to_uri(path)) do
      {synced, state} = sync_text(state, path, text)
      state = state |> resync_open(path) |> evict()
      doc = state.documents[path]

      {:ok,
       %{
         uri: doc.uri,
         version: doc.version,
         synced: synced,
         diagnostics_seq: seq,
         documents: state.documents
       }, state}
    else
      {:error, :unknown_lsp_session} -> {:error, :session_lost, state}
      {:error, reason} when is_atom(reason) -> {:error, {:file, reason, path}, state}
    end
  end

  defp sync_text(state, path, text) do
    digest = :erlang.md5(text)
    now = System.monotonic_time()

    case Map.get(state.documents, path) do
      nil ->
        uri = Text.path_to_uri(path)

        notify!(
          ServerManager.open_document(state.session_id, uri, language_id(path), text, version: 1)
        )

        doc = %{uri: uri, version: 1, digest: digest, used_at: now}
        {:opened, put_in(state.documents[path], doc)}

      %{digest: ^digest} = doc ->
        {:unchanged, put_in(state.documents[path], %{doc | used_at: now})}

      doc ->
        version = doc.version + 1
        notify!(ServerManager.change_document(state.session_id, doc.uri, text, version: version))

        {:changed,
         put_in(state.documents[path], %{doc | version: version, digest: digest, used_at: now})}
    end
  end

  # Other open documents may have been changed by edits, formatters or the
  # user since they were opened; stale buffers give wrong cross-file answers.
  defp resync_open(state, current) do
    Enum.reduce(Map.keys(state.documents), state, fn
      ^current, state -> state
      path, state -> resync(state, path)
    end)
  end

  defp resync(state, path) do
    doc = state.documents[path]

    case File.read(path) do
      {:ok, text} ->
        if :erlang.md5(text) == doc.digest do
          state
        else
          version = doc.version + 1

          notify!(
            ServerManager.change_document(state.session_id, doc.uri, text, version: version)
          )

          put_in(state.documents[path], %{doc | version: version, digest: :erlang.md5(text)})
        end

      {:error, _reason} ->
        notify!(ServerManager.close_document(state.session_id, doc.uri))
        %{state | documents: Map.delete(state.documents, path)}
    end
  end

  defp evict(%{documents: documents} = state) when map_size(documents) > @max_open_documents do
    {path, doc} = Enum.min_by(documents, fn {_path, doc} -> doc.used_at end)
    notify!(ServerManager.close_document(state.session_id, doc.uri))
    evict(%{state | documents: Map.delete(documents, path)})
  end

  defp evict(state), do: state

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle_timeout, idle_timeout_ms())}
  end

  defp idle_timeout_ms do
    Application.get_env(:coding_agent, :lsp_idle_timeout_ms, @idle_timeout_ms)
  end
end
