use crate::{ErrorKind as E, Event, Kind};

fn identifier(s: &str, uppercase: bool) -> bool {
    (1..=32).contains(&s.len()) && s.bytes().all(|b| {
        b.is_ascii_digit() || b == b'_' || b == b'-' ||
        if uppercase { b.is_ascii_uppercase() } else { b.is_ascii_alphabetic() }
    })
}

pub(crate) fn validate(last: Option<u64>, event: &Event) -> Result<(), E> {
    if last.is_some_and(|last| event.id <= last) { return Err(E::NonIncreasingId); }
    if !identifier(&event.sku, true) { return Err(E::InvalidSku); }
    let quantity = match &event.kind {
        Kind::Reserve { reservation, quantity } |
        Kind::Release { reservation, quantity } |
        Kind::Ship { reservation, quantity } => {
            if !identifier(reservation, false) { return Err(E::InvalidReservation); }
            *quantity
        }
        Kind::Receive(quantity) => *quantity,
        Kind::Correct(delta) => delta.unsigned_abs(),
    };
    if quantity == 0 { return Err(E::ZeroQuantity); }
    Ok(())
}
