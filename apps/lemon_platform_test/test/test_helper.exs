# The self-validation suites run the kit against the platform's own
# implementations, so the two applications whose registries they round-trip
# through have to be up: channels (plugin registry) and memory (provider
# registry).
{:ok, _} = Application.ensure_all_started(:lemon_channels)
{:ok, _} = Application.ensure_all_started(:lemon_memory)

ExUnit.start()
