defmodule LemonControlPlane.Lifecycle do
  @moduledoc "Runtime lifecycle availability shared by status and admin methods."

  def availability do
    managed? = launcher() != nil

    %{
      "restart" => managed?,
      "stop" => true,
      "reason" =>
        if(managed?,
          do: nil,
          else: "Restart requires a launcher-managed runtime (LEMON_LAUNCHER)."
        )
    }
  end

  @doc false
  def launcher do
    case System.get_env("LEMON_LAUNCHER") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end
end
