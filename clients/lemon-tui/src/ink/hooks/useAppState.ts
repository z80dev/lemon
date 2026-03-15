/**
 * Hook to subscribe to StateStore using useSyncExternalStore.
 */

import { useSyncExternalStore, useCallback } from 'react';
import type { StateStore, AppState } from '../../state.js';
import { useStore } from '../context/AppContext.js';

/**
 * Subscribe to the full AppState. Re-renders on every state change.
 */
export function useAppState(): AppState {
  const store = useStore();
  return useSyncExternalStore(
    useCallback((cb: () => void) => store.subscribe(cb), [store]),
    () => store.getState()
  );
}

/**
 * Subscribe to a derived slice of AppState. Only re-renders when the
 * selector's return value changes (by reference).
 */
export function useAppSelector<T>(selector: (state: AppState) => T): T {
  const store = useStore();
  return useSyncExternalStore(
    useCallback((cb: () => void) => store.subscribe(cb), [store]),
    () => selector(store.getState())
  );
}
