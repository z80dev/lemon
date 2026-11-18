defmodule CodingAgent.ExtensionLifecycle.LoadError do
  @moduledoc """
  Raised when a configured extension fails to compile, load or validate at
  session start or reload. The session does not run with a partial extension
  set, since the missing extension may be the one enforcing policy.
  """

  defexception [:errors]

  @impl true
  def message(%__MODULE__{errors: errors}) do
    details =
      Enum.map_join(errors, "; ", fn error ->
        "#{Map.get(error, :source_path) || "unknown source"}: #{Map.get(error, :error_message)}"
      end)

    "configured extensions failed to load, refusing to start without them: " <> details
  end
end
