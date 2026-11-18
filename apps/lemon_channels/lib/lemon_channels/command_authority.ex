defmodule LemonChannels.CommandAuthority do
  @moduledoc """
  Central enforcement of `adminOnly` entries in `LemonChannels.CommandCatalog`.

  Every chat surface asks this module before dispatching a catalog command, so
  the flag that hides a command from menus is also the one that refuses it.
  The caller supplies the platform-verified authority of the sender:

    * Telegram: `sender.owner?`, true only for a positive (human) sender id in
      the transport's `allowed_chat_ids`.
    * Discord: the invoking guild member holds Administrator or Manage Server in
      the interaction's Discord-supplied `member.permissions`. This authority
      gates channel administration only; it never grants owner identity.

  Unknown commands and a missing authority fail closed for `adminOnly` entries.
  """

  alias LemonChannels.CommandCatalog

  @refusal "Only the bot owner can use this command; nothing was changed."

  @admin_only_commands CommandCatalog.catalog()
                       |> Enum.filter(&(&1["adminOnly"] == true))
                       |> Enum.map(& &1["name"])

  @doc "Canonical names of catalog commands restricted to the owner."
  @spec admin_only_commands() :: [String.t()]
  def admin_only_commands, do: @admin_only_commands

  @doc "Whether a command name or alias is `adminOnly` in the catalog."
  @spec admin_only?(term()) :: boolean()
  def admin_only?(command) do
    case CommandCatalog.find(command) do
      {:ok, %{"adminOnly" => true}} -> true
      _ -> false
    end
  end

  @doc "Authorize `command` for a sender whose verified owner authority is `owner?`."
  @spec authorize(term(), boolean()) :: :ok | {:error, :owner_required}
  def authorize(command, owner?) do
    if admin_only?(command) and owner? != true, do: {:error, :owner_required}, else: :ok
  end

  @doc "The chat reply for a refused `adminOnly` command."
  @spec refusal_message() :: String.t()
  def refusal_message, do: @refusal

  @discord_administrator 0x8
  @discord_manage_guild 0x20

  @doc """
  Whether a Discord interaction's guild member holds Administrator or Manage
  Server, from the Discord-supplied `member.permissions` bitset. DMs carry no
  member and therefore no authority.
  """
  @spec discord_admin?(term()) :: boolean()
  def discord_admin?(%{} = interaction) do
    with %{} = member <- field(interaction, :member),
         permissions when is_binary(permissions) <- field(member, :permissions),
         {bits, ""} <- Integer.parse(permissions) do
      Bitwise.band(bits, Bitwise.bor(@discord_administrator, @discord_manage_guild)) != 0
    else
      _ -> false
    end
  end

  def discord_admin?(_interaction), do: false

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
