# By default, exclude integration tests that require external CLIs/services.
ExUnit.configure(exclude: [:integration])
ExUnit.start()
