defmodule CodingAgent.UI.Context do
  @moduledoc """
  Context for UI operations, holds reference to the current UI implementation.

  This struct wraps a UI module and optional state, providing a convenient way
  to pass UI capabilities through the application. All UI calls are delegated
  through the context to the underlying module.

  ## Example

      # `CodingAgent.UI.Headless` is provided by the coding_agent_ui app
      ctx = CodingAgent.UI.Context.new(CodingAgent.UI.Headless)
      {:ok, selection} = CodingAgent.UI.Context.select(ctx, "Choose one", options)
  """

  defstruct [:module, :state]

  @type t :: %__MODULE__{
          module: module(),
          state: term()
        }

  @doc """
  Creates a new UI context with the given module and optional state.
  """
  @spec new(module(), term()) :: t()
  def new(module, state \\ nil) do
    %__MODULE__{module: module, state: state}
  end

  # Dialog methods

  @doc """
  Displays a selection dialog with the given options.
  """
  @spec select(t(), String.t(), [CodingAgent.UI.option()], keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def select(%__MODULE__{module: mod}, title, options, opts \\ []) do
    mod.select(title, options, opts)
  end

  @doc """
  Displays a confirmation dialog.
  """
  @spec confirm(t(), String.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def confirm(%__MODULE__{module: mod}, title, message, opts \\ []) do
    mod.confirm(title, message, opts)
  end

  @doc """
  Displays an input dialog for text entry.
  """
  @spec input(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def input(%__MODULE__{module: mod}, title, placeholder \\ nil, opts \\ []) do
    mod.input(title, placeholder, opts)
  end

  @doc """
  Displays a notification message.
  """
  @spec notify(t(), String.t(), CodingAgent.UI.notify_type()) :: :ok
  def notify(%__MODULE__{module: mod}, message, type) do
    mod.notify(message, type)
  end

  # Status/widget methods

  @doc """
  Sets a status value by key.
  """
  @spec set_status(t(), String.t(), String.t() | nil) :: :ok
  def set_status(%__MODULE__{module: mod}, key, text) do
    mod.set_status(key, text)
  end

  @doc """
  Sets widget content by key.
  """
  @spec set_widget(t(), String.t(), CodingAgent.UI.widget_content(), keyword()) :: :ok
  def set_widget(%__MODULE__{module: mod}, key, content, opts \\ []) do
    mod.set_widget(key, content, opts)
  end

  @doc """
  Sets the current working/progress message.
  """
  @spec set_working_message(t(), String.t() | nil) :: :ok
  def set_working_message(%__MODULE__{module: mod}, message) do
    mod.set_working_message(message)
  end

  # Layout methods

  @doc """
  Sets the UI title.
  """
  @spec set_title(t(), String.t()) :: :ok
  def set_title(%__MODULE__{module: mod}, title) do
    mod.set_title(title)
  end

  # Editor methods

  @doc """
  Sets the text content of the editor widget.
  """
  @spec set_editor_text(t(), String.t()) :: :ok
  def set_editor_text(%__MODULE__{module: mod}, text) do
    mod.set_editor_text(text)
  end

  @doc """
  Gets the current text content from the editor widget.
  """
  @spec get_editor_text(t()) :: String.t()
  def get_editor_text(%__MODULE__{module: mod}) do
    mod.get_editor_text()
  end

  @doc """
  Opens an editor dialog with optional prefilled content.
  """
  @spec editor(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def editor(%__MODULE__{module: mod}, title, prefill \\ nil, opts \\ []) do
    mod.editor(title, prefill, opts)
  end

  # Capability check

  @doc """
  Checks if the UI implementation has full interactive capabilities.
  """
  @spec has_ui?(t()) :: boolean()
  def has_ui?(%__MODULE__{module: mod}) do
    mod.has_ui?()
  end
end
