mod model;
mod fold;
mod validation;

pub use model::{Event, Kind, Stock, Inventory, ErrorKind, FoldError};
pub use fold::fold;
