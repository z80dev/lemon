export class Totals {
  values = new Map;
  add(event) {
    const value = this.values.get(event.key);
    if (value) {
      value.count++;
      value.sum += event.value;
    } else
      this.values.set(event.key, { key: event.key, count: 1, sum: event.value });
  }
  remove(event) {
    const value = this.values.get(event.key);
    value.count--;
    value.sum -= event.value;
    if (value.count === 0)
      this.values.delete(event.key);
  }
  get(key) {
    const value = this.values.get(key);
    return value ? { ...value } : undefined;
  }
  snapshot() {
    return [...this.values.values()].map((value) => ({ ...value })).sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  }
}
