defmodule CodingAgent.UI.Headless do
  @moduledoc """
  Headless UI implementation for print and RPC modes.

  In print mode: All methods are no-ops returning defaults.
  In RPC mode: Dialog methods send JSON requests and wait for responses.

  This implementation provides sensible defaults for non-interactive environments:
  - Dialog methods (select, confirm, input, editor) return nil/false
  - Status/widget methods are no-ops
  - notify logs to console with appropriate formatting
  - has_ui?() returns false
  """

  @behaviour CodingAgent.UI

  require Logger

  # Dialog methods

  @impl CodingAgent.UI
  def select(_title, _options, _opts \\ []) do
    {:ok, nil}
  end

  @impl CodingAgent.UI
  def confirm(_title, _message, _opts \\ []) do
    {:ok, false}
  end

  @impl CodingAgent.UI
  def input(_title, _placeholder \\ nil, _opts \\ []) do
    {:ok, nil}
  end

  @impl CodingAgent.UI
  def notify(message, type) do
    case type do
      :info -> Logger.info(message)
      :warning -> Logger.warning(message)
      :error -> Logger.error(message)
      :success -> Logger.info("[SUCCESS] #{message}")
    end

    :ok
  end

  # Status/widget methods

  @impl CodingAgent.UI
  def set_status(_key, _text) do
    :ok
  end

  @impl CodingAgent.UI
  def set_widget(_key, _content, _opts \\ []) do
    :ok
  end

  @impl CodingAgent.UI
  def set_working_message(nil) do
    :ok
  end

  def set_working_message(message) do
    Logger.debug("[WORKING] #{message}")
    :ok
  end

  # Layout methods

  @impl CodingAgent.UI
  def set_title(_title) do
    :ok
  end

  # Editor methods

  @impl CodingAgent.UI
  def set_editor_text(_text) do
    :ok
  end

  @impl CodingAgent.UI
  def get_editor_text do
    ""
  end

  @impl CodingAgent.UI
  def editor(_title, _prefill \\ nil, _opts \\ []) do
    {:ok, nil}
  end

  # Capability check

  @impl CodingAgent.UI
  def has_ui? do
    false
  end
end
