use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event { pub id: u64, pub sku: String, pub kind: Kind }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Receive(u64),
    Reserve { reservation: String, quantity: u64 },
    Release { reservation: String, quantity: u64 },
    Ship { reservation: String, quantity: u64 },
    Correct(i64),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stock { pub on_hand: u64, pub reservations: BTreeMap<String, u64> }

impl Stock {
    pub fn available(&self) -> u64 { self.on_hand - self.reservations.values().sum::<u64>() }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Inventory { pub last_id: Option<u64>, pub items: BTreeMap<String, Stock> }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    NonIncreasingId, InvalidSku, InvalidReservation, ZeroQuantity, UnknownSku,
    UnknownReservation, InsufficientAvailable, InsufficientReserved, Overflow,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldError { pub event_id: u64, pub kind: ErrorKind }
