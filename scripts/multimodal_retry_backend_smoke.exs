# Standalone source backend for multimodal_retry_app_smoke.ts. No ExUnit/provider calls.
# Invoked with mix run --no-compile; source must be compiled by the integration owner first.
defmodule MultimodalRetrySmokeBackend do
  alias CodingAgent.SessionManager
  alias LemonControlPlane.Methods.{ChatHistory, SessionsRewind, SessionsTree}

  def run do
    original_provider = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, CodingAgent.ControlPlaneProvider)

    try do
      loop(nil)
    after
      Application.put_env(:lemon_core, :agent_runtime_provider, original_provider)
    end
  end

  defp loop(state) do
    case IO.gets("") do
      :eof ->
        cleanup(state)

      line ->
        request = Jason.decode!(line)
        {result, next} = dispatch(request["method"], request["params"], state)

        IO.puts(
          "MULTIMODAL_RETRY_SMOKE " <> Jason.encode!(%{"id" => request["id"], "result" => result})
        )

        loop(next)
    end
  end

  defp dispatch("seed", params, state) do
    cleanup(state)
    cwd = params["cwd"]
    key = params["sessionKey"]
    text = "Fix error shown in screenshot"

    image = %{
      "type" => "image",
      "data" => Base.encode64("original image bytes"),
      "mime_type" => "image/png"
    }

    message =
      case params["kind"] do
        "text" ->
          %{"role" => "user", "content" => text}

        "mixed" ->
          %{"role" => "user", "content" => [%{"type" => "text", "text" => text}, image]}

        "separate" ->
          %{"role" => "user", "content" => text, "images" => [image]}

        "unknown" ->
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => text},
              %{"type" => "future_media", "data" => "opaque"}
            ]
          }
      end

    target = SessionManager.new(cwd) |> SessionManager.append_message(message)

    session =
      SessionManager.append_message(target, %{"role" => "assistant", "content" => "failed turn"})

    path = CodingAgent.Session.Presentation.session_file_path(session.header.id, cwd)
    :ok = SessionManager.save_to_file(path, session)

    :ok =
      LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: session.header.id
      })

    next = %{key: key, cwd: cwd, path: path, id: session.header.id, target: target.leaf_id}
    {%{"entryId" => target.leaf_id, "prompt" => text}, next}
  end

  defp dispatch("snapshot", _params, state) do
    {:ok, session} = SessionManager.load_from_file(state.path)

    snapshot = %{
      "leafId" => session.leaf_id,
      "digest" => Base.encode16(:crypto.hash(:sha256, File.read!(state.path))),
      "entries" => length(SessionManager.entries(session)),
      "message" => SessionManager.get_entry(session, state.target).message
    }

    {snapshot, state}
  end

  defp dispatch("append", _params, state) do
    {:ok, session} = SessionManager.load_from_file(state.path)

    changed =
      SessionManager.append_message(%{session | file_path: state.path}, %{
        "role" => "user",
        "content" => "a later turn invalidates the original preview"
      })

    {%{"leafId" => changed.leaf_id}, state}
  end

  defp dispatch(method, params, state) do
    handler =
      case method do
        "chat.history" -> ChatHistory
        "sessions.tree" -> SessionsTree
        "sessions.rewind" -> SessionsRewind
      end

    result =
      case handler.handle(params, %{}) do
        {:ok, receipt} ->
          %{"ok" => receipt}

        {:error, {code, message, details}} ->
          %{"error" => %{"code" => to_string(code), "message" => message, "details" => details}}
      end

    {result, state}
  end

  defp cleanup(nil), do: :ok

  defp cleanup(state) do
    LemonCore.ChatStateStore.delete(state.key)
    LemonCore.Store.delete(:session_rewinds, state.id)
    File.rm_rf!(CodingAgent.Config.sessions_dir(state.cwd))
  end
end

MultimodalRetrySmokeBackend.run()
