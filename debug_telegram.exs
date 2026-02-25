# Debug script for Telegram message flow
IO.puts("\n=== TELEGRAM DEBUG ===\n")

# 1. Check if Telegram transport is running
IO.puts("1. Checking Telegram Transport process...")
case Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
  nil -> IO.puts("   ❌ Telegram Transport NOT RUNNING")
  pid ->
    IO.puts("   ✅ Telegram Transport running: #{inspect(pid)}")

    try do
      st = :sys.get_state(pid)

      IO.puts("   account_id: #{inspect(st.account_id)}")
      IO.puts("   offset: #{inspect(st.offset)}")
      IO.puts("   poll_interval_ms: #{inspect(st.poll_interval_ms)}")
      IO.puts("   debounce_ms: #{inspect(st.debounce_ms)}")
      IO.puts("   allowed_chat_ids: #{inspect(st.allowed_chat_ids)}")
      IO.puts("   deny_unbound_chats: #{inspect(st.deny_unbound_chats)}")
      IO.puts("   drop_pending_updates?: #{inspect(st.drop_pending_updates?)}")
      IO.puts("   drop_pending_done?: #{inspect(st.drop_pending_done?)}")
      IO.puts("   last_poll_error: #{inspect(st.last_poll_error)}")
      IO.puts("   debug_inbound: #{inspect(Map.get(st, :debug_inbound))}")
      IO.puts("   log_drops: #{inspect(Map.get(st, :log_drops))}")
    rescue
      e -> IO.puts("   Could not read transport state: #{inspect(e)}")
    end
end

# 2. Check Telegram Supervisor
IO.puts("\n2. Checking Telegram Supervisor...")
case Process.whereis(LemonChannels.Adapters.Telegram.Supervisor) do
  nil -> IO.puts("   ❌ Telegram Supervisor NOT RUNNING")
  pid ->
    IO.puts("   ✅ Telegram Supervisor running: #{inspect(pid)}")
    children = Supervisor.which_children(pid)
    IO.puts("   Children: #{inspect(children)}")
end

# 3. Check Registry for Telegram plugin
IO.puts("\n3. Checking Plugin Registry...")
try do
  plugins = LemonChannels.Registry.list_plugins()
  IO.puts("   Registered plugins: #{inspect(plugins)}")
rescue
  e -> IO.puts("   Error checking registry: #{inspect(e)}")
end

# 4. Check Outbox
IO.puts("\n4. Checking Outbox...")
case Process.whereis(LemonChannels.Outbox) do
  nil -> IO.puts("   ❌ Outbox NOT RUNNING")
  pid -> IO.puts("   ✅ Outbox running: #{inspect(pid)}")
end

# 4b. Check legacy Telegram outbox (used for delete/edit coalescing)
IO.puts("\n4b. Checking LemonGateway.Telegram.Outbox...")
case Process.whereis(LemonGateway.Telegram.Outbox) do
  nil -> IO.puts("   ℹ️  LemonGateway.Telegram.Outbox NOT RUNNING")
  pid -> IO.puts("   ✅ LemonGateway.Telegram.Outbox running: #{inspect(pid)}")
end

# 5. Check RunOrchestrator/DynamicSupervisor
IO.puts("\n5. Checking Run infrastructure...")
case Process.whereis(LemonRouter.RunSupervisor) do
  nil -> IO.puts("   ❌ RunSupervisor NOT RUNNING")
  pid ->
    IO.puts("   ✅ RunSupervisor running: #{inspect(pid)}")
    children = DynamicSupervisor.which_children(pid)
    IO.puts("   Active runs: #{length(children)}")
end

# 6. Check StreamCoalescer registry
IO.puts("\n6. Checking StreamCoalescer...")
case Process.whereis(LemonRouter.CoalescerRegistry) do
  nil -> IO.puts("   ❌ CoalescerRegistry NOT RUNNING")
  pid -> IO.puts("   ✅ CoalescerRegistry running: #{inspect(pid)}")
end

# 7. Check EventBridge
IO.puts("\n7. Checking EventBridge...")
case Process.whereis(LemonControlPlane.EventBridge) do
  nil -> IO.puts("   ❌ EventBridge NOT RUNNING")
  pid -> IO.puts("   ✅ EventBridge running: #{inspect(pid)}")
end

# 8. Check LemonGateway Store for agent config
IO.puts("\n8. Checking LemonGateway Store...")
case Process.whereis(LemonCore.Store) do
  nil -> IO.puts("   ❌ LemonCore.Store NOT RUNNING")
  pid ->
    IO.puts("   ✅ LemonCore.Store running: #{inspect(pid)}")
    # Try to list stored items
    try do
      agents = LemonCore.Store.list(:agents)
      IO.puts("   Stored agents: #{inspect(Map.keys(agents))}")
    rescue
      e -> IO.puts("   Could not list agents: #{inspect(e)}")
    end
end

# 8b. Check RouterBridge wiring
IO.puts("\n8b. Checking LemonCore.RouterBridge config...")
try do
  cfg = Application.get_env(:lemon_core, :router_bridge, %{})
  IO.puts("   router_bridge env: #{inspect(cfg)}")
rescue
  e -> IO.puts("   Could not read router_bridge env: #{inspect(e)}")
end

# 9. Check for any ETS tables
IO.puts("\n9. Checking ETS tables...")
tables = :ets.all() |> Enum.filter(fn t ->
  name = :ets.info(t, :name)
  name_str = to_string(name)
  String.contains?(name_str, "telegram") or
  String.contains?(name_str, "Telegram") or
  String.contains?(name_str, "lemon") or
  String.contains?(name_str, "Lemon")
end)
IO.puts("   Relevant ETS tables: #{inspect(tables)}")

IO.puts("\n=== END DEBUG ===\n")
