#
# In umbrella `mix test`, applications are not guaranteed to be started for each
# child app. LemonRouter tests expect Registries and core runtime services to be
# running. Establish a consistent baseline here.
#

Application.put_env(:lemon_channels, :telegram, %{
  bot_token: nil,
  allowed_chat_ids: nil,
  deny_unbound_chats: false,
  drop_pending_updates: false,
  files: %{}
})

routing_feedback_path =
  System.tmp_dir!()
  |> Path.join("lemon_router_test_routing_feedback_#{System.unique_integer([:positive])}")

File.rm_rf!(routing_feedback_path)
Application.put_env(:lemon_router, LemonRouter.RoutingFeedbackStore, path: routing_feedback_path)

# Stop dependents before what they depend on: lemon_router runs on coding_agent.
_ = Application.stop(:lemon_router)
_ = Application.stop(:coding_agent)
_ = Application.stop(:lemon_channels)

{:ok, _} = Application.ensure_all_started(:lemon_router)
{:ok, _} = Application.ensure_all_started(:coding_agent)

ExUnit.start(capture_log: true)

# An umbrella `mix test` runs every later app suite in this VM, and this
# callback runs after each of them too: restart everything it stops.
ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_router)
  _ = Application.stop(:coding_agent)
  _ = Application.stop(:lemon_channels)

  Application.delete_env(:lemon_channels, :telegram)
  Application.delete_env(:lemon_router, LemonRouter.RoutingFeedbackStore)
  File.rm_rf!(routing_feedback_path)

  {:ok, _} = Application.ensure_all_started(:lemon_channels)
  {:ok, _} = Application.ensure_all_started(:coding_agent)
  {:ok, _} = Application.ensure_all_started(:lemon_router)
end)
