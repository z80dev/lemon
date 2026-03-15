/**
 * Git modeline refresh hook.
 */

import { useEffect, useRef } from 'react';
import { useStore } from '../context/AppContext.js';
import { useAppSelector } from './useAppState.js';
import { getGitModeline } from '../../git-utils.js';
import { GIT_REFRESH_INTERVAL_MS } from '../../constants.js';

export function useGitModeline(): void {
  const store = useStore();
  const ready = useAppSelector((s) => s.ready);
  const cwd = useAppSelector((s) => s.cwd);
  const inFlight = useRef(false);

  useEffect(() => {
    if (!ready) return;

    const refresh = async () => {
      if (inFlight.current) return;
      inFlight.current = true;
      try {
        const modeline = await getGitModeline(cwd || process.cwd());
        store.setStatus('modeline:git', modeline);
      } finally {
        inFlight.current = false;
      }
    };

    refresh();
    const timer = setInterval(refresh, GIT_REFRESH_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [ready, cwd, store]);
}
