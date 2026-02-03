defmodule LemonGateway.Command do
  @moduledoc """
  Behaviour for slash command plugins.

  Commands are invoked when a user sends a message starting with `/command_name`.
  They execute synchronously and can return an immediate reply or perform
  background actions.

  ## Usage

      defmodule MyCommand do
        use LemonGateway.Command

        @impl true
        def name, do: "mycommand"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def handle(scope, args, context) do
          {:reply, "You said: \#{args}"}
        end
      end
  """

  alias LemonGateway.Types.ChatScope

  @type context :: %{
          optional(:message) => map(),
          optional(:reply_to_message) => map(),
          optional(:transport_meta) => map()
        }

  @type result :: :ok | {:reply, String.t()} | {:error, String.t()}

  @doc """
  Returns the command name (without the leading slash).

  Must be a lowercase string matching `^[a-z][a-z0-9_]*$`.
  """
  @callback name() :: String.t()

  @doc """
  Returns a short description of the command for help text.
  """
  @callback description() :: String.t()

  @doc """
  Handles the command invocation.

  - `scope` - The chat scope where the command was issued
  - `args` - The arguments string after the command name (may be empty)
  - `context` - Additional context including the original message

  Returns:
  - `:ok` - Command executed, no reply needed
  - `{:reply, text}` - Send text as a reply
  - `{:error, reason}` - Command failed with error message
  """
  @callback handle(scope :: ChatScope.t(), args :: String.t(), context :: context()) :: result()

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonGateway.Command
    end
  end
end
