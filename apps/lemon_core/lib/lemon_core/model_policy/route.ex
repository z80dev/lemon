defmodule LemonCore.ModelPolicy.Route do
  @moduledoc """
  Route key handling for model policies.

  Routes define the hierarchical path for model policy resolution:
  - `{channel_id, account_id, peer_id, thread_id}` - thread-level (most specific)
  - `{channel_id, account_id, peer_id, nil}` - peer-level (DM/chat)
  - `{channel_id, account_id, nil, nil}` - account-level
  - `{channel_id, nil, nil, nil}` - channel-type level

  ## Precedence (highest to lowest)

  1. Session override (temporary, per-request)
  2. Thread-level policy
  3. Peer-level policy
  4. Account-level policy
  5. Channel-type policy
  6. Global default

  ## Examples

      # Create a route for a Telegram chat thread
      route = Route.new("telegram", "default", "-1001234567890", "456")

      # Create a route for a Discord channel
      route = Route.new("discord", "bot1", "123456789012345678", nil)

      # Get route key for storage
      key = Route.to_key(route)
  """

  @typedoc "Channel identifier (e.g., 'telegram', 'discord')"
  @type channel_id :: String.t()

  @typedoc "Account identifier within a channel"
  @type account_id :: String.t() | nil

  @typedoc "Peer/chat/channel identifier"
  @type peer_id :: String.t() | nil

  @typedoc "Thread/topic identifier"
  @type thread_id :: String.t() | nil

  @typedoc "Route tuple for storage lookup"
  @type route_key ::
          {channel_id(), account_id(), peer_id(), thread_id()}
          | {channel_id(), account_id(), peer_id()}
          | {channel_id(), account_id()}
          | {channel_id()}

  @enforce_keys [:channel_id]
  defstruct [:channel_id, :account_id, :peer_id, :thread_id]

  @typedoc "Route struct representing a policy scope"
  @type t :: %__MODULE__{
          channel_id: channel_id(),
          account_id: account_id(),
          peer_id: peer_id(),
          thread_id: thread_id()
        }

  @doc """
  Creates a new route struct.

  ## Examples

      iex> Route.new("telegram", "default", "123", "456")
      %Route{channel_id: "telegram", account_id: "default", peer_id: "123", thread_id: "456"}

      iex> Route.new("discord")
      %Route{channel_id: "discord", account_id: nil, peer_id: nil, thread_id: nil}
  """
  @spec new(channel_id(), account_id(), peer_id(), thread_id()) :: t()
  def new(channel_id, account_id \\ nil, peer_id \\ nil, thread_id \\ nil) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: account_id,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end

  @doc """
  Converts a route struct to a storage key tuple.

  ## Examples

      iex> Route.new("telegram", "default", "123", "456") |> Route.to_key()
      {"telegram", "default", "123", "456"}
  """
  @spec to_key(t()) :: route_key()
  def to_key(%__MODULE__{} = route) do
    {route.channel_id, route.account_id, route.peer_id, route.thread_id}
  end

  @doc """
  Creates a route from a storage key tuple.

  ## Examples

      iex> Route.from_key({"telegram", "default", "123", "456"})
      %Route{channel_id: "telegram", account_id: "default", peer_id: "123", thread_id: "456"}
  """
  @spec from_key(route_key()) :: t()
  def from_key({channel_id, account_id, peer_id, thread_id}) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: account_id,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end

  def from_key({channel_id, account_id, peer_id}) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: account_id,
      peer_id: peer_id,
      thread_id: nil
    }
  end

  def from_key({channel_id, account_id}) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: account_id,
      peer_id: nil,
      thread_id: nil
    }
  end

  def from_key({channel_id}) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: nil,
      peer_id: nil,
      thread_id: nil
    }
  end

  @doc """
  Returns the precedence hierarchy for policy resolution.

  Given a route, returns a list of increasingly general route keys
  to check for policy matches.

  ## Examples

      iex> Route.new("telegram", "default", "123", "456") |> Route.precedence_keys()
      [
        {"telegram", "default", "123", "456"},
        {"telegram", "default", "123", nil},
        {"telegram", "default", nil, nil},
        {"telegram", nil, nil, nil}
      ]
  """
  @spec precedence_keys(t()) :: [route_key()]
  def precedence_keys(%__MODULE__{} = route) do
    base = {route.channel_id, route.account_id, route.peer_id, route.thread_id}

    keys = [base]

    keys =
      if route.thread_id != nil do
        [{route.channel_id, route.account_id, route.peer_id, nil} | keys]
      else
        keys
      end

    keys =
      if route.peer_id != nil do
        [{route.channel_id, route.account_id, nil, nil} | keys]
      else
        keys
      end

    keys =
      if route.account_id != nil do
        [{route.channel_id, nil, nil, nil} | keys]
      else
        keys
      end

    Enum.reverse(keys)
  end

  @doc """
  Creates a wildcard route that matches any account/peer/thread within a channel.

  ## Examples

      iex> Route.channel_wide("telegram")
      %Route{channel_id: "telegram", account_id: nil, peer_id: nil, thread_id: nil}
  """
  @spec channel_wide(channel_id()) :: t()
  def channel_wide(channel_id) do
    %__MODULE__{
      channel_id: channel_id,
      account_id: nil,
      peer_id: nil,
      thread_id: nil
    }
  end

  @doc """
  Checks if a route is more specific than another.

  ## Examples

      iex> Route.more_specific?(
      ...>   Route.new("telegram", "default", "123", "456"),
      ...>   Route.new("telegram", "default", "123", nil)
      ...> )
      true

      iex> Route.more_specific?(
      ...>   Route.new("telegram"),
      ...>   Route.new("telegram", "default", "123", "456")
      ...> )
      false
  """
  @spec more_specific?(t(), t()) :: boolean()
  def more_specific?(a, b) do
    specificity(a) > specificity(b)
  end

  defp specificity(%__MODULE__{} = route) do
    cond do
      route.thread_id != nil -> 4
      route.peer_id != nil -> 3
      route.account_id != nil -> 2
      route.channel_id != nil -> 1
      true -> 0
    end
  end
end
