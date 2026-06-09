defmodule LemonSim.GameHelpers.UpdaterHelpers do
  @moduledoc false

  defdelegate ensure_in_progress(world), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_phase(world, expected_phase), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_phase_in(world, phases), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_active_actor(world, player_id), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_living(players, player_id), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_role(players, player_id, expected_role), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_not_role(players, player_id, forbidden_role), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_different(id_a, id_b), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate ensure_valid_vote_target(players, voter_id, target_id),
    to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate next_in_order(turn_order, current_id), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate world_updates(world, updates), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate reject_action(state, event, player_id, reason), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate rejection_reason(reason), to: LemonSim.Examples.Helpers.UpdaterHelpers
  defdelegate maybe_store_thought(state, event), to: LemonSim.Examples.Helpers.UpdaterHelpers
end
