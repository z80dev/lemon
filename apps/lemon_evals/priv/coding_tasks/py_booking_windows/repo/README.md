# Room calendar

`Booking(id, room, start, end, cancelled=False)` records integer-minute room reservations. `Calendar(bookings).conflicts(room, start, end)` is used by the scheduling UI. Intervals are half-open; the full query contract is in the change request.

Run visible checks with `python3 -m unittest discover -s tests -v`.
