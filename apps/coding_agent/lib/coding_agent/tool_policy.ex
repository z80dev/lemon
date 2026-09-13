defmodule CodingAgent.ToolPolicy do
  @moduledoc """
  Compatibility facade for Lemon's canonical validated tool policy.

  The policy type and validation semantics live in `LemonCore.ToolPolicy` so
  router, gateway, direct-session, delegated, and named-node entry points share
  one fail-closed authorization contract.
  """

  @type approval_mode :: LemonCore.ToolPolicy.approval_mode()
  @type profile :: LemonCore.ToolPolicy.profile()
  @type policy :: LemonCore.ToolPolicy.t()

  defdelegate from_profile(profile), to: LemonCore.ToolPolicy
  defdelegate fetch_profile(profile), to: LemonCore.ToolPolicy
  defdelegate custom(), to: LemonCore.ToolPolicy
  defdelegate custom(opts), to: LemonCore.ToolPolicy
  defdelegate parse(policy), to: LemonCore.ToolPolicy
  defdelegate parse!(policy), to: LemonCore.ToolPolicy
  defdelegate validated?(policy), to: LemonCore.ToolPolicy
  defdelegate resolve(policy, default), to: LemonCore.ToolPolicy
  defdelegate restrict(parent, requested), to: LemonCore.ToolPolicy
  defdelegate deny_all(), to: LemonCore.ToolPolicy
  defdelegate allowed?(policy, tool_name), to: LemonCore.ToolPolicy
  defdelegate requires_approval?(policy, tool_name), to: LemonCore.ToolPolicy
  defdelegate approval_mode(policy, tool_name), to: LemonCore.ToolPolicy
  defdelegate no_reply?(policy), to: LemonCore.ToolPolicy
  defdelegate denial_reason(policy, tool_name), to: LemonCore.ToolPolicy
  defdelegate apply_policy(policy, tools), to: LemonCore.ToolPolicy
  defdelegate partition_tools(policy, tools), to: LemonCore.ToolPolicy
  defdelegate apply_policy_to_map(policy, tools_map), to: LemonCore.ToolPolicy
  defdelegate to_map(policy), to: LemonCore.ToolPolicy
  defdelegate from_map(map), to: LemonCore.ToolPolicy
  defdelegate mark_no_reply(message), to: LemonCore.ToolPolicy
  defdelegate mark_no_reply(message, opts), to: LemonCore.ToolPolicy
  defdelegate message_no_reply?(message), to: LemonCore.ToolPolicy
  defdelegate filter_no_reply(messages), to: LemonCore.ToolPolicy
end
