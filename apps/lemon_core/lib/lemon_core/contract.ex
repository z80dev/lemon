defmodule LemonCore.Contract do
  @moduledoc """
  Checks that a configured module implements a behaviour before the platform
  starts calling it.

  The seams between umbrella apps are composed in configuration: the router
  names its engine runtime, the control plane registers itself as the event
  fan-out, channels are handed the router through `LemonCore.RouterBridge`.
  Each of those seams verifies its implementation once, here, at configure
  time. A module that is not loadable or that lacks a required callback is
  rejected with a reason, so call sites can call the implementation directly
  instead of guarding every call with `function_exported?/3` and falling back
  to a silent no-op when the guard fails.

  Optional callbacks declared with `@optional_callbacks` are not required.
  """

  @type callback :: {atom(), arity()}
  @type error ::
          {:not_a_module, term()}
          | {:not_loadable, module()}
          | {:missing_callbacks, module(), [callback()]}

  @doc """
  Validates that `module` is loadable and exports every required callback of
  `behaviour`.
  """
  @spec validate(term(), module()) :: :ok | {:error, error()}
  def validate(module, behaviour)
      when is_atom(module) and not is_nil(module) and is_atom(behaviour) do
    with :ok <- loadable(module) do
      missing =
        Enum.reject(required_callbacks(behaviour), fn {function, arity} ->
          function_exported?(module, function, arity)
        end)

      case missing do
        [] -> :ok
        missing -> {:error, {:missing_callbacks, module, missing}}
      end
    end
  end

  def validate(other, _behaviour), do: {:error, {:not_a_module, other}}

  @doc "Every callback of `behaviour` that an implementation must export."
  @spec required_callbacks(module()) :: [callback()]
  def required_callbacks(behaviour) when is_atom(behaviour) do
    behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)
  end

  defp loadable(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, _reason} -> {:error, {:not_loadable, module}}
    end
  end
end
