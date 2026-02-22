defmodule LemonWeb.SessionLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonCore.{Bus, MapHelpers, SessionKey}
  alias LemonWeb.Live.Components.{FileUploadComponent, MessageComponent}

  @max_messages 250

  @impl true
  def mount(params, _session, socket) do
    session_key = resolve_session_key(params)
    agent_id = SessionKey.agent_id(session_key) || "default"

    if connected?(socket) do
      Bus.subscribe(Bus.session_topic(session_key))
    end

    socket =
      socket
      |> assign(:page_title, "Lemon Dashboard")
      |> assign(:session_key, session_key)
      |> assign(:agent_id, agent_id)
      |> assign(:prompt, "")
      |> assign(:messages, [])
      |> assign(:last_run_id, nil)
      |> assign(:submit_error, nil)
      |> allow_upload(:files,
        accept: :any,
        max_entries: 5,
        max_file_size: 20_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"chat" => %{"prompt" => prompt}}, socket) do
    {:noreply, assign(socket, :prompt, prompt || "")}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    socket =
      socket
      |> cancel_upload(:files, ref)
      |> assign(:submit_error, nil)

    {:noreply, socket}
  end

  def handle_event("submit", %{"chat" => %{"prompt" => prompt}}, socket) do
    prompt = String.trim(prompt || "")

    if uploads_in_progress?(socket) do
      {:noreply,
       assign(socket, :submit_error, "Please wait for uploads to finish before submitting.")}
    else
      uploads = persist_uploads(socket)

      if prompt == "" and uploads == [] do
        {:noreply, assign(socket, :submit_error, "Enter a prompt or upload at least one file.")}
      else
        submission_prompt = build_submission_prompt(prompt, uploads)
        user_text = build_user_message(prompt, uploads)

        socket =
          socket
          |> append_message(%{
            id: message_id("user"),
            kind: :user,
            content: user_text,
            ts_ms: now_ms()
          })
          |> assign(:prompt, "")
          |> assign(:submit_error, nil)

        case submit_run(
               socket.assigns.session_key,
               socket.assigns.agent_id,
               submission_prompt,
               uploads
             ) do
          {:ok, run_id} ->
            {:noreply, assign(socket, :last_run_id, run_id)}

          {:error, reason} ->
            socket =
              socket
              |> append_message(%{
                id: message_id("system"),
                kind: :system,
                content: "Submit failed: #{format_error(reason)}",
                ts_ms: now_ms()
              })
              |> assign(:submit_error, format_error(reason))

            {:noreply, socket}
        end
      end
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :run_started} = event, socket) do
    run_id = read(event.payload, :run_id) || read(event.meta, :run_id)
    engine = read(event.payload, :engine)

    socket =
      socket
      |> assign(:last_run_id, run_id || socket.assigns.last_run_id)
      |> maybe_append_system("Run started#{if is_binary(engine), do: " (#{engine})", else: ""}.")

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: payload, meta: meta}, socket) do
    run_id = read(payload, :run_id) || read(meta, :run_id) || socket.assigns.last_run_id
    text = read(payload, :text) || ""

    socket =
      if is_binary(text) and text != "" do
        upsert_assistant_delta(socket, run_id, text)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :engine_action, payload: payload}, socket) do
    socket =
      append_message(socket, %{
        id: message_id("tool"),
        kind: :tool_call,
        event: payload,
        ts_ms: now_ms()
      })

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :run_completed, payload: payload, meta: meta}, socket) do
    run_id = read(meta, :run_id) || read(payload, :run_id) || socket.assigns.last_run_id
    completed = read(payload, :completed) || payload
    answer = read(completed, :answer)
    ok? = read(completed, :ok)
    error = read(completed, :error)

    socket =
      socket
      |> finalize_assistant_message(run_id, answer)
      |> maybe_append_run_completion(ok?, error)

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto flex min-h-screen w-full max-w-3xl flex-col px-3 py-4 sm:px-6 sm:py-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-sm">
          <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon Web Dashboard</p>
          <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">Session Console</h1>
          <div class="mt-3 space-y-1 text-xs text-slate-600 sm:flex sm:items-center sm:justify-between sm:space-y-0">
            <p>session: <code class="rounded bg-slate-100 px-1 py-0.5">{@session_key}</code></p>
            <p>agent: <code class="rounded bg-slate-100 px-1 py-0.5">{@agent_id}</code></p>
          </div>
        </header>

        <section
          id="messages"
          class="mt-4 flex-1 space-y-3 overflow-y-auto rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:p-4"
        >
          <%= if @messages == [] do %>
            <p class="text-sm text-slate-500">No messages yet. Send a prompt to start streaming output.</p>
          <% else %>
            <%= for message <- @messages do %>
              <MessageComponent.message message={message} />
            <% end %>
          <% end %>
        </section>

        <section class="mt-4 rounded-2xl border border-slate-200 bg-white p-3 shadow-sm sm:p-4">
          <.form
            for={to_form(%{"prompt" => @prompt}, as: :chat)}
            id="chat-form"
            phx-change="validate"
            phx-submit="submit"
            multipart
            class="space-y-3"
          >
            <label for="chat_prompt" class="text-xs font-medium uppercase tracking-wide text-slate-500">
              Prompt
            </label>
            <textarea
              id="chat_prompt"
              name="chat[prompt]"
              rows="4"
              value={@prompt}
              placeholder="Ask Lemon to do work..."
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-500 focus:ring"
            ></textarea>

            <FileUploadComponent.file_upload upload={@uploads.files} />

            <%= if is_binary(@submit_error) and @submit_error != "" do %>
              <p class="rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700">
                {@submit_error}
              </p>
            <% end %>

            <div class="flex items-center justify-between gap-3">
              <p class="text-xs text-slate-500">Supports multi-file upload and live streaming updates.</p>
              <.button type="submit">Send</.button>
            </div>
          </.form>
        </section>
      </div>
    </main>
    """
  end

  defp submit_run(session_key, agent_id, prompt, uploads) do
    LemonRouter.submit(%{
      origin: :control_plane,
      session_key: session_key,
      agent_id: agent_id,
      prompt: prompt,
      meta: %{
        source: :lemon_web,
        web_dashboard: true,
        uploads: uploads
      }
    })
  end

  defp persist_uploads(socket) do
    upload_root = upload_root()
    :ok = File.mkdir_p(upload_root)

    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
      filename = sanitize_filename(entry.client_name || "upload")

      destination =
        Path.join(
          upload_root,
          "#{System.system_time(:millisecond)}-#{message_id("file")}-#{filename}"
        )

      case File.cp(path, destination) do
        :ok ->
          {:ok,
           %{
             name: entry.client_name,
             path: destination,
             content_type: entry.client_type,
             size: entry.client_size
           }}

        {:error, reason} ->
          {:ok,
           %{
             name: entry.client_name,
             path: nil,
             error: format_error(reason)
           }}
      end
    end)
  end

  defp upload_root do
    Application.get_env(:lemon_web, :uploads_dir) ||
      Path.join(System.tmp_dir!(), "lemon_web_uploads")
  end

  defp build_submission_prompt(prompt, []), do: prompt

  defp build_submission_prompt(prompt, uploads) do
    files_text =
      uploads
      |> Enum.filter(&is_binary(read(&1, :path)))
      |> Enum.map_join("\n", fn file -> "- #{read(file, :path)}" end)

    cond do
      prompt == "" and files_text != "" ->
        "Process these uploaded files:\n#{files_text}"

      files_text == "" ->
        prompt

      true ->
        prompt <> "\n\nUploaded files:\n" <> files_text
    end
  end

  defp build_user_message(prompt, []) do
    if prompt == "", do: "(uploaded files)", else: prompt
  end

  defp build_user_message(prompt, uploads) do
    files =
      uploads
      |> Enum.map(fn file -> read(file, :name) || "file" end)
      |> Enum.reject(&(&1 in [nil, ""]))

    files_suffix = if files == [], do: "", else: "\n\nFiles: " <> Enum.join(files, ", ")

    case prompt do
      "" -> "(uploaded files)" <> files_suffix
      _ -> prompt <> files_suffix
    end
  end

  defp upsert_assistant_delta(socket, run_id, text) do
    run_id = run_id || "unknown"

    {messages, found?} =
      Enum.map_reduce(socket.assigns.messages, false, fn message, found ->
        if message.kind == :assistant and message.run_id == run_id and
             Map.get(message, :pending, false) do
          {Map.update!(message, :content, &(&1 <> text)), true}
        else
          {message, found}
        end
      end)

    if found? do
      assign(socket, :messages, messages)
    else
      append_message(socket, %{
        id: message_id("assistant"),
        kind: :assistant,
        run_id: run_id,
        content: text,
        pending: true,
        ts_ms: now_ms()
      })
    end
  end

  defp finalize_assistant_message(socket, run_id, answer) do
    run_id = run_id || "unknown"

    {messages, found?} =
      Enum.map_reduce(socket.assigns.messages, false, fn message, found ->
        if message.kind == :assistant and message.run_id == run_id do
          content =
            if message.content in [nil, ""] and is_binary(answer) and answer != "" do
              answer
            else
              message.content
            end

          {%{message | content: content, pending: false}, true}
        else
          {message, found}
        end
      end)

    socket = assign(socket, :messages, messages)

    cond do
      found? ->
        socket

      is_binary(answer) and answer != "" ->
        append_message(socket, %{
          id: message_id("assistant"),
          kind: :assistant,
          run_id: run_id,
          content: answer,
          pending: false,
          ts_ms: now_ms()
        })

      true ->
        socket
    end
  end

  defp maybe_append_run_completion(socket, true, _error), do: socket

  defp maybe_append_run_completion(socket, _ok, error) do
    maybe_append_system(socket, "Run failed: #{format_error(error)}")
  end

  defp maybe_append_system(socket, text) when is_binary(text) and text != "" do
    append_message(socket, %{
      id: message_id("system"),
      kind: :system,
      content: text,
      ts_ms: now_ms()
    })
  end

  defp maybe_append_system(socket, _), do: socket

  defp append_message(socket, message) do
    # Prepend for O(1) then reverse to maintain order
    messages = [message | socket.assigns.messages] |> trim_messages_prepend()
    assign(socket, :messages, messages)
  end

  defp trim_messages_prepend(messages) when length(messages) <= @max_messages,
    do: Enum.reverse(messages)

  defp trim_messages_prepend(messages) do
    messages |> Enum.take(@max_messages) |> Enum.reverse()
  end

  # Old function kept for compatibility - now uses prepend-based approach
  # defp trim_messages(messages) when length(messages) <= @max_messages, do: messages
  # defp trim_messages(messages), do: Enum.take(messages, -@max_messages)

  defp resolve_session_key(params) when is_map(params) do
    candidate = params["session_key"]
    agent_id = normalize_agent_id(params["agent_id"])

    cond do
      is_binary(candidate) and candidate != "" and SessionKey.valid?(candidate) ->
        candidate

      true ->
        isolated_session_key(agent_id)
    end
  end

  defp resolve_session_key(_params), do: isolated_session_key("default")

  defp isolated_session_key(agent_id) do
    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "web",
      account_id: "browser",
      peer_kind: :unknown,
      peer_id: "tab-#{session_suffix()}"
    })
  end

  defp session_suffix do
    Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
  end

  defp normalize_agent_id(agent_id) when is_binary(agent_id) do
    agent_id
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9._-]/u, "_")
    |> case do
      "" -> "default"
      value -> value
    end
  end

  defp normalize_agent_id(_), do: "default"

  defp uploads_in_progress?(socket) do
    socket.assigns.uploads.files.entries
    |> Enum.any?(fn entry -> not Map.get(entry, :done?, false) end)
  end

  defp read(map, key), do: MapHelpers.get_key(map, key)

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9._-]/u, "_")
    |> case do
      "" -> "upload"
      value -> value
    end
  end

  defp sanitize_filename(_), do: "upload"

  defp message_id(prefix) when is_binary(prefix) do
    integer = System.unique_integer([:positive])
    "#{prefix}-#{integer}"
  end

  defp now_ms do
    System.system_time(:millisecond)
  end
end
