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

_ = Application.stop(:lemon_channels)
_ = Application.stop(:coding_agent)
_ = Application.stop(:lemon_router)

{:ok, _} = Application.ensure_all_started(:lemon_router)
{:ok, _} = Application.ensure_all_started(:coding_agent)

ExUnit.start()

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:coding_agent)
  _ = Application.stop(:lemon_router)

  Application.delete_env(:lemon_channels, :telegram)
  Application.delete_env(:lemon_router, LemonRouter.RoutingFeedbackStore)
  File.rm_rf!(routing_feedback_path)

  {:ok, _} = Application.ensure_all_started(:lemon_channels)
  {:ok, _} = Application.ensure_all_started(:coding_agent)
end)
