defmodule LemonWeb do
  @moduledoc """
  Entry point for web interface definitions.
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: LemonWeb.Layouts]

      use Gettext, backend: LemonWeb.Gettext

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {LemonWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: LemonWeb.Gettext

      import Phoenix.HTML
      import LemonWeb.CoreComponents

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: LemonWeb.Endpoint,
        router: LemonWeb.Router,
        statics: LemonWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
