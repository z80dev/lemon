defmodule LemonControlPlane.Methods.SmsInboxClearTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SmsInboxClear}

  @inbox :"Elixir.LemonGateway.Sms.Inbox"
  @tables [:sms_inbox, :sms_inbox_reservation]

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    {:ok, _} = Application.ensure_all_started(:lemon_agent)
    clear_tables()
    start_supervised!(@inbox)
    on_exit(&clear_tables/0)
    :ok
  end

  defp clear_tables do
    for table <- @tables,
        {k, _} <- LemonCore.Store.list(table),
        do: LemonCore.Store.delete(table, k)
  end

  test "is an admin-only registered method" do
    assert SmsInboxClear.scopes() == [:admin]
    assert Registry.lookup("sms.inbox.clear") == {:ok, SmsInboxClear}
  end

  test "previews the holder, then clears only with that holder and token" do
    assert :ok = @inbox.reserve("agent:victim:main")
    assert {:error, :inbox_reserved} = @inbox.reserve("agent:other:main")

    assert {:ok, %{"dryRun" => true, "holder" => "agent:victim:main", "confirmToken" => token}} =
             SmsInboxClear.handle(%{}, %{})

    # Wrong holder: refused and the token is spent.
    assert {:error, {:conflict, _, %{"reason" => "confirmation_mismatch"}}} =
             SmsInboxClear.handle(%{"holder" => "agent:other:main", "confirmToken" => token}, %{})

    assert {:error, {:conflict, _, %{"reason" => "confirmation_required"}}} =
             SmsInboxClear.handle(
               %{"holder" => "agent:victim:main", "confirmToken" => token},
               %{}
             )

    assert {:error, :inbox_reserved} = @inbox.reserve("agent:other:main")

    assert {:ok, %{"confirmToken" => token}} = SmsInboxClear.handle(%{"dryRun" => true}, %{})

    assert {:ok, %{"cleared" => true, "holder" => "agent:victim:main"}} =
             SmsInboxClear.handle(
               %{"holder" => "agent:victim:main", "confirmToken" => token},
               %{}
             )

    assert :ok = @inbox.reserve("agent:other:main")
  end

  test "a confirm token requires the holder parameter" do
    assert {:error, {:invalid_params, _, _}} =
             SmsInboxClear.handle(%{"confirmToken" => "x"}, %{})
  end
end
