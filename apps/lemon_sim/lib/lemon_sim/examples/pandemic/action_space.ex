defmodule LemonSim.Examples.Pandemic.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Pandemic.Events
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @comm_quota 3

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase == "intelligence" ->
        {:ok, Enum.map(intelligence_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "communication" ->
        {:ok, Enum.map(communication_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "resource_allocation" ->
        {:ok, Enum.map(allocation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "local_action" ->
        {:ok, Enum.map(local_action_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Intelligence phase tools --

  defp intelligence_tools(world, actor_id) do
    players = get(world, :players, %{})
    player = Map.get(players, actor_id, %{})
    own_region = Map.get(player, :region, actor_id)
    travel_routes = get(world, :travel_routes, %{})
    neighbors = Map.get(travel_routes, own_region, [])
    checkable_regions = [own_region | neighbors]

    [
      check_region_tool(actor_id, checkable_regions),
      end_intelligence_tool(actor_id)
    ]
  end

  defp check_region_tool(actor_id, regions) do
    region_enum = Enum.map(regions, &%{"const" => &1})

    %AgentTool{
      name: "check_region",
      description:
        "Check the current disease situation in a region. " <>
          "You can check your own region and directly connected neighbors. " <>
          "Returns real-time infection data for checked regions. " <>
          "Available: #{Enum.join(regions, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "region_id" => %{
            "type" => "string",
            "description" => "The region to check",
            "anyOf" => region_enum
          }
        },
        "required" => ["region_id"],
        "additionalProperties" => false
      },
      label: "Check Region",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        region_id = Map.get(params, "region_id", Map.get(params, :region_id))
        event = Events.check_region(actor_id, region_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("checking region #{region_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_intelligence_tool(actor_id) do
    %AgentTool{
      name: "end_intelligence",
      description:
        "End your intelligence gathering phase. Once all governors finish, the communication phase begins.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Intelligence",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_intelligence(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending intelligence phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Communication phase tools --

  defp communication_tools(world, actor_id) do
    players = get(world, :players, %{})
    other_governors = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))
    comm_sent = Map.get(get(world, :comm_sent_this_round, %{}), actor_id, 0)

    tools =
      if comm_sent < @comm_quota and length(other_governors) > 0 do
        [
          share_data_tool(actor_id, other_governors),
          request_help_tool(actor_id, other_governors)
        ]
      else
        []
      end

    tools ++ [end_communication_tool(actor_id)]
  end

  defp share_data_tool(actor_id, other_governors) do
    recipient_enum = Enum.map(other_governors, &%{"const" => &1})

    %AgentTool{
      name: "share_data",
      description:
        "Share regional intelligence data with another governor. " <>
          "You may share accurate or misleading data. " <>
          "#{@comm_quota} messages per round total. " <>
          "Recipients: #{Enum.join(other_governors, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to_id" => %{
            "type" => "string",
            "description" => "Governor to send data to",
            "anyOf" => recipient_enum
          },
          "data" => %{
            "type" => "object",
            "description" =>
              "Data payload to share (e.g. infection estimates, resource needs, coordinates)"
          }
        },
        "required" => ["to_id", "data"],
        "additionalProperties" => false
      },
      label: "Share Data",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        to_id = Map.get(params, "to_id", Map.get(params, :to_id))
        data = Map.get(params, "data", Map.get(params, :data, %{}))
        event = Events.share_data(actor_id, to_id, data)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("shared data with #{to_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp request_help_tool(actor_id, other_governors) do
    recipient_enum = Enum.map(other_governors, &%{"const" => &1})

    %AgentTool{
      name: "request_help",
      description:
        "Send a help request to another governor asking for resource donations or coordination.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to_id" => %{
            "type" => "string",
            "description" => "Governor to request help from",
            "anyOf" => recipient_enum
          },
          "message" => %{
            "type" => "string",
            "description" => "Your help request message"
          }
        },
        "required" => ["to_id", "message"],
        "additionalProperties" => false
      },
      label: "Request Help",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        to_id = Map.get(params, "to_id", Map.get(params, :to_id))
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.request_help(actor_id, to_id, message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sent help request to #{to_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_communication_tool(actor_id) do
    %AgentTool{
      name: "end_communication",
      description:
        "End your communication phase. Once all governors finish, resource allocation begins.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Communication",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_communication(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending communication for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Resource allocation phase tools --

  defp allocation_tools(world, actor_id) do
    allocations = get(world, :allocations, %{})
    already_allocated = Map.has_key?(allocations, actor_id)
    players = get(world, :players, %{})
    other_governors = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))

    tools =
      if already_allocated do
        []
      else
        [request_resources_tool(actor_id, world)]
      end

    tools =
      tools ++ [donate_resources_tool(actor_id, other_governors)]

    tools ++ [end_resource_allocation_tool(actor_id)]
  end

  defp request_resources_tool(actor_id, world) do
    pool = get(world, :resource_pool, %{})
    pool_vaccines = Map.get(pool, :vaccines, 0)
    pool_funding = Map.get(pool, :funding, 0)
    pool_teams = Map.get(pool, :medical_teams, 0)

    %AgentTool{
      name: "request_resources",
      description:
        "Request resources from the shared pool. You may only do this once per round. " <>
          "Pool has: #{pool_vaccines} vaccines, #{pool_funding} funding, #{pool_teams} medical teams.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "vaccines" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Number of vaccines to request from pool"
          },
          "funding" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Funding units to request from pool"
          },
          "medical_teams" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Medical teams to request from pool"
          }
        },
        "required" => ["vaccines", "funding", "medical_teams"],
        "additionalProperties" => false
      },
      label: "Request Resources",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        vaccines = Map.get(params, "vaccines", Map.get(params, :vaccines, 0))
        funding = Map.get(params, "funding", Map.get(params, :funding, 0))
        medical_teams = Map.get(params, "medical_teams", Map.get(params, :medical_teams, 0))
        event = Events.request_resources(actor_id, vaccines, funding, medical_teams)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "requested #{vaccines} vaccines, #{funding} funding, #{medical_teams} teams"
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp donate_resources_tool(actor_id, other_governors) do
    targets = ["pool" | other_governors]
    target_enum = Enum.map(targets, &%{"const" => &1})

    %AgentTool{
      name: "donate_resources",
      description:
        "Donate resources to the shared pool or directly to another governor. " <>
          "Donate to 'pool' to replenish shared reserves. " <>
          "Recipients: #{Enum.join(targets, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to_id" => %{
            "type" => "string",
            "description" => "Recipient: 'pool' or a governor_id",
            "anyOf" => target_enum
          },
          "vaccines" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Vaccines to donate"
          },
          "funding" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Funding to donate"
          },
          "medical_teams" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Medical teams to donate"
          }
        },
        "required" => ["to_id", "vaccines", "funding", "medical_teams"],
        "additionalProperties" => false
      },
      label: "Donate Resources",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        to_id = Map.get(params, "to_id", Map.get(params, :to_id, "pool"))
        vaccines = Map.get(params, "vaccines", Map.get(params, :vaccines, 0))
        funding = Map.get(params, "funding", Map.get(params, :funding, 0))
        medical_teams = Map.get(params, "medical_teams", Map.get(params, :medical_teams, 0))
        event = Events.donate_resources(actor_id, to_id, vaccines, funding, medical_teams)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("donated resources to #{to_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_resource_allocation_tool(actor_id) do
    %AgentTool{
      name: "end_resource_allocation",
      description:
        "End your resource allocation turn. Once all governors finish, local action begins.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Allocation",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_resource_allocation(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending resource allocation for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Local action phase tools --

  defp local_action_tools(world, actor_id) do
    players = get(world, :players, %{})
    player = Map.get(players, actor_id, %{})
    region_id = Map.get(player, :region, actor_id)
    resources = Map.get(player, :resources, %{})
    vaccines = Map.get(resources, :vaccines, 0)
    funding = Map.get(resources, :funding, 0)
    medical_teams = Map.get(resources, :medical_teams, 0)

    tools = []

    tools =
      if vaccines > 0 do
        tools ++ [vaccinate_tool(actor_id, vaccines)]
      else
        tools
      end

    tools =
      if medical_teams >= 1 do
        tools ++ [quarantine_zone_tool(actor_id, region_id)]
      else
        tools
      end

    tools =
      if funding >= 3 do
        tools ++ [build_hospital_tool(actor_id)]
      else
        tools
      end

    tools =
      if funding > 0 do
        tools ++ [fund_research_tool(actor_id, funding)]
      else
        tools
      end

    # Hoard supplies is always available (though discouraged)
    pool = get(world, :resource_pool, %{})
    pool_vaccines = Map.get(pool, :vaccines, 0)
    pool_teams = Map.get(pool, :medical_teams, 0)

    tools =
      if pool_vaccines > 0 or pool_teams > 0 do
        tools ++ [hoard_supplies_tool(actor_id, pool_vaccines, pool_teams)]
      else
        tools
      end

    tools ++ [end_local_action_tool(actor_id)]
  end

  defp vaccinate_tool(actor_id, available_vaccines) do
    %AgentTool{
      name: "vaccinate",
      description:
        "Deploy vaccines in your region to protect susceptible population. " <>
          "You have #{available_vaccines} vaccines available.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "count" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => available_vaccines,
            "description" => "Number of vaccines to deploy"
          }
        },
        "required" => ["count"],
        "additionalProperties" => false
      },
      label: "Vaccinate",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        count = Map.get(params, "count", Map.get(params, :count, 0))
        event = Events.vaccinate(actor_id, count)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("deploying #{count} vaccines")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp quarantine_zone_tool(actor_id, region_id) do
    %AgentTool{
      name: "quarantine_zone",
      description:
        "Quarantine your region (#{region_id}) to drastically reduce disease spread. " <>
          "Costs 1 medical team. Greatly reduces incoming and outgoing transmission.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "region_id" => %{
            "type" => "string",
            "const" => region_id,
            "description" => "Your region to quarantine"
          }
        },
        "required" => ["region_id"],
        "additionalProperties" => false
      },
      label: "Quarantine Zone",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        rid = Map.get(params, "region_id", Map.get(params, :region_id, region_id))
        event = Events.quarantine_zone(actor_id, rid)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("quarantining #{rid}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp build_hospital_tool(actor_id) do
    %AgentTool{
      name: "build_hospital",
      description:
        "Build a hospital in your region. Costs 3 funding. " <>
          "Increases treatment capacity and reduces mortality rate.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Build Hospital",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.build_hospital(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("building hospital")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp fund_research_tool(actor_id, available_funding) do
    %AgentTool{
      name: "fund_research",
      description:
        "Contribute funding to global disease research. " <>
          "Each unit reduces disease spread rate by 0.5%. " <>
          "You have #{available_funding} funding available.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "funding" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => available_funding,
            "description" => "Funding units to invest in research"
          }
        },
        "required" => ["funding"],
        "additionalProperties" => false
      },
      label: "Fund Research",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        funding = Map.get(params, "funding", Map.get(params, :funding, 0))
        event = Events.fund_research(actor_id, funding)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("investing #{funding} in research")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp hoard_supplies_tool(actor_id, pool_vaccines, pool_teams) do
    %AgentTool{
      name: "hoard_supplies",
      description:
        "Take resources from the shared pool for your own region only. " <>
          "WARNING: This is recorded as a hoarding incident. " <>
          "Pool has: #{pool_vaccines} vaccines, #{pool_teams} medical teams.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "vaccines" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => pool_vaccines,
            "description" => "Vaccines to take from pool"
          },
          "medical_teams" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => pool_teams,
            "description" => "Medical teams to take from pool"
          }
        },
        "required" => ["vaccines", "medical_teams"],
        "additionalProperties" => false
      },
      label: "Hoard Supplies",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        vaccines = Map.get(params, "vaccines", Map.get(params, :vaccines, 0))
        medical_teams = Map.get(params, "medical_teams", Map.get(params, :medical_teams, 0))
        event = Events.hoard_supplies(actor_id, vaccines, medical_teams)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "hoarding #{vaccines} vaccines, #{medical_teams} teams from pool (incident logged)"
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_local_action_tool(actor_id) do
    %AgentTool{
      name: "end_turn",
      description:
        "End your local action turn. Once all governors finish, disease spreads and a new round begins.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Turn",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_local_action(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending local action turn for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
