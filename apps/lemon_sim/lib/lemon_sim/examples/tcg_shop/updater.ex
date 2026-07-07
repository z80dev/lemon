defmodule LemonSim.Examples.TcgShop.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonSim.Examples.TcgShop.Events
  alias LemonSim.Examples.TcgShop.Updaters.Consignment
  alias LemonSim.Examples.TcgShop.Updaters.DayRollover
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Grading
  alias LemonSim.Examples.TcgShop.Updaters.Hosting
  alias LemonSim.Examples.TcgShop.Updaters.LossPrevention
  alias LemonSim.Examples.TcgShop.Updaters.Memberships
  alias LemonSim.Examples.TcgShop.Updaters.Observations
  alias LemonSim.Examples.TcgShop.Updaters.OnlineChannel
  alias LemonSim.Examples.TcgShop.Updaters.Preorders
  alias LemonSim.Examples.TcgShop.Updaters.Pricing
  alias LemonSim.Examples.TcgShop.Updaters.Promotions
  alias LemonSim.Examples.TcgShop.Updaters.Purchasing
  alias LemonSim.Examples.TcgShop.Updaters.Returns
  alias LemonSim.Examples.TcgShop.Updaters.Staffing
  alias LemonSim.Examples.TcgShop.Updaters.Suppliers
  alias LemonSim.Kernel.State

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "tcg_checked_dashboard" -> Observations.append_only(state, event)
      "tcg_inspected_inventory" -> Observations.append_only(state, event)
      "tcg_researched_market" -> Observations.apply_researched_market(state, event)
      "tcg_reviewed_customers" -> Observations.append_only(state, event)
      "tcg_order_product_line" -> Suppliers.apply_order_product_line(state, event)
      "tcg_buy_collection" -> Purchasing.apply_buy_collection(state, event)
      "tcg_open_sealed_product" -> Purchasing.apply_open_sealed_product(state, event)
      "tcg_prepare_loose_packs" -> Purchasing.apply_prepare_loose_packs(state, event)
      "tcg_take_consignment" -> Consignment.apply_take_consignment(state, event)
      "tcg_sell_memberships" -> Memberships.apply_sell_memberships(state, event)
      "tcg_schedule_staff_shift" -> Staffing.apply_schedule_staff_shift(state, event)
      "tcg_upgrade_loss_prevention" -> LossPrevention.apply_upgrade_loss_prevention(state, event)
      "tcg_manage_credit_line" -> Finance.apply_manage_credit_line(state, event)
      "tcg_make_bank_deposit" -> Finance.apply_make_bank_deposit(state, event)
      "tcg_set_prices" -> Pricing.apply_set_prices(state, event)
      "tcg_host_event" -> Hosting.apply_host_event(state, event)
      "tcg_take_preorders" -> Preorders.apply_take_preorders(state, event)
      "tcg_take_special_order" -> Preorders.apply_take_special_order(state, event)
      "tcg_run_promotion" -> Promotions.apply_run_promotion(state, event)
      "tcg_manage_online_channel" -> OnlineChannel.apply_manage_online_channel(state, event)
      "tcg_file_supplier_claim" -> Suppliers.apply_file_supplier_claim(state, event)
      "tcg_process_customer_return" -> Returns.apply_process_customer_return(state, event)
      "tcg_submit_grading" -> Grading.apply_submit_grading(state, event)
      "tcg_process_online_orders" -> OnlineChannel.apply_process_online_orders(state, event)
      "tcg_wait_next_day" -> DayRollover.apply_wait_next_day(state, event)
      _ -> {:error, {:invalid_tcg_shop_event, event.kind}}
    end
  end
end
