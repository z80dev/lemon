defmodule LemonWeb.Layouts do
  @moduledoc """
  Root document and the authenticated app shell (navigation rail, mobile top
  bar, reconnect banner, toasts).
  """

  use LemonWeb, :html

  embed_templates("layouts/*")

  @doc false
  def open_rail(js \\ %JS{}) do
    js
    |> JS.set_attribute({"data-open", "true"}, to: "#rail")
    |> JS.set_attribute({"role", "dialog"}, to: "#rail")
    |> JS.set_attribute({"aria-modal", "true"}, to: "#rail")
    |> JS.show(to: "#rail-backdrop")
    |> JS.focus_first(to: "#rail")
  end

  @doc false
  def close_rail(js \\ %JS{}) do
    js
    |> JS.set_attribute({"data-open", "false"}, to: "#rail")
    |> JS.remove_attribute("role", to: "#rail")
    |> JS.remove_attribute("aria-modal", to: "#rail")
    |> JS.hide(to: "#rail-backdrop")
  end
end
