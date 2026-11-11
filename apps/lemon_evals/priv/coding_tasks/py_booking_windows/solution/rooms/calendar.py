class Calendar:
    def __init__(self, bookings):
        self.bookings = list(bookings)

    def conflicts(self, room, start, end):
        if start >= end:
            raise ValueError('start must precede end')
        matches = [booking for booking in self.bookings
                   if booking.room == room and not booking.cancelled
                   and booking.start < end and start < booking.end]
        return [booking.id for booking in sorted(matches, key=lambda booking: (booking.start, booking.id))]
