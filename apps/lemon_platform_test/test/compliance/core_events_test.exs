defmodule LemonPlatformTest.Compliance.CoreEventsTest do
  @moduledoc """
  Runs the events contract suite against the platform's own `LemonCore.Events` registry.

  This is the self-validation pass: if the kit's assertions do not hold for the payloads
  Lemon itself publishes, they cannot be held against anyone else's.
  """

  use LemonPlatformTest.EventsCase
end
