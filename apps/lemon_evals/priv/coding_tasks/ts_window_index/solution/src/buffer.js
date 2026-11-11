export class EventBuffer {
  events = [];
  head = 0;
  onVisit;
  constructor(onVisit) {
    this.onVisit = onVisit;
  }
  append(event) {
    this.events.push(event);
  }
  evict(cutoff, expired) {
    while (this.head < this.events.length) {
      const event = this.events[this.head];
      this.onVisit();
      if (event.at > cutoff)
        break;
      expired(event);
      this.events[this.head++] = undefined;
    }
    if (this.head === this.events.length) {
      this.events = [];
      this.head = 0;
    } else if (this.head >= 1024 && this.head * 2 >= this.events.length) {
      this.events = this.events.slice(this.head);
      this.head = 0;
    }
  }
}
