import { ExpiringCache } from './cache.ts';
export function createSessions(now: () => number) {
  const cache = new ExpiringCache<{user: string}>(2, now);
  return { login(token: string, user: string, ttl: number) { cache.set(token, {user}, ttl); },
    lookup(token: string) { return cache.get(token)?.user; }, count() { return cache.size; } };
}
