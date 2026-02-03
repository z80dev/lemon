# By default, exclude integration tests that require external CLIs/services.
ExUnit.configure(exclude: [:integration])
ExUnit.start()

# Compile and load support files
Code.compile_file("support/mocks.ex", __DIR__)
