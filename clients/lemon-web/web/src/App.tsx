import { useEffect } from 'react';
import './App.css';
import { useLemonSocket } from './rpc/useLemonSocket';
import { useLemonStore } from './store/useLemonStore';
import { TopBar } from './components/TopBar';
import { Sidebar } from './components/Sidebar';
import { ChatView } from './components/ChatView';
import { ToolTimeline } from './components/ToolTimeline';
import { StatusBar } from './components/StatusBar';
import { WidgetDock } from './components/WidgetDock';
import { Composer } from './components/Composer';
import { WorkingBanner } from './components/WorkingBanner';
import { ToastStack } from './components/ToastStack';
import { UIRequestModal } from './components/UIRequestModal';

function App() {
  useLemonSocket();

  const send = useLemonStore((state) => state.send);
  const title = useLemonStore((state) => state.ui.title);
  const connectionState = useLemonStore((state) => state.connection.state);

  useEffect(() => {
    if (title) {
      document.title = title;
    }
  }, [title]);

  useEffect(() => {
    if (connectionState !== 'connected') return;
    send({ type: 'list_models' });
    send({ type: 'list_sessions' });
    send({ type: 'list_running_sessions' });
  }, [connectionState, send]);

  return (
    <div className="app">
      <TopBar />
      <div className="layout">
        <Sidebar />
        <main className="main">
          <StatusBar />
          <WidgetDock />
          <div className="main-grid">
            <ChatView />
            <ToolTimeline />
          </div>
        </main>
      </div>
      <WorkingBanner />
      <Composer />
      <UIRequestModal />
      <ToastStack />
    </div>
  );
}

export default App;
