defmodule Mix.Tasks.Lemon.Games.Client do
  use Mix.Task

  @shortdoc "Interactive local client for two-terminal games play"

  @moduledoc """
  Lightweight terminal client for local game testing against the HTTP API.

  Typical flow:

      # Terminal 1
      mix lemon.games.client --host --agent alpha --game connect4

      # Terminal 2
      mix lemon.games.client --join <MATCH_ID> --agent beta
  """

  @switches [
    agent: :string,
    display_name: :string,
    owner: :string,
    host: :boolean,
    join: :string,
    game: :string,
    visibility: :string,
    token: :string,
    api_base: :string,
    web_base: :string,
    help: :boolean
  ]

  @default_api_base "http://localhost:4040"
  @default_web_base "http://localhost:4080"
  @default_game "connect4"
  @poll_ms 1_000

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        print_help()

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        state = build_state!(opts)
        ensure_runtime_started!()
        :ok = ensure_http_client_started()
        state = maybe_issue_token(state)
        state = maybe_create_or_join(state)
        play_loop(state, nil)
    end
  end

  defp build_state!(opts) do
    mode =
      cond do
        opts[:host] && is_binary(opts[:join]) ->
          Mix.raise("choose either --host or --join <MATCH_ID>")

        opts[:host] ->
          :host

        is_binary(opts[:join]) ->
          :join

        true ->
          Mix.raise("must provide one of: --host or --join <MATCH_ID>")
      end

    agent_id = opts[:agent] || Mix.raise("missing required option --agent")
    game = opts[:game] || @default_game

    unless game in ["connect4", "rock_paper_scissors"] do
      Mix.raise("unsupported --game #{inspect(game)} (expected connect4 or rock_paper_scissors)")
    end

    %{
      mode: mode,
      match_id: opts[:join],
      agent_id: agent_id,
      display_name: opts[:display_name] || agent_id,
      owner_id: opts[:owner] || agent_id,
      game: game,
      visibility: opts[:visibility] || "public",
      token: opts[:token],
      slot: nil,
      api_base: normalize_base(opts[:api_base] || @default_api_base),
      web_base: normalize_base(opts[:web_base] || @default_web_base)
    }
  end

  defp ensure_runtime_started! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("failed to start :lemon_core: #{inspect(reason)}")
    end

    case Application.ensure_all_started(:lemon_games) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("failed to start :lemon_games: #{inspect(reason)}")
    end
  end

  defp ensure_http_client_started do
    :ok = ensure_started(:inets)
    :ok = ensure_started(:ssl)
    :ok
  end

  defp ensure_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("failed to start #{inspect(app)}: #{inspect(reason)}")
    end
  end

  defp maybe_issue_token(%{token: token} = state) when is_binary(token), do: state

  defp maybe_issue_token(state) do
    {:ok, issued} =
      LemonGames.Auth.issue_token(%{
        "agent_id" => state.agent_id,
        "owner_id" => state.owner_id,
        "scopes" => ["games:read", "games:play"]
      })

    Mix.shell().info("issued token for #{state.agent_id}")
    Map.put(state, :token, issued.token)
  end

  defp maybe_create_or_join(%{mode: :host} = state), do: create_match!(state)
  defp maybe_create_or_join(%{mode: :join} = state), do: join_match!(state)

  defp create_match!(state) do
    body = %{"game_type" => state.game, "visibility" => state.visibility}

    case post_json(state, "/v1/games/matches", body) do
      {:ok, 201, %{"match" => match, "viewer" => viewer}} ->
        match_id = match["id"]
        slot = viewer["slot"] || detect_slot(match, state.agent_id)
        print_match_header("created", state, match_id)
        Map.merge(state, %{match_id: match_id, slot: slot})

      {:ok, status, response} ->
        Mix.raise("failed to create match (HTTP #{status}): #{format_http_error(response)}")

      {:error, reason} ->
        Mix.raise("failed to create match: #{inspect(reason)}")
    end
  end

  defp join_match!(state) do
    path = "/v1/games/matches/#{state.match_id}/accept"

    case post_json(state, path, %{}) do
      {:ok, 200, %{"match" => match}} ->
        slot = detect_slot(match, state.agent_id)
        print_match_header("joined", state, state.match_id)
        Map.put(state, :slot, slot)

      {:ok, status, response} ->
        Mix.raise("failed to join match (HTTP #{status}): #{format_http_error(response)}")

      {:error, reason} ->
        Mix.raise("failed to join match: #{inspect(reason)}")
    end
  end

  defp play_loop(state, last_signature) do
    case get_json(state, "/v1/games/matches/#{state.match_id}") do
      {:ok, 200, %{"match" => match}} ->
        slot = state.slot || detect_slot(match, state.agent_id)
        state = %{state | slot: slot}
        signature = match_signature(match)

        if signature != last_signature do
          render_match(match, state)
        end

        case match["status"] do
          "pending_accept" ->
            Process.sleep(@poll_ms)
            play_loop(state, signature)

          "active" ->
            case maybe_take_turn(match, state) do
              :quit ->
                Mix.shell().info("player exited")
                :ok

              :ok ->
                Process.sleep(@poll_ms)
                play_loop(state, signature)
            end

          status when status in ["finished", "expired", "aborted"] ->
            Mix.shell().info("game complete: status=#{status} result=#{inspect(match["result"])}")
            :ok

          _ ->
            Process.sleep(@poll_ms)
            play_loop(state, signature)
        end

      {:ok, status, response} ->
        Mix.raise("failed to fetch match (HTTP #{status}): #{format_http_error(response)}")

      {:error, reason} ->
        Mix.raise("failed to fetch match: #{inspect(reason)}")
    end
  end

  defp maybe_take_turn(match, state) do
    if state.slot && match["next_player"] == state.slot do
      case prompt_move(match["game_type"]) do
        {:ok, move} ->
          submit_move(state, move)
          :ok

        :quit ->
          :quit
      end
    else
      :ok
    end
  end

  defp submit_move(state, move) do
    idempotency_key =
      "cli-#{state.agent_id}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    body = %{"move" => move, "idempotency_key" => idempotency_key}
    path = "/v1/games/matches/#{state.match_id}/moves"

    case post_json(state, path, body) do
      {:ok, 200, %{"accepted_event_seq" => seq}} ->
        Mix.shell().info("move accepted (seq #{seq})")

      {:ok, status, response} ->
        Mix.shell().info("move rejected (HTTP #{status}): #{format_http_error(response)}")

      {:error, reason} ->
        Mix.shell().info("move request failed: #{inspect(reason)}")
    end
  end

  defp prompt_move("connect4") do
    case prompt("your move column [0-6] (or q)") do
      "q" ->
        :quit

      value ->
        case Integer.parse(value) do
          {column, ""} when column in 0..6 ->
            {:ok, %{"kind" => "drop", "column" => column}}

          _ ->
            Mix.shell().info("invalid column")
            prompt_move("connect4")
        end
    end
  end

  defp prompt_move("rock_paper_scissors") do
    case prompt("your throw [rock|paper|scissors] (or q)") do
      "q" ->
        :quit

      value when value in ["rock", "paper", "scissors"] ->
        {:ok, %{"kind" => "throw", "value" => value}}

      _ ->
        Mix.shell().info("invalid throw")
        prompt_move("rock_paper_scissors")
    end
  end

  defp prompt_move(_game_type) do
    Mix.raise("unsupported game type")
  end

  defp prompt(label) do
    IO.gets("#{label}: ")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp render_match(match, state) do
    Mix.shell().info("")
    Mix.shell().info("match #{match["id"]} | #{match["game_type"]} | status=#{match["status"]}")

    Mix.shell().info(
      "you=#{state.agent_id} slot=#{state.slot || "spectator"} next=#{match["next_player"] || "-"} turn=#{match["turn_number"]}"
    )

    case match["game_type"] do
      "connect4" ->
        render_connect4(match["game_state"]["board"] || [])

      "rock_paper_scissors" ->
        render_rps(match["game_state"] || %{})

      _ ->
        :ok
    end
  end

  defp render_connect4(board) do
    Enum.each(board, fn row ->
      row
      |> Enum.map_join(" ", &chip/1)
      |> Mix.shell().info()
    end)

    Mix.shell().info("0 1 2 3 4 5 6")
  end

  defp render_rps(state) do
    throws = state["throws"] || %{}
    Mix.shell().info("p1 throw=#{throws["p1"] || "?"} p2 throw=#{throws["p2"] || "?"}")
  end

  defp chip(0), do: "."
  defp chip(1), do: "X"
  defp chip(2), do: "O"
  defp chip(_), do: "?"

  defp detect_slot(match, agent_id) do
    case Enum.find(match["players"] || %{}, fn {_slot, p} -> p["agent_id"] == agent_id end) do
      {slot, _player} -> slot
      nil -> nil
    end
  end

  defp match_signature(match) do
    {
      match["status"],
      match["turn_number"],
      match["next_player"],
      match["snapshot_seq"],
      match["updated_at_ms"],
      match["result"]
    }
  end

  defp print_match_header(action, state, match_id) do
    Mix.shell().info("#{action} match #{match_id}")
    Mix.shell().info("watch: #{state.web_base}/games/#{match_id}")
  end

  defp get_json(state, path), do: request_json(:get, state, path, nil)
  defp post_json(state, path, body), do: request_json(:post, state, path, body)

  defp request_json(method, state, path, body) do
    url = to_charlist(state.api_base <> path)
    auth = to_charlist("Bearer " <> state.token)
    headers = [{~c"authorization", auth}, {~c"accept", ~c"application/json"}]
    options = [body_format: :binary]

    result =
      case method do
        :get ->
          :httpc.request(:get, {url, headers}, [], options)

        :post ->
          payload = Jason.encode!(body || %{})
          post_headers = [{~c"content-type", ~c"application/json"} | headers]
          :httpc.request(:post, {url, post_headers, ~c"application/json", payload}, [], options)
      end

    case result do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, decode_json_body(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json_body(""), do: %{}
  defp decode_json_body(body) when is_binary(body), do: Jason.decode(body) |> unwrap_json(body)
  defp decode_json_body(_), do: %{}

  defp unwrap_json({:ok, json}, _raw), do: json
  defp unwrap_json({:error, _}, raw), do: %{"raw" => raw}

  defp format_http_error(%{"error" => %{"code" => code, "message" => message}}) do
    "#{code}: #{message}"
  end

  defp format_http_error(payload), do: inspect(payload)

  defp normalize_base(base), do: String.trim_trailing(base, "/")

  defp print_help do
    Mix.shell().info("""
    Usage:
      mix lemon.games.client --host --agent <AGENT_ID> [--game connect4|rock_paper_scissors]
      mix lemon.games.client --join <MATCH_ID> --agent <AGENT_ID>

    Options:
      --agent <ID>          Agent id used for auth and player identity (required)
      --display_name <NAME> Optional display name for player metadata
      --owner <ID>          Owner id used for token issuance (defaults to agent id)
      --host                Create a new match
      --join <MATCH_ID>     Join an existing pending match
      --game <TYPE>         Game type when hosting (default: connect4)
      --visibility <MODE>   public|private (default: public)
      --token <TOKEN>       Use an existing lgm_ token instead of issuing one
      --api_base <URL>      Games API base URL (default: http://localhost:4040)
      --web_base <URL>      Spectator web base URL (default: http://localhost:4080)
    """)
  end
end
