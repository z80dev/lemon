/**
 * App context — provides StateStore + AgentConnection to all components.
 */

import React, { createContext, useContext } from 'react';
import type { StateStore } from '../../state.js';
import type { AgentConnection } from '../../agent-connection.js';

interface AppContextValue {
  store: StateStore;
  connection: AgentConnection;
}

const AppContext = createContext<AppContextValue | null>(null);

export function AppProvider({
  store,
  connection,
  children,
}: {
  store: StateStore;
  connection: AgentConnection;
  children: React.ReactNode;
}) {
  return (
    <AppContext.Provider value={{ store, connection }}>
      {children}
    </AppContext.Provider>
  );
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be used within AppProvider');
  return ctx;
}

export function useStore(): StateStore {
  return useApp().store;
}

export function useConnection(): AgentConnection {
  return useApp().connection;
}
