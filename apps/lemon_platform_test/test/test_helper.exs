# The self-validation suites run the kit against the platform's own
# implementations, so the three applications whose registries they round-trip
# through have to be up: channels (plugin registry), gateway (engine registry)
# and memory (provider registry).
Application.put_env(:lemon_gateway, :web_port, 0)
Application.put_env(:lemon_gateway, :health_enabled, false)

{:ok, _} = Application.ensure_all_started(:lemon_gateway)
{:ok, _} = Application.ensure_all_started(:lemon_channels)
{:ok, _} = Application.ensure_all_started(:lemon_memory)

ExUnit.start()
