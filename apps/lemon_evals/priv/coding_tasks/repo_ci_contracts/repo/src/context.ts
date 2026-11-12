import type { Context } from './types.ts';
export function createContext(actorId: string | null = null, clock: () => number = () => 0): Context { return { actorId, clock }; }
