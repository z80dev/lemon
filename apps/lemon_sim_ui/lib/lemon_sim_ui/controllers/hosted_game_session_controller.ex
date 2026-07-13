defmodule LemonSimUi.HostedGameSessionController do
  @moduledoc false

  use LemonSimUi, :controller

  alias LemonSimUi.HostedGame

  @recent_room_sessions_key "hosted_werewolf_recent_sessions"
  @max_room_sessions 8

  def create(conn, raw_params) do
    case nested_params(raw_params, "room") do
      {:ok, params} -> create_room(conn, Map.delete(params, "seed"))
      :error -> invalid_request(conn, ~p"/play")
    end
  end

  defp create_room(conn, params) do
    create_token = Map.get(params, "create_token")

    if HostedGame.creation_authorized?(create_token) do
      case HostedGame.create_room(params) do
        {:ok, room} ->
          conn
          |> configure_session(renew: true)
          |> put_room_session(HostedGame.host_session_key(room.room_id), room.host_token)
          |> redirect(to: room.host_path)

        {:error, reason} ->
          conn
          |> put_flash(:error, error_message(reason))
          |> redirect(to: ~p"/play")
      end
    else
      conn
      |> put_flash(:error, "That host invite is not valid.")
      |> redirect(to: ~p"/play")
    end
  end

  def join(conn, raw_params) do
    case nested_params(raw_params, "player") do
      {:ok, params} -> join_room(conn, params)
      :error -> invalid_request(conn, ~p"/play")
    end
  end

  defp join_room(conn, params) do
    join_code = string_param(params, "join_code")
    seat_id = string_param(params, "seat_id")
    display_name = string_param(params, "display_name")

    case HostedGame.join_view(join_code) do
      {:ok, room} ->
        session_key = HostedGame.player_session_key(room.room_id)

        case get_session(conn, session_key) do
          nil ->
            claim_seat(conn, join_code, seat_id, display_name)

          token ->
            case HostedGame.player_view(room.room_id, token) do
              {:ok, _view} ->
                conn
                |> put_flash(:info, "This browser already holds a seat in that room.")
                |> redirect(to: ~p"/rooms/#{room.room_id}/play")

              _ ->
                conn
                |> delete_session(session_key)
                |> claim_seat(join_code, seat_id, display_name)
            end
        end

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: join_redirect(join_code))
    end
  end

  defp nested_params(raw_params, key) when is_map(raw_params) do
    case Map.get(raw_params, key, raw_params) do
      %{} = params -> {:ok, params}
      _ -> :error
    end
  end

  defp nested_params(_raw_params, _key), do: :error
  defp string_param(params, key), do: if(is_binary(params[key]), do: params[key], else: "")

  defp invalid_request(conn, path) do
    conn
    |> put_flash(:error, "The submitted form was not valid.")
    |> redirect(to: path)
  end

  defp claim_seat(conn, join_code, seat_id, display_name) do
    case HostedGame.claim_seat(join_code, seat_id, display_name) do
      {:ok, claim} ->
        conn
        |> configure_session(renew: true)
        |> put_room_session(HostedGame.player_session_key(claim.room_id), claim.player_token)
        |> redirect(to: ~p"/rooms/#{claim.room_id}/play")

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: join_redirect(join_code))
    end
  end

  def export(conn, %{"room_id" => room_id}) do
    token = get_session(conn, HostedGame.host_session_key(room_id))

    case HostedGame.export_replay(room_id, token) do
      {:ok, replay} ->
        body = replay |> json_safe() |> Jason.encode!(pretty: true)

        send_download(conn, {:binary, body},
          filename: "werewolf-#{room_id}-replay.json",
          content_type: "application/json"
        )

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> text("Unauthorized")

      {:error, reason} ->
        conn |> put_status(:conflict) |> text(error_message(reason))
    end
  end

  defp error_message(:hosted_rooms_disabled), do: "Hosted games are disabled on this deployment."
  defp error_message(:room_limit_reached), do: "This server has reached its room limit."
  defp error_message(:invalid_player_count), do: "Choose between 5 and 8 players."
  defp error_message(:invalid_ai_seats), do: "The AI seat count is not valid."
  defp error_message(:hosted_ai_not_configured),
    do: "AI seats are not configured on this deployment."
  defp error_message(:invalid_turn_timeout), do: "Turn timers must be between 15 and 600 seconds."
  defp error_message(:invalid_join_code), do: "That room code was not found."
  defp error_message(:invalid_display_name), do: "Choose a name between 1 and 40 characters."
  defp error_message(:seat_taken), do: "That seat was just claimed. Choose another."
  defp error_message(:seat_not_joinable), do: "That seat is not open to a player."
  defp error_message(:invalid_room_status), do: "That room is no longer accepting players."
  defp error_message(:game_in_progress), do: "Replay export unlocks after the match ends."
  defp error_message({:persistence_failed, _}), do: "The room could not be saved. Try again."
  defp error_message(_reason), do: "The request could not be completed."

  defp json_safe(value) when is_struct(value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when value in [true, false, nil], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp put_room_session(conn, key, token) do
    previous = List.wrap(get_session(conn, @recent_room_sessions_key))
    recent = Enum.take([key | List.delete(previous, key)], @max_room_sessions)

    conn =
      previous
      |> Enum.reject(&(&1 in recent))
      |> Enum.reduce(conn, &delete_session(&2, &1))

    conn
    |> put_session(@recent_room_sessions_key, recent)
    |> put_session(key, token)
  end

  defp join_redirect(join_code) do
    code = join_code |> String.trim() |> String.upcase()

    if code =~ ~r/^[A-Z2-9]{10}$/ do
      ~p"/join/#{code}"
    else
      ~p"/play"
    end
  end
end
