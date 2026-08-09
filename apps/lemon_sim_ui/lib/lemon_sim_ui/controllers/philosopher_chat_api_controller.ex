defmodule LemonSimUi.PhilosopherChatApiController do
  @moduledoc """
  JSON API for hosted PhilosopherChat threads.

  Thin surface over `LemonSimUi.PhilosopherChat` (coordinator), `Persona`
  (roster), and `Auth` (session). The SSE stream route authenticates
  manually (query param or header) because `EventSource` cannot set
  request headers.
  """

  use LemonSimUi, :controller

  require Logger

  alias LemonSim.Examples.PhilosopherChat.Persona
  alias LemonSimUi.PhilosopherChat
  alias LemonSimUi.PhilosopherChat.Auth

  @heartbeat_ms 15_000

  # -- session (public) --

  # CORS preflight catch-all: headers are set by Plugs.ChatCors in the
  # pipeline; this just answers 204.
  def preflight(conn, _params), do: send_resp(conn, 204, "")

  def session(conn, params) do
    case Auth.record_login_attempt(conn.remote_ip) do
      :ok ->
        case Auth.login(Map.get(params, "password")) do
          {:ok, token} ->
            Auth.reset_login_attempts(conn.remote_ip)
            json(conn, %{token: token, user: %{id: "you", name: "You"}})

          {:error, :unauthorized} ->
            conn |> put_status(401) |> json(%{error: "unauthorized"})
        end

      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})
    end
  end

  # -- roster --

  # Exchanges the bearer token (header) for a short-lived stream ticket
  # (query param), so EventSource never puts the bearer token in a URL.
  def stream_ticket(conn, _params) do
    json(conn, %{ticket: Auth.issue_stream_ticket()})
  end

  def roster(conn, _params) do
    contacts =
      Persona.roster()
      |> Enum.map(fn persona ->
        Map.take(persona, [
          :id,
          :name,
          :era,
          :tradition,
          :emoji,
          :color,
          :known_for,
          :doctrine,
          :style,
          :relationships
        ])
      end)

    json(conn, %{contacts: contacts})
  end

  # -- threads --

  def index(conn, _params) do
    {:ok, summaries} = PhilosopherChat.list_threads()
    json(conn, %{threads: summaries})
  end

  def create(conn, params) do
    name = Map.get(params, "name", "")
    member_ids = Map.get(params, "member_ids", [])
    pace = Map.get(params, "pace", "relaxed")

    if is_binary(name) and is_list(member_ids) and Enum.all?(member_ids, &is_binary/1) and
         pace in ["relaxed", "chatty"] do
      case PhilosopherChat.create_thread(name, member_ids, %{"pace" => pace}) do
        {:ok, thread_id} ->
          conn |> put_status(201) |> json(%{thread_id: thread_id})

        {:error, reason} ->
          bad_request(conn, create_error(reason))
      end
    else
      bad_request(conn, "Invalid request")
    end
  end

  def show(conn, %{"id" => id}) do
    case PhilosopherChat.view(id) do
      {:ok, view} -> json(conn, %{thread: view})
      {:error, _reason} -> not_found(conn)
    end
  end

  def create_message(conn, %{"id" => id} = params) do
    text = Map.get(params, "text", "")
    client_msg_id = Map.get(params, "client_msg_id")

    case PhilosopherChat.post_user_message(id, text, client_msg_id) do
      {:ok, view} ->
        json(conn, %{thread: view, duplicate: Map.get(view, :duplicate, false)})

      {:error, :thread_not_found} ->
        not_found(conn)

      {:error, reason} ->
        bad_request(conn, message_error(reason))
    end
  end

  def nudge(conn, %{"id" => id} = params) do
    agent_id = Map.get(params, "agent_id")

    if is_binary(agent_id) do
      case PhilosopherChat.nudge(id, agent_id) do
        {:ok, %{scheduled: scheduled}} ->
          json(conn, %{scheduled: scheduled})

        {:error, :thread_not_found} ->
          not_found(conn)

        {:error, reason} ->
          bad_request(conn, nudge_error(reason))
      end
    else
      bad_request(conn, "Invalid request")
    end
  end

  def pause(conn, %{"id" => id}), do: change_status(conn, id, "paused")
  def resume(conn, %{"id" => id}), do: change_status(conn, id, "active")

  def memories(conn, %{"id" => id, "agent_id" => agent_id}) do
    case PhilosopherChat.memories(id, agent_id) do
      {:ok, memories} -> json(conn, %{memories: memories})
      {:error, _reason} -> not_found(conn)
    end
  end

  def events(conn, %{"id" => id} = params) do
    since = parse_since(Map.get(params, "since"))

    case PhilosopherChat.events(id, since) do
      {:ok, payload} -> json(conn, payload)
      {:error, _reason} -> not_found(conn)
    end
  end

  # -- SSE stream (public route; verifies the ticket/token manually) --

  def stream(conn, %{"id" => id} = params) do
    with :ok <- authorize_stream(conn, params),
         {:ok, _view} <- PhilosopherChat.view(id) do
      # Subscribe BEFORE reading the missed log: events that land between the
      # read and the subscribe would otherwise be lost; overlap only
      # duplicates, and clients dedupe by event_seq.
      LemonCore.Bus.subscribe(PhilosopherChat.topic(id))
      {:ok, %{events: missed}} = PhilosopherChat.events(id, parse_since(Map.get(params, "since")))

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      conn =
        Enum.reduce_while(missed, conn, fn event, acc ->
          case chunk_event(acc, event.payload) do
            {:ok, acc} -> {:cont, acc}
            :error -> {:halt, acc}
          end
        end)

      stream_loop(conn)
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, _reason} ->
        not_found(conn)
    end
  end

  defp stream_loop(conn) do
    receive do
      %LemonCore.Event{type: :philosopher_chat_update, payload: payload} ->
        case chunk_event(conn, payload) do
          {:ok, conn} -> stream_loop(conn)
          :error -> conn
        end

      _other ->
        stream_loop(conn)
    after
      @heartbeat_ms ->
        case safe_chunk(conn, "data: {\"type\":\"ping\"}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          :error -> conn
        end
    end
  end

  # Encodes inside the guard: an undecodable payload is skipped rather than
  # killing the stream.
  defp chunk_event(conn, payload) do
    case Jason.encode(payload) do
      {:ok, json} -> safe_chunk(conn, "data: " <> json <> "\n\n")
      {:error, _reason} -> {:ok, conn}
    end
  end

  defp safe_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> :error
    end
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp authorize_stream(conn, params) do
    cond do
      Auth.dev_bypass?() ->
        :ok

      is_binary(Map.get(params, "ticket")) ->
        verify_ticket(Map.get(params, "ticket"))

      # Legacy round-1 clients pass the bearer token in the query string.
      is_binary(Map.get(params, "token")) ->
        verify_token(Map.get(params, "token"))

      true ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] -> verify_token(token)
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp verify_ticket(ticket) do
    case Auth.verify_stream_ticket(ticket) do
      {:ok, _user} -> :ok
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp verify_token(token) do
    case Auth.verify(token) do
      {:ok, _user} -> :ok
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  # -- helpers --

  defp change_status(conn, id, status) do
    case PhilosopherChat.set_status(id, status) do
      {:ok, %{status: new_status}} -> json(conn, %{status: new_status})
      {:error, :thread_not_found} -> not_found(conn)
      {:error, reason} -> bad_request(conn, Atom.to_string(reason))
    end
  end

  defp not_found(conn) do
    conn |> put_status(404) |> json(%{error: "not_found"})
  end

  defp bad_request(conn, message) do
    conn |> put_status(400) |> json(%{error: message})
  end

  defp parse_since(nil), do: 0
  defp parse_since(value) when is_integer(value), do: max(value, 0)

  defp parse_since(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> max(int, 0)
      :error -> 0
    end
  end

  # Catches query garbage like `?since[a]=1` (parsed as a map).
  defp parse_since(_value), do: 0

  defp create_error(:name_required), do: "Name is required"
  defp create_error(:name_too_long), do: "Name is too long"
  defp create_error(:too_few_members), do: "Pick at least one philosopher"
  defp create_error(:too_many_members), do: "Maximum 6 philosophers"
  defp create_error(:unknown_member), do: "Unknown philosopher"
  defp create_error(:duplicate_member), do: "Duplicate member"
  defp create_error(:thread_limit_reached), do: "Thread limit reached"
  defp create_error(:philosopher_chat_disabled), do: "Service disabled"
  defp create_error(other), do: Atom.to_string(other)

  defp message_error(:empty_message), do: "Message is required"
  defp message_error(:message_too_long), do: "Message is too long"
  defp message_error(:thread_not_active), do: "Thread is not active"
  defp message_error(:invalid_client_msg_id), do: "Invalid client_msg_id"
  defp message_error(other), do: Atom.to_string(other)

  defp nudge_error(:thread_not_active), do: "Thread is not active"
  defp nudge_error(:not_a_member), do: "Not a member of this thread"
  defp nudge_error(:cooldown_active), do: "Cooldown active"
  defp nudge_error(other), do: Atom.to_string(other)
end
