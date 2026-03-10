defmodule LemonSimUi.ConnCase do
  @moduledoc """
  Test case template for tests that require a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint LemonSimUi.Endpoint

      use LemonSimUi, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
