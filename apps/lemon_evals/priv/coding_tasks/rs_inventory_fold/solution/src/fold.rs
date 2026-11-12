use crate::{Event, Kind, Inventory, FoldError, ErrorKind as E};
use crate::validation::validate;

impl Inventory {
    pub fn apply(&mut self, event: &Event) -> Result<(), FoldError> {
        self.apply_checked(event).map_err(|kind| FoldError { event_id: event.id, kind })
    }

    fn apply_checked(&mut self, event: &Event) -> Result<(), E> {
        validate(self.last_id, event)?;
        match &event.kind {
            Kind::Receive(quantity) => self.add_physical(&event.sku, *quantity)?,
            Kind::Correct(delta) if *delta > 0 => self.add_physical(&event.sku, *delta as u64)?,
            Kind::Correct(delta) => {
                let stock = self.items.get_mut(&event.sku).ok_or(E::UnknownSku)?;
                let quantity = delta.unsigned_abs();
                if quantity > stock.available() { return Err(E::InsufficientAvailable); }
                stock.on_hand -= quantity;
            }
            Kind::Reserve { reservation, quantity } => {
                let stock = self.items.get_mut(&event.sku).ok_or(E::UnknownSku)?;
                if *quantity > stock.available() { return Err(E::InsufficientAvailable); }
                // Total reservations cannot exceed on_hand, so addition is bounded by u64::MAX.
                if let Some(held) = stock.reservations.get_mut(reservation) {
                    *held += quantity;
                } else {
                    stock.reservations.insert(reservation.clone(), *quantity);
                }
            }
            Kind::Release { reservation, quantity } | Kind::Ship { reservation, quantity } => {
                let stock = self.items.get_mut(&event.sku).ok_or(E::UnknownSku)?;
                let held = stock.reservations.get_mut(reservation).ok_or(E::UnknownReservation)?;
                if *quantity > *held { return Err(E::InsufficientReserved); }
                *held -= quantity;
                if *held == 0 { stock.reservations.remove(reservation); }
                if matches!(&event.kind, Kind::Ship { .. }) { stock.on_hand -= quantity; }
            }
        }
        self.last_id = Some(event.id);
        Ok(())
    }

    fn add_physical(&mut self, sku: &str, quantity: u64) -> Result<(), E> {
        if let Some(stock) = self.items.get_mut(sku) {
            let total = stock.on_hand.checked_add(quantity).ok_or(E::Overflow)?;
            stock.on_hand = total;
        } else {
            self.items.insert(sku.to_owned(), crate::Stock { on_hand: quantity, ..Default::default() });
        }
        Ok(())
    }
}

pub fn fold(events: &[Event]) -> Result<Inventory, FoldError> {
    let mut inventory = Inventory::default();
    for event in events { inventory.apply(event)?; }
    Ok(inventory)
}
