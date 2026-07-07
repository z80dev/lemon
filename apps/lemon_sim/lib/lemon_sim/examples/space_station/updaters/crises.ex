defmodule LemonSim.Examples.SpaceStation.Updaters.Crises do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  @crisis_types [:cascade_failure, :power_surge, :lockdown, :hull_breach]

  # -- Crisis generation and effects --

  def generate_crisis(round, world) do
    systems = get(world, :systems, %{})
    system_ids = Map.keys(systems) |> Enum.map(&to_string/1)

    # Pick a crisis type, cycling through to avoid repeats
    crisis_type = Enum.at(@crisis_types, rem(round, length(@crisis_types)))

    case crisis_type do
      :cascade_failure ->
        [sys_a, sys_b] = system_ids |> Enum.shuffle() |> Enum.take(2)
        name_a = system_display_name(sys_a)
        name_b = system_display_name(sys_b)

        %{
          type: "cascade_failure",
          name: "Cascade Failure",
          linked_systems: [sys_a, sys_b],
          threshold: 40,
          extra_damage: 12,
          description:
            "WARNING: #{name_a} and #{name_b} systems are linked through a shared conduit. " <>
              "If either drops below 40 health, the other takes 12 extra damage!",
          announcement:
            "CRISIS ALERT: Cascade failure detected! #{name_a} and #{name_b} are linked — " <>
              "if either drops below 40 HP, the other takes 12 damage."
        }

      :power_surge ->
        [victim, beneficiary] = system_ids |> Enum.shuffle() |> Enum.take(2)
        victim_name = system_display_name(victim)
        beneficiary_name = system_display_name(beneficiary)
        surge_damage = Enum.random(15..25)
        surge_repair = Enum.random(10..15)

        %{
          type: "power_surge",
          name: "Power Surge",
          victim_system: victim,
          beneficiary_system: beneficiary,
          surge_damage: surge_damage,
          surge_repair: surge_repair,
          description:
            "A power surge is routing energy away from #{victim_name} (-#{surge_damage} HP) " <>
              "and overcharging #{beneficiary_name} (+#{surge_repair} HP). " <>
              "Prioritize repairing #{victim_name} this round!",
          announcement:
            "CRISIS ALERT: Power surge! #{victim_name} takes #{surge_damage} damage, " <>
              "#{beneficiary_name} gains #{surge_repair} health."
        }

      :lockdown ->
        %{
          type: "lockdown",
          name: "Security Lockdown",
          description:
            "Station security lockdown activated! All crew locations will be revealed at the end of this round. " <>
              "Everyone can see where everyone went.",
          announcement:
            "CRISIS ALERT: Security lockdown! All player locations will be revealed this round."
        }

      :hull_breach ->
        [sys_a, sys_b] = system_ids |> Enum.shuffle() |> Enum.take(2)
        name_a = system_display_name(sys_a)
        name_b = system_display_name(sys_b)
        breach_damage = 20

        %{
          type: "hull_breach",
          name: "Hull Breach",
          affected_systems: [sys_a, sys_b],
          breach_damage: breach_damage,
          description:
            "Hull breach detected near #{name_a} and #{name_b}! " <>
              "Both systems take #{breach_damage} extra damage unless someone repairs them this round. " <>
              "Any system that receives a repair this round is spared the breach damage.",
          announcement:
            "CRISIS ALERT: Hull breach! #{name_a} and #{name_b} take #{breach_damage} damage " <>
              "unless repaired this round."
        }
    end
  end

  def apply_crisis_effects(systems, world) do
    crisis = get(world, :active_crisis)
    action_log = get(world, :action_log, %{})

    if is_nil(crisis) do
      systems
    else
      case get(crisis, :type) do
        "cascade_failure" ->
          [sys_a, sys_b] = get(crisis, :linked_systems, [])
          threshold = get(crisis, :threshold, 40)
          extra_damage = get(crisis, :extra_damage, 12)

          health_a = get(Map.get(systems, sys_a, %{}), :health, 100)
          health_b = get(Map.get(systems, sys_b, %{}), :health, 100)

          systems =
            if health_a < threshold do
              apply_system_change(systems, sys_b, -extra_damage)
            else
              systems
            end

          if health_b < threshold do
            apply_system_change(systems, sys_a, -extra_damage)
          else
            systems
          end

        "power_surge" ->
          victim = get(crisis, :victim_system)
          beneficiary = get(crisis, :beneficiary_system)
          damage = get(crisis, :surge_damage, 20)
          repair = get(crisis, :surge_repair, 12)

          systems
          |> apply_system_change(victim, -damage)
          |> apply_system_change(beneficiary, repair)

        "hull_breach" ->
          affected = get(crisis, :affected_systems, [])
          breach_damage = get(crisis, :breach_damage, 20)

          # Systems that received a repair this round are spared
          repaired_systems =
            action_log
            |> Enum.filter(fn {_pid, entry} -> get_action_field(entry, :action) == "repair" end)
            |> Enum.map(fn {_pid, entry} -> get_action_field(entry, :system) end)
            |> MapSet.new()

          Enum.reduce(affected, systems, fn sys_id, acc ->
            if MapSet.member?(repaired_systems, sys_id) do
              acc
            else
              apply_system_change(acc, sys_id, -breach_damage)
            end
          end)

        # Lockdown has no system effect — it's handled in the projector
        _ ->
          systems
      end
    end
  end
end
