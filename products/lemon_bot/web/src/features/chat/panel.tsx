import type { Conversation, Run, TranscriptEntry } from '@lemon-bot/sdk';
import { Activity, BookOpen, Brain, CalendarClock, ChevronRight, FolderOpen, Plug, Repeat, Settings2, Sparkles, Square, X } from 'lucide-react';
import { useApp } from '../../app';
import { BotAvatar, LemonFace, formatTime, presenceLabel } from '../../ui';
import { ConversationDetails } from './details';
import { RunOutcomeRow } from './index';

export type PanelTab = 'activity' | 'details' | 'library';
const activeStatus: Record<string, true> = { reserved: true, queued: true, running: true, awaiting_input: true, outcome_unknown: true };
const outcomeLabel: Record<Run['status'], string> = { reserved: 'Starting', queued: 'Queued', running: 'Working', awaiting_input: 'Needs your input', succeeded: 'Finished', failed: 'Couldn’t finish', cancelled: 'Stopped', outcome_unknown: 'Unconfirmed' };

function duration(run: Run, now: number) {
  if (run.startedAtMs === null) return '';
  const seconds = Math.max(0, Math.round(((run.completedAtMs ?? now) - run.startedAtMs) / 1000));
  return seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : `${Math.floor(seconds / 3600)}h ${Math.floor(seconds / 60) % 60}m`;
}

/** Steps are the run's sanitized tool-call entries from the transcript. */
function RunSteps({ run, entries }: { run: Run; entries: TranscriptEntry[] }) {
  const steps = entries.filter(entry => entry.kind === 'tool_call' && entry.runId === run.id);
  if (!steps.length) return null;
  return <ol className="panel-steps">{steps.map(step => step.kind === 'tool_call' && <li key={step.id}><details><summary><span className={`chat-tool-dot ${step.status}`} aria-hidden="true"/><span className="panel-step-title">{step.title}</span><span className="muted">{step.status === 'started' ? 'running' : step.status}</span></summary><p><code>{step.tool}</code></p>{step.detail && <p>{step.detail}</p>}</details></li>)}</ol>;
}

export function BotPanel({ id, conversation, changed, runs, entries, tab, setTab, stop, stopDisabled }: { id: string; conversation: Conversation; changed: (conversation: Conversation) => void; runs: Run[]; entries: TranscriptEntry[]; tab: PanelTab; setTab: (tab: PanelTab | null) => void; stop: (run: Run) => void; stopDisabled: boolean }) {
  const { snapshot, navigate } = useApp();
  const bot = snapshot.bots.find(item => item.id === (conversation.leadBotId || conversation.botIds[0]));
  const machine = bot ? snapshot.machines.find(item => item.id === bot.machineId) : undefined;
  const now = Date.now();
  const active = runs.filter(run => activeStatus[run.status]);
  const recent = runs.filter(run => !activeStatus[run.status]).sort((a, b) => (b.startedAtMs ?? b.createdAtMs) - (a.startedAtMs ?? a.createdAtMs)).slice(0, 20);
  const botName = (botId: string) => snapshot.bots.find(item => item.id === botId)?.name || 'Bot';
  const library: [string, string, typeof FolderOpen, () => void][] = bot ? [
    ['Files', machine ? `On ${machine.name}` : 'Host files', FolderOpen, () => navigate({ screen: 'machine.detail', id: bot.machineId, botId: bot.id })],
    ['Memory', 'What this Bot remembers', Brain, () => navigate({ screen: 'memory', id: bot.id, botId: bot.id })],
    ['Routines', 'Scheduled work', Repeat, () => navigate({ screen: 'routines', botId: bot.id })],
    ['Skills', `${bot.skillIds.length} enabled`, Sparkles, () => navigate({ screen: 'skills', botId: bot.id })],
    ['Connected apps', 'Accounts this Bot can use', Plug, () => navigate({ screen: 'connect.apps', botId: bot.id })],
    ['Templates', 'Start a similar Bot', BookOpen, () => navigate({ screen: 'templates' })],
  ] : [];
  return <aside className="chat-panel" id={id} aria-label="Bot details and activity">
    <div className="chat-panel-top"><button className="icon-button" aria-label="Close panel" onClick={() => setTab(null)}><X size={18}/></button></div>
    <div className="panel-hero">
      {bot ? <BotAvatar bot={bot} size={76}/> : <LemonFace size={76}/>}
      <h2>{conversation.kind === 'dm' && bot ? bot.name : conversation.name}</h2>
      {bot && (bot.title || bot.job) && <p className="muted">{bot.title || bot.job}</p>}
      {bot && <span className="presence-pill"><span className={`status-dot ${bot.activity}`} aria-hidden="true"/>{presenceLabel(bot.activity)}{machine && <> · {machine.name}</>}</span>}
    </div>
    <div className="segmented" role="tablist" aria-label="Panel sections">
      {(['activity', 'details', 'library'] as const).map(value => <button key={value} role="tab" aria-selected={tab === value} className={tab === value ? 'selected' : ''} onClick={() => setTab(value)}>{value[0].toUpperCase() + value.slice(1)}</button>)}
    </div>
    <div className="chat-panel-body" role="tabpanel">
      {tab === 'activity' && <>
        <section className="panel-section">
          <h3>Now</h3>
          {active.length === 0 && <p className="panel-idle">{bot?.activity === 'offline' ? 'Offline. Its host is not reachable right now.' : 'Nothing running. Send a message to start work.'}</p>}
          {active.map(run => <div className="panel-run live" key={run.id}>
            <div className="panel-run-head"><span className={`spinner ${run.status === 'awaiting_input' ? 'paused' : ''}`} aria-hidden="true"/><strong>{botName(run.botId)}</strong><span className="muted">{outcomeLabel[run.status]}{run.startedAtMs !== null && ` · ${duration(run, now)}`}</span>
              <button className="chat-stop" aria-label="Stop this run" title="Stop" disabled={stopDisabled || run.status === 'outcome_unknown'} onClick={() => stop(run)}><Square size={11} fill="currentColor"/></button></div>
            <RunSteps run={run} entries={entries}/>
            <details className="panel-ids"><summary>IDs</summary><code>{run.id}</code></details>
          </div>)}
        </section>
        <section className="panel-section">
          <h3>Recent runs</h3>
          {recent.length === 0 && <p className="muted small">No finished runs in this conversation yet.</p>}
          {recent.map(run => <div className={`panel-run ${run.status}`} key={run.id}>
            {run.status === 'succeeded' ? <><div className="panel-run-head"><span className="outcome-dot succeeded" aria-hidden="true"/><strong>{outcomeLabel[run.status]}</strong><span className="muted">{formatTime(run.completedAtMs ?? run.startedAtMs)}{run.startedAtMs !== null && ` · ${duration(run, now)}`}</span></div><RunSteps run={run} entries={entries}/><details className="panel-ids"><summary>IDs</summary><code>{run.id}</code></details></> : <RunOutcomeRow run={run} showTime/>}
          </div>)}
        </section>
        {bot && <section className="panel-links">
          <button onClick={() => navigate({ screen: 'activity', botId: bot.id })}><Activity size={16}/><span>All activity</span><ChevronRight size={16}/></button>
          <button onClick={() => navigate({ screen: 'upcoming', botId: bot.id })}><CalendarClock size={16}/><span>Upcoming</span><ChevronRight size={16}/></button>
        </section>}
      </>}
      {tab === 'details' && <>
        {bot && <section className="panel-section">
          <dl className="panel-facts">
            {bot.job && <><dt>Job</dt><dd>{bot.job}</dd></>}
            {bot.instructions && <><dt>Instructions</dt><dd className="panel-clamp">{bot.instructions}</dd></>}
            <dt>Host</dt><dd>{machine ? `${machine.name} · ${machine.status}` : 'Assigned host'}</dd>
            <dt>Notifications</dt><dd>{bot.sidebar.notificationsEnabled ? 'On' : 'Off'}</dd>
          </dl>
          <div className="panel-links">
            <button onClick={() => navigate({ screen: 'bot.overview', id: bot.id, botId: bot.id })}><span>Bot overview</span><ChevronRight size={16}/></button>
            <button onClick={() => navigate({ screen: 'bot.settings', id: bot.id, botId: bot.id })}><Settings2 size={16}/><span>Bot settings</span><ChevronRight size={16}/></button>
          </div>
        </section>}
        <ConversationDetails conversation={conversation} changed={changed}/>
      </>}
      {tab === 'library' && <section className="panel-links">
        {library.map(([label, hint, Icon, open]) => <button key={label} onClick={open}><Icon size={16}/><span>{label}<small>{hint}</small></span><ChevronRight size={16}/></button>)}
        {!bot && <p className="muted">Open a Bot’s own chat to see its library.</p>}
      </section>}
    </div>
  </aside>;
}
