defmodule LemonGateway.Event do
  @moduledoc false

  @type phase :: :started | :updated | :completed

  defmodule Started do
    @moduledoc false
    @enforce_keys [:engine, :resume]
    defstruct [:engine, :resume, :title, :meta]
  end

  defmodule Action do
    @moduledoc false
    @enforce_keys [:id, :kind, :title]
    defstruct [:id, :kind, :title, :detail]
  end

  defmodule ActionEvent do
    @moduledoc false
    @enforce_keys [:engine, :action, :phase]
    defstruct [:engine, :action, :phase, :ok, :message, :level]
  end

  defmodule Completed do
    @moduledoc false
    @enforce_keys [:engine, :ok]
    defstruct [:engine, :resume, :ok, :answer, :error, :usage, :meta]
  end
end
