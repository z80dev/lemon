import { describe, expect, it } from 'vitest';
import { StateStore } from '../state.js';
import { applyReadyMessage } from './App.js';

describe('applyReadyMessage', () => {
  it('hydrates the initial ready state before event listeners are mounted', () => {
    const store = new StateStore({ cwd: '/before' });

    applyReadyMessage(store, {
      type: 'ready',
      cwd: '/repo',
      model: { provider: 'remote', id: 'echo' },
      debug: false,
      ui: false,
      primary_session_id: 'agent:default:tui-proof',
      active_session_id: 'agent:default:tui-proof',
    });

    const state = store.getState();
    expect(state.ready).toBe(true);
    expect(state.cwd).toBe('/repo');
    expect(state.model).toEqual({ provider: 'remote', id: 'echo' });
    expect(state.primarySessionId).toBe('agent:default:tui-proof');
    expect(state.activeSessionId).toBe('agent:default:tui-proof');
    expect(state.sessions.has('agent:default:tui-proof')).toBe(true);
  });
});
