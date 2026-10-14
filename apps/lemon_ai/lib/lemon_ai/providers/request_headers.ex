defmodule LemonAi.Providers.RequestHeaders do
  @moduledoc false

  # The accumulator has normalized names. Apply each later layer in place so
  # mixed-case names replace, rather than duplicate, earlier HTTP headers.
  @spec merge(map(), map() | list() | nil) :: map()
  def merge(headers, nil), do: headers
  def merge(headers, extra) when extra == %{} or extra == [], do: headers

  def merge(headers, extra) do
    Enum.reduce(extra, headers, fn {name, value}, acc ->
      put(acc, name, value)
    end)
  end

  @spec put(map(), String.t() | atom(), term()) :: map()
  def put(headers, name, value) do
    Map.put(headers, name |> to_string() |> String.downcase(), to_string(value))
  end
end
