defmodule LemonSim.Examples.VendingBench.Suppliers do
  @moduledoc """
  Static supplier directory for the Vending Bench simulation.

  Suppliers intentionally vary by reliability and incentives so the operator has
  to research, negotiate, and recover from bad counterparties.
  """

  @suppliers %{
    "freshco" => %{
      name: "FreshCo Distributors",
      email: "orders@freshco.example",
      behavior: "honest_fast",
      items: %{
        "sparkling_water" => %{cost: 1.10, min_order: 6},
        "water" => %{cost: 0.40, min_order: 12},
        "energy_drink" => %{cost: 1.50, min_order: 6},
        "cola" => %{cost: 0.55, min_order: 12},
        "sandwich" => %{cost: 2.20, min_order: 6},
        "protein_box" => %{cost: 2.85, min_order: 4}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      description: "Beverage specialist. Fast 1-day delivery. Good prices on drinks."
    },
    "snackworld" => %{
      name: "SnackWorld Supply",
      email: "sales@snackworld.example",
      behavior: "honest_specialist",
      items: %{
        "chips" => %{cost: 0.80, min_order: 8},
        "candy_bar" => %{cost: 0.60, min_order: 10},
        "trail_mix" => %{cost: 1.20, min_order: 6},
        "granola_bar" => %{cost: 0.85, min_order: 8}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      description: "Snack specialist. 1-day delivery. Wide selection of snacks."
    },
    "drinkdepot" => %{
      name: "DrinkDepot Wholesale",
      email: "bulk@drinkdepot.example",
      behavior: "honest_bulk",
      items: %{
        "sparkling_water" => %{cost: 1.00, min_order: 12},
        "water" => %{cost: 0.35, min_order: 24},
        "energy_drink" => %{cost: 1.40, min_order: 12},
        "cola" => %{cost: 0.50, min_order: 24},
        "chips" => %{cost: 0.75, min_order: 12},
        "candy_bar" => %{cost: 0.55, min_order: 12},
        "sandwich" => %{cost: 2.00, min_order: 12}
      },
      delivery_days: 2,
      minimum_order: 12,
      markup: 0.0,
      description: "Bulk wholesaler. 2-day delivery but lower prices and larger selection."
    },
    "campusliquidators" => %{
      name: "Campus Liquidators",
      email: "deals@campusliquidators.example",
      behavior: "negotiable_discount",
      items: %{
        "chips" => %{cost: 0.82, min_order: 8},
        "candy_bar" => %{cost: 0.62, min_order: 10},
        "water" => %{cost: 0.42, min_order: 12}
      },
      delivery_days: 2,
      minimum_order: 8,
      markup: 0.0,
      negotiated_discount: 0.15,
      description:
        "Closeout supplier. Will discount negotiated bulk orders but requires clear email terms."
    },
    "budgetvend" => %{
      name: "BudgetVend Brokers",
      email: "orders@budgetvend.example",
      behavior: "adversarial_overpricing",
      items: %{
        "sparkling_water" => %{cost: 1.05, min_order: 6},
        "chips" => %{cost: 0.78, min_order: 8},
        "candy_bar" => %{cost: 0.58, min_order: 10}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.45,
      description:
        "Aggressive broker. Fast replies, but inflated invoices make comparison shopping important."
    },
    "quickcrate" => %{
      name: "QuickCrate Logistics",
      email: "dispatch@quickcrate.example",
      behavior: "unreliable_delay",
      items: %{
        "cola" => %{cost: 0.48, min_order: 12},
        "energy_drink" => %{cost: 1.35, min_order: 6},
        "trail_mix" => %{cost: 1.10, min_order: 6}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      max_delay_days: 2,
      description:
        "Low-cost logistics supplier. Good prices, but some deliveries slip by one or two days."
    },
    "switcheroo" => %{
      name: "Switcheroo Wholesale",
      email: "sales@switcheroo.example",
      behavior: "bait_switch",
      items: %{
        "sparkling_water" => %{cost: 0.92, min_order: 6, substitute_item_id: "water"},
        "candy_bar" => %{cost: 0.52, min_order: 10, substitute_item_id: "granola_bar"}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      description:
        "Suspicious discount supplier. Advertises attractive items but may ship substitutes."
    },
    "ghostsupply" => %{
      name: "GhostSupply Depot",
      email: "orders@ghostsupply.example",
      behavior: "shutdown",
      items: %{
        "water" => %{cost: 0.30, min_order: 24},
        "chips" => %{cost: 0.65, min_order: 12}
      },
      delivery_days: 2,
      minimum_order: 12,
      markup: 0.0,
      shutdown_day: 3,
      description:
        "Very cheap supplier that exits the market after day 2 and sends shutdown notices afterward."
    }
  }

  @spec directory() :: map()
  def directory, do: @suppliers

  @spec lookup(String.t()) :: {String.t(), map()} | nil
  def lookup(identifier) when is_binary(identifier) do
    normalized = identifier |> String.trim() |> String.downcase()

    Enum.find(@suppliers, fn {id, supplier} ->
      id == normalized or supplier.email == normalized
    end)
  end

  @spec research(String.t()) :: [%{title: String.t(), body: String.t()}]
  def research(query) when is_binary(query) do
    terms = query_terms(query)

    @suppliers
    |> Enum.filter(fn {id, supplier} ->
      searchable =
        [
          id,
          supplier.name,
          supplier.description,
          supplier.behavior,
          supplier.items |> Map.keys() |> Enum.join(" ")
        ]
        |> Enum.join(" ")
        |> String.downcase()

      terms == [] or Enum.any?(terms, &String.contains?(searchable, &1))
    end)
    |> Enum.map(fn {id, supplier} ->
      %{
        title: "#{supplier.name} (#{supplier.email})",
        body:
          "#{supplier.description} Supplier id #{id}. Delivery #{supplier.delivery_days} day(s). Carries #{supplier.items |> Map.keys() |> Enum.sort() |> Enum.join(", ")}."
      }
    end)
  end

  @spec process_message(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, map()}
  def process_message(to, subject, body, current_day) do
    case lookup(to) do
      nil ->
        {:error,
         %{
           supplier_id: "mailer-daemon",
           message: "Delivery failed: no supplier is known at #{to}.",
           metadata: %{kind: "bounce", to: to, subject: subject}
         }}

      {supplier_id, supplier} ->
        if supplier_closed?(supplier, current_day) do
          {:error,
           %{
             supplier_id: supplier_id,
             message:
               "#{supplier.name} is no longer accepting orders and has shut down operations.",
             metadata: %{
               kind: "supplier_shutdown",
               to: supplier.email,
               subject: subject,
               shutdown_day: supplier.shutdown_day
             }
           }}
        else
          case parse_order(body) do
            {:ok, item_id, quantity} ->
              case process_order(supplier_id, item_id, quantity, current_day,
                     negotiated?: negotiated?(subject <> "\n" <> body)
                   ) do
                {:ok, order} ->
                  {:ok,
                   %{
                     supplier_id: supplier_id,
                     item_id: item_id,
                     quantity: quantity,
                     cost: order.cost,
                     delivery_day: order.delivery_day,
                     message: confirmation_text(supplier, item_id, quantity, order),
                     metadata:
                       order.metadata
                       |> Map.merge(%{
                         kind: "order_confirmed",
                         to: supplier.email,
                         subject: subject,
                         cost: order.cost,
                         delivery_day: order.delivery_day
                       })
                   }}

                {:error, reason} ->
                  {:error,
                   %{
                     supplier_id: supplier_id,
                     message: "#{supplier.name} cannot process this order: #{reason}",
                     metadata: %{kind: "order_rejected", to: supplier.email, subject: subject}
                   }}
              end

            :no_order ->
              {:ok,
               %{
                 supplier_id: supplier_id,
                 message: quote_text(supplier_id),
                 metadata: %{kind: "quote", to: supplier.email, subject: subject}
               }}

            {:ambiguous_order, matches} ->
              items =
                matches
                |> Enum.map(fn {item_id, quantity} -> "#{quantity}x #{item_id}" end)
                |> Enum.join(", ")

              {:error,
               %{
                 supplier_id: supplier_id,
                 message:
                   "#{supplier.name} cannot process this order: multiple products detected (#{items}). Send one product per supplier email.",
                 metadata: %{
                   kind: "order_rejected",
                   to: supplier.email,
                   subject: subject,
                   reason: "multiple_products_in_single_email",
                   detected_items: matches
                 }
               }}
          end
        end
    end
  end

  @spec process_order(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, %{cost: float(), delivery_day: pos_integer()}} | {:error, String.t()}
  def process_order(supplier_id, item_id, quantity, current_day, opts \\ []) do
    case Map.get(@suppliers, supplier_id) do
      nil ->
        {:error, "Unknown supplier: #{supplier_id}"}

      supplier ->
        cond do
          supplier_closed?(supplier, current_day) ->
            {:error, "#{supplier.name} has shut down and is no longer accepting orders"}

          true ->
            case Map.get(supplier.items, item_id) do
              nil ->
                {:error, "#{supplier.name} does not carry #{item_id}"}

              item_info ->
                cond do
                  quantity <= 0 ->
                    {:error, "Quantity must be positive"}

                  quantity < item_info.min_order ->
                    {:error,
                     "Minimum order for #{item_id} from #{supplier.name} is #{item_info.min_order} units"}

                  true ->
                    {:ok,
                     build_order(
                       supplier_id,
                       supplier,
                       item_id,
                       item_info,
                       quantity,
                       current_day,
                       opts
                     )}
                end
            end
        end
    end
  end

  @spec supplier_info_text(String.t()) :: String.t()
  def supplier_info_text(supplier_id) do
    case Map.get(@suppliers, supplier_id) do
      nil ->
        "Unknown supplier: #{supplier_id}"

      supplier ->
        items_text =
          supplier.items
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.map(fn {name, info} ->
            "  - #{name}: $#{:erlang.float_to_binary(info.cost, decimals: 2)}/unit (min order: #{info.min_order})"
          end)
          |> Enum.join("\n")

        """
        #{supplier.name} (#{supplier_id})
        Email: #{supplier.email}
        #{supplier.description}
        Behavior: #{supplier.behavior}
        Delivery: #{supplier.delivery_days} day(s)
        Items:
        #{items_text}
        """
    end
  end

  @spec directory_text() :: String.t()
  def directory_text do
    @suppliers
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, _} -> supplier_info_text(id) end)
    |> Enum.join("\n---\n")
  end

  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(&1 in ~w(supplier suppliers vending machine product products order quote)))
  end

  defp parse_order(body) do
    normalized = String.downcase(body)

    if String.contains?(normalized, ["order", "buy", "purchase", "send", "deliver"]) do
      matches =
        @suppliers
        |> Enum.flat_map(fn {_id, supplier} -> Map.keys(supplier.items) end)
        |> Enum.uniq()
        |> Enum.flat_map(fn item_id ->
          item_id
          |> item_aliases()
          |> Enum.find_value(fn alias_text ->
            case quantity_for_alias(normalized, alias_text) do
              nil -> nil
              quantity -> {item_id, quantity}
            end
          end)
          |> List.wrap()
        end)

      case matches do
        [] -> :no_order
        [{item_id, quantity}] -> {:ok, item_id, quantity}
        _ -> {:ambiguous_order, matches}
      end
    else
      :no_order
    end
  end

  defp item_aliases(item_id) do
    spaced = String.replace(item_id, "_", " ")

    [item_id, spaced, pluralize(spaced)]
    |> Enum.uniq()
  end

  defp pluralize(text) do
    cond do
      String.ends_with?(text, "box") -> text <> "es"
      String.ends_with?(text, "y") -> String.replace_suffix(text, "y", "ies")
      true -> text <> "s"
    end
  end

  defp quantity_for_alias(normalized, alias_text) do
    alias_pattern = Regex.escape(alias_text)
    item_pattern = "(?<![a-z0-9_])#{alias_pattern}(?![a-z0-9_])"

    [
      ~r/(?:#{item_pattern})\D{0,24}(\d+)/,
      ~r/(\d+)\D{0,24}(?:#{item_pattern})/
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, normalized) do
        [_, quantity] -> String.to_integer(quantity)
        _ -> nil
      end
    end)
  end

  defp quote_text(supplier_id) do
    case Map.fetch(@suppliers, supplier_id) do
      {:ok, supplier} ->
        items =
          supplier.items
          |> Enum.sort_by(fn {item_id, _info} -> item_id end)
          |> Enum.map(fn {item_id, info} ->
            "#{item_id}: $#{format_price(info.cost)}/unit, min #{info.min_order}"
          end)
          |> Enum.join("; ")

        "#{supplier.name} quote: #{items}. Delivery #{supplier.delivery_days} day(s). Behavior: #{supplier.behavior}."

      :error ->
        "Supplier unavailable."
    end
  end

  defp format_price(price) when is_float(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp supplier_closed?(supplier, current_day) do
    shutdown_day = Map.get(supplier, :shutdown_day)
    is_integer(shutdown_day) and current_day >= shutdown_day
  end

  defp negotiated?(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, [
      "discount",
      "bulk",
      "price match",
      "match price",
      "long term",
      "long-term",
      "better price",
      "negotiate"
    ])
  end

  defp build_order(supplier_id, supplier, item_id, item_info, quantity, current_day, opts) do
    negotiated? = Keyword.get(opts, :negotiated?, false)
    discount = negotiated_discount(supplier, negotiated?)
    delay_days = delivery_delay_days(supplier_id, supplier, item_id, quantity, current_day)
    delivered_item_id = Map.get(item_info, :substitute_item_id, item_id)
    unit_cost = item_info.cost * (1.0 + supplier.markup) * (1.0 - discount)
    total_cost = Float.round(unit_cost * quantity, 2)
    delivery_day = current_day + supplier.delivery_days + delay_days

    metadata =
      %{
        behavior: supplier.behavior,
        ordered_item_id: item_id,
        delivered_item_id: delivered_item_id,
        discount_rate: discount,
        delivery_delay_days: delay_days,
        supplier_issue: delivered_item_id != item_id or delay_days > 0 or supplier.markup > 0.0
      }
      |> maybe_put(:substituted_item_id, delivered_item_id, delivered_item_id != item_id)

    %{
      supplier_id: supplier_id,
      item_id: item_id,
      quantity: quantity,
      cost: total_cost,
      delivery_day: delivery_day,
      metadata: metadata
    }
  end

  defp negotiated_discount(%{behavior: "negotiable_discount"} = supplier, true),
    do: Map.get(supplier, :negotiated_discount, 0.0)

  defp negotiated_discount(_supplier, _negotiated?), do: 0.0

  defp delivery_delay_days(
         _supplier_id,
         %{behavior: "unreliable_delay"} = supplier,
         item_id,
         quantity,
         current_day
       ) do
    max_delay = Map.get(supplier, :max_delay_days, 2)
    rem(:erlang.phash2({item_id, quantity, current_day}), max_delay + 1)
  end

  defp delivery_delay_days(_supplier_id, _supplier, _item_id, _quantity, _current_day), do: 0

  defp confirmation_text(supplier, item_id, quantity, order) do
    parts = [
      "#{supplier.name} confirms #{quantity}x #{item_id} for $#{format_price(order.cost)}.",
      "Delivery day #{order.delivery_day}."
    ]

    parts =
      if get_in(order, [:metadata, :discount_rate]) > 0.0 do
        parts ++ ["Negotiated discount applied."]
      else
        parts
      end

    parts =
      if get_in(order, [:metadata, :delivery_delay_days]) > 0 do
        parts ++
          [
            "Carrier notice: delivery is delayed by #{get_in(order, [:metadata, :delivery_delay_days])} day(s)."
          ]
      else
        parts
      end

    parts =
      case get_in(order, [:metadata, :substituted_item_id]) do
        nil ->
          parts

        substitute ->
          parts ++ ["Fulfillment note: #{substitute} will be shipped instead of #{item_id}."]
      end

    Enum.join(parts, " ")
  end

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map
end
