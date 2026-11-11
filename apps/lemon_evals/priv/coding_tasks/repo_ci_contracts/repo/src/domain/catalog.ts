export class Catalog {
  #skus = new Set<string>();
  add(sku: string): void { this.#skus.add(sku); }
  list(): string[] { return [...this.#skus].sort(); }
}
