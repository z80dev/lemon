defmodule LemonCore.ConfigCacheError do
  @moduledoc """
  Exception raised when the ConfigCache is not available or encounters an error.

  This typically indicates that the lemon_core application has not been started
  or that there's an issue with the ETS table.

  ## Example

      try do
        config = LemonCore.ConfigCache.get()
      rescue
        e in LemonCore.ConfigCacheError ->
          IO.puts("ConfigCache error: \#{e.message}")
      end
  """

  defexception [:message]

  @impl true
  def exception(opts) do
    message = Keyword.get(opts, :message, "ConfigCache is not available")
    %__MODULE__{message: message}
  end
end
