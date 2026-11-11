class Calendar:
    def __init__(self, bookings):
        self.bookings = list(bookings)

    def conflicts(self, room, start, end):
        for booking in self.bookings:
            if booking.room == room and booking.start <= end and start <= booking.end:
                return [booking.id]
        return []
