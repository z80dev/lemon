defmodule LemonSimUi.AdminSimController do
  use LemonSimUi, :controller

  alias LemonSimUi.SimManager

  @player_count_domains ~w(werewolf stock_market survivor space_station auction diplomacy courtroom startup_incubator intel_network legislature pandemic murder_mystery supply_chain)a
  @multi_model_domains ~w(werewolf stock_market survivor space_station)a
  @watchable_domains ~w(werewolf vending_bench tcg_shop)a

  def create(conn, params) do
    with {:ok, domain} <- parse_domain(params["domain"]),
         {:ok, opts} <- build_start_opts(domain, params),
         {:ok, sim_id} <- SimManager.start_sim(domain, opts) do
      payload = %{
        "sim_id" => sim_id,
        "domain" => Atom.to_string(domain),
        "admin_url" => url(~p"/admin/sims/#{sim_id}"),
        "watch_url" => watch_url(domain, sim_id)
      }

      conn
      |> put_status(:created)
      |> json(payload)
    else
      {:error, :invalid_domain} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_domain"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => format_reason(reason)})
    end
  end

  def stop(conn, %{"sim_id" => sim_id}) do
    case SimManager.stop_sim(sim_id) do
      :ok ->
        json(conn, %{"sim_id" => sim_id, "status" => "stopped"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => format_reason(reason)})
    end
  end

  defp parse_domain(domain) when is_binary(domain) do
    case String.trim(domain) do
      "" ->
        {:error, :invalid_domain}

      trimmed ->
        atom = String.to_existing_atom(trimmed)

        if domain_supported?(atom) do
          {:ok, atom}
        else
          {:error, :invalid_domain}
        end
    end
  rescue
    ArgumentError -> {:error, :invalid_domain}
  end

  defp parse_domain(_), do: {:error, :invalid_domain}

  defp domain_supported?(domain) do
    domain in [
      :tic_tac_toe,
      :skirmish,
      :werewolf,
      :stock_market,
      :survivor,
      :space_station,
      :auction,
      :diplomacy,
      :dungeon_crawl,
      :courtroom,
      :startup_incubator,
      :intel_network,
      :legislature,
      :pandemic,
      :murder_mystery,
      :supply_chain,
      :vending_bench,
      :tcg_shop
    ]
  end

  defp build_start_opts(:tic_tac_toe, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_turns, params["max_turns"])}
  end

  defp build_start_opts(:skirmish, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_turns, params["max_turns"])
     |> maybe_put_int(:rng_seed, params["rng_seed"])
     |> maybe_put_int(:map_width, params["map_width"])
     |> maybe_put_int(:map_height, params["map_height"])
     |> maybe_put_string(:map_preset, params["map_preset"])}
  end

  defp build_start_opts(:dungeon_crawl, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:party_size, params["party_size"])}
  end

  defp build_start_opts(:vending_bench, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_days, params["max_days"])
     |> maybe_put_int(:max_turns, params["max_turns"])
     |> maybe_put_int(:driver_max_turns, params["driver_max_turns"])
     |> maybe_put_string(:operator_model_spec, params["operator_model_spec"])
     |> maybe_put_string(:physical_worker_model_spec, params["physical_worker_model_spec"])
     |> maybe_put_string(:model_spec, params["model_spec"])
     |> maybe_put_string(:worker_model_spec, params["worker_model_spec"])}
  end

  defp build_start_opts(:tcg_shop, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_days, params["max_days"])
     |> maybe_put_int(:max_turns, params["max_turns"])
     |> maybe_put_int(:driver_max_turns, params["driver_max_turns"])
     |> maybe_put_string(:operator_model_spec, params["operator_model_spec"])
     |> maybe_put_model_specs(params["model_specs"])}
  end

  defp build_start_opts(domain, params) when domain in @player_count_domains do
    opts =
      []
      |> maybe_put_string(:sim_id, params["sim_id"])
      |> maybe_put_int(:player_count, params["player_count"])

    opts =
      if domain in @multi_model_domains do
        maybe_put_model_specs(opts, params["model_specs"])
      else
        opts
      end

    {:ok, opts}
  end

  defp build_start_opts(_domain, params) do
    {:ok, maybe_put_string([], :sim_id, params["sim_id"])}
  end

  defp maybe_put_model_specs(opts, specs) when is_list(specs) do
    cleaned =
      specs
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)

    if cleaned == [], do: opts, else: Keyword.put(opts, :model_specs, cleaned)
  end

  defp maybe_put_model_specs(opts, _), do: opts

  defp maybe_put_int(opts, _key, nil), do: opts

  defp maybe_put_int(opts, key, value) do
    case parse_int(value) do
      nil -> opts
      parsed -> Keyword.put(opts, key, parsed)
    end
  end

  defp maybe_put_string(opts, _key, nil), do: opts

  defp maybe_put_string(opts, key, value) do
    case normalize_string(value) do
      nil -> opts
      parsed -> Keyword.put(opts, key, parsed)
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp watch_url(domain, sim_id) when domain in @watchable_domains, do: url(~p"/watch/#{sim_id}")
  defp watch_url(_domain, _sim_id), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
