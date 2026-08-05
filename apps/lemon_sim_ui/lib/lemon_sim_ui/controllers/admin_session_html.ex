defmodule LemonSimUi.AdminSessionHTML do
  @moduledoc "HTML views for the LemonSim operator authentication flow."

  use LemonSimUi, :html

  embed_templates("admin_session_html/*")
end
