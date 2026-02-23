import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { MonitoringApp } from './components/monitoring/MonitoringApp.tsx'

const isMonitor = window.location.pathname === '/monitor' || new URLSearchParams(window.location.search).has('monitor')

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {isMonitor ? <MonitoringApp /> : <App />}
  </StrictMode>,
)
