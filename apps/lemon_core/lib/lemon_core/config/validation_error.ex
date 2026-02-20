defmodule LemonCore.Config.ValidationError do
  @moduledoc """
  Exception raised when configuration validation fails.

  Contains the list of validation errors for debugging and user feedback.

  ## Example

      try do
        config = LemonCore.Config.Modular.load!()
      rescue
        e in LemonCore.Config.ValidationError ->
          IO.puts("Config errors:")
          Enum.each(e.errors, &IO.puts/1)
      end
  """

  defexception [:message, :errors]

  @impl true
  def exception(opts) do
    errors = Keyword.get(opts, :errors, [])
    message = Keyword.get(opts, :message, "Configuration validation failed")

    full_message = """
    #{message}

    Errors:
    #{Enum.map_join(errors, "\n", &"  - #{&1}")}
    """

    %__MODULE__{
      message: full_message,
      errors: errors
    }
  end
end
