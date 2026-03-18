defmodule LemonSimUi.Layouts do
  @moduledoc "Root and app layout templates for the LemonSim UI."

  use LemonSimUi, :html
  embed_templates "layouts/*"
end
