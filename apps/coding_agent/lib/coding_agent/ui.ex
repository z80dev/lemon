defmodule CodingAgent.UI do
  @moduledoc """
  Behaviour for UI abstraction in CodingAgent.

  Implementations live outside this app (see `apps/coding_agent_ui`), keeping
  the core UI-agnostic. Example implementations include:
  - `CodingAgent.UI.Headless` - No-op UI for headless runs
  - `CodingAgent.UI.RPC` - JSON stdin/stdout adapter
  """

  @type option :: %{label: String.t(), value: String.t(), description: String.t() | nil}
  @type notify_type :: :info | :warning | :error | :success
  @type widget_content :: String.t() | [String.t()] | nil

  # Dialog methods
  @callback select(title :: String.t(), options :: [option()], opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}
  @callback confirm(title :: String.t(), message :: String.t(), opts :: keyword()) ::
              {:ok, boolean()} | {:error, term()}
  @callback input(title :: String.t(), placeholder :: String.t() | nil, opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}
  @callback notify(message :: String.t(), type :: notify_type()) :: :ok

  # Status/widget methods
  @callback set_status(key :: String.t(), text :: String.t() | nil) :: :ok
  @callback set_widget(key :: String.t(), content :: widget_content(), opts :: keyword()) :: :ok
  @callback set_working_message(message :: String.t() | nil) :: :ok

  # Layout methods
  @callback set_title(title :: String.t()) :: :ok

  # Editor methods
  @callback set_editor_text(text :: String.t()) :: :ok
  @callback get_editor_text() :: String.t()
  @callback editor(title :: String.t(), prefill :: String.t() | nil, opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  # Convenience function to check if UI has full capabilities
  @callback has_ui?() :: boolean()
end
