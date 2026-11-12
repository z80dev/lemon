export interface SubscribeOptions { once?: boolean }
export interface Hub<Events extends object> {
  subscribe<K extends keyof Events>(key: K, listener: (payload: Events[K]) => void, options?: SubscribeOptions): () => void;
  publish<K extends keyof Events>(key: K, payload: Events[K]): void;
  listenerCount<K extends keyof Events>(key: K): number;
}
