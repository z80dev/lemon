export class EventBuffer {
  events = [];
  onVisit;
  constructor(onVisit) {
    this.onVisit = onVisit;
  }
  append(event) {
    this.events.push(event);
  }
  evict(cutoff, expired) {
    this.events = this.events.filter((event) => {
      this.onVisit();
      if (event.at <= cutoff) {
        expired(event);
        return false;
      }
      return true;
    });
  }
  forEach(consume) {
    for (const event of this.events) {
      this.onVisit();
      consume(event);
    }
  }
}
