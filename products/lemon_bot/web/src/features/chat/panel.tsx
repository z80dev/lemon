import { useState, type ReactNode } from 'react';
import type { Conversation, Run, TranscriptEntry } from '@lemon-bot/sdk';
import { nonce } from '@lemon-bot/sdk';
import { Activity, BookOpen, Brain, Check, ChevronRight, Clock, Copy, FileText, GitBranch, Hand, History, Languages, LayoutGrid, ListChecks, Monitor, Pencil, Repeat, Settings2, ShieldCheck, Sparkles, Square, X, type LucideIcon } from 'lucide-react';
import { useApp } from '../../app';
import { BotAvatar, ErrorNotice, LemonFace, useAction, useQuery } from '../../ui';
import { compactDuration, currentStep, humanize, liveRunStatuses, relativeTime, toolIcon } from '../../live';
import { ConversationDetails } from './details';
import { TypingDots } from './index';

export type PanelTab = 'activity' | 'details' | 'library';
const outcomeLabel: Record<string, string> = { succeeded: 'Finished', failed: 'Couldn’t finish', cancelled: 'Stopped', outcome_unknown: 'Unconfirmed' };

/** Inspector row: icon column, title, meta, chevron (design system §5 Inspector). */
function Row({ icon: Icon, title, meta, onClick, children }: { icon: LucideIcon; title: ReactNode; meta?: ReactNode; onClick?: () => void; children?: ReactNode }) {
  const body = <><Icon size={17} className="inspector-row-icon" aria-hidden="true"/><span className="inspector-row-text"><strong>{title}</strong>{meta && <small>{meta}</small>}</span>{children}{onClick && <ChevronRight size={15} className="faint" aria-hidden="true"/>}</>;
  return onClick ? <button className="inspector-row" onClick={onClick}>{body}</button> : <div className="inspector-row">{body}</div>;
}

function RecentRun({ run }: { run: Run }) {
  const { reportError } = useApp(); const [open, setOpen] = useState(false);
  const duration = run.startedAtMs !== null && run.completedAtMs !== null ? ` · ${compactDuration(run.startedAtMs, run.completedAtMs)}` : '';
  return <div className="recent-run">
    <button className="recent-run-head" aria-expanded={open} onClick={() => setOpen(!open)}><span className={`outcome-dot ${run.status}`} aria-hidden="true"/><strong>{outcomeLabel[run.status] || humanize(run.status)}</strong><small>{relativeTime(run.completedAtMs ?? run.updatedAtMs)}{duration}</small><ChevronRight size={13} className="chevron faint" aria-hidden="true"/></button>
    {open && <div className="recent-run-body">{run.error ? <p>{run.error.message}</p> : <p className="muted">{run.status === 'succeeded' ? 'Finished without errors.' : 'No error details.'}</p>}{run.error?.requestId && <button className="pill-button secondary compact" onClick={() => void navigator.clipboard.writeText(run.error?.requestId || '').catch(reportError)}><Copy size={12}/>Copy request ID</button>}</div>}
  </div>;
}

export function BotPanel({ id, conversation, changed, runs, entries, tab, setTab, stop, stopDisabled }: { id: string; conversation: Conversation; changed: (conversation: Conversation) => void; runs: Run[]; entries: TranscriptEntry[]; tab: PanelTab; setTab: (tab: PanelTab | null) => void; stop: (run: Run) => void; stopDisabled: boolean }) {
  const { client, snapshot, navigate, online, refresh } = useApp();
  const bot = snapshot.bots.find(item => item.id === (conversation.leadBotId || conversation.botIds[0]));
  const machine = bot ? snapshot.machines.find(item => item.id === bot.machineId) : undefined;
  const botRuns = useQuery(`inspector-runs:${bot?.id}`, () => bot ? client.call('GET /runs', { query: { botId: bot.id, limit: 30 } }) : Promise.resolve({ items: [], nextCursor: null }));
  const upcoming = useQuery(`inspector-upcoming:${bot?.id}`, () => bot ? client.call('GET /upcoming', { query: { botId: bot.id, limit: 3 } }) : Promise.resolve({ items: [], nextCursor: null }));
  const activity = useQuery(`inspector-activity:${bot?.id}`, () => bot ? client.call('GET /activity', { query: { botId: bot.id, limit: 3 } }) : Promise.resolve({ items: [], nextCursor: null }));
  const action = useAction({ reconcileOnRefresh: true, available: online });
  const live = runs.filter(run => liveRunStatuses[run.status]);
  const step = currentStep(runs, entries, conversation);
  const finished = (botRuns.data?.items ?? []).filter(run => !liveRunStatuses[run.status]).sort((a, b) => (b.completedAtMs ?? b.updatedAtMs) - (a.completedAtMs ?? a.updatedAtMs));
  const lastFinished = finished.find(run => run.completedAtMs !== null);
  const steps = entries.filter(entry => entry.kind === 'tool_call' && !!entry.runId && live.some(run => run.id === entry.runId)).slice(-8);
  const tasks = snapshot.conversations.filter(room => room.kind === 'task' && room.parentConversationId === conversation.id).sort((a, b) => b.updatedAtMs - a.updatedAtMs);
  const status = step?.needsInput || bot?.activity === 'needs_input' ? 'needs_input' : live.length ? 'working' : bot?.activity === 'offline' ? 'offline' : 'idle';
  const statusLabel: Record<string, string> = { idle: 'Idle', working: 'Working', needs_input: 'Needs you', offline: 'Offline' };
  const machineMeta = machine ? `${humanize(machine.status)}${machine.lastSeenAtMs ? ` · seen ${relativeTime(machine.lastSeenAtMs)}` : ''}` : 'Assigned machine';
  const name = conversation.kind === 'dm' && bot ? bot.name : conversation.name;
  return <aside className="chat-panel" id={id} aria-label="Bot details and activity">
    <button className="ghost-circle panel-close" aria-label="Close details" onClick={() => setTab(null)}><X size={16}/></button>
    <div className="panel-hero">
      {bot ? <BotAvatar bot={bot} size={72} presence={online}/> : <LemonFace size={72}/>}
      <h2>{name}</h2>
      {bot && (bot.title ? <p className="muted">{bot.title}</p> : <button className="add-label" onClick={() => navigate({ screen: 'bot.edit', id: bot.id, botId: bot.id })}>Add a label</button>)}
      {bot && <div className="status-chips"><span className="chip"><span className={`status-dot ${status}`} aria-hidden="true"/>{statusLabel[status]}</span>{machine && <span className="chip"><span className={`status-dot ${machine.status === 'online' ? 'idle' : 'offline'}`} aria-hidden="true"/>{machine.name}</span>}</div>}
    </div>
    <div className="segmented sliding" role="tablist" aria-label="Inspector sections" style={{ ['--tab-index' as string]: ['activity', 'details', 'library'].indexOf(tab) }}>
      <span className="segmented-thumb" aria-hidden="true"/>
      {(['activity', 'details', 'library'] as const).map(value => <button key={value} role="tab" aria-selected={tab === value} className={tab === value ? 'selected' : ''} onClick={() => setTab(value)}>{value[0].toUpperCase() + value.slice(1)}</button>)}
    </div>
    <div className="chat-panel-body" role="tabpanel">
      {tab === 'activity' && <>
        <section className="now-card">
          <div className="now-head"><span className={`status-dot ${status}`} aria-hidden="true"/><strong>{statusLabel[status]}</strong>{live.length > 0 && <button className="stop-pill danger" disabled={stopDisabled} onClick={() => live.forEach(stop)}><Square size={9} fill="currentColor"/>Stop</button>}</div>
          {step ? <>
            <div className="now-step">{step.needsInput ? <Hand size={16} className="warning-text" aria-hidden="true"/> : (() => { const Icon = toolIcon(step.tool || ''); return <Icon size={16} aria-hidden="true"/>; })()}<span>{step.title}</span>{step.sinceMs !== undefined && <small>{compactDuration(step.sinceMs)}</small>}</div>
            {steps.length > 0 && <ol className="step-rows">{steps.map(entry => { if (entry.kind !== 'tool_call') return null; const Icon = toolIcon(entry.tool); return <li key={entry.id}><details><summary><Icon size={14} aria-hidden="true"/><span className="step-text"><span>{entry.title || humanize(entry.tool)}</span>{entry.detail && <small>{entry.detail.split('\n')[0]}</small>}</span>{entry.status === 'started' ? <TypingDots/> : entry.status === 'failed' ? <X size={13} className="danger-text" aria-label="Failed"/> : <Check size={13} className="faint" aria-label="Done"/>}</summary><pre>{entry.tool}{entry.detail ? `\n${entry.detail}` : ''}</pre></details></li>; })}</ol>}
          </> : <><p className="now-idle">{status === 'offline' ? 'Offline — its machine isn’t reachable' : 'Idle — nothing running'}</p>{lastFinished && <small className="faint">Last finished {relativeTime(lastFinished.completedAtMs ?? lastFinished.updatedAtMs)}</small>}</>}
        </section>
        {bot && <Row icon={Monitor} title={machine?.name || 'Machine'} meta={machineMeta} onClick={() => navigate({ screen: 'machine.detail', id: bot.machineId, botId: bot.id })}/>}
        <section className="panel-section"><h3>Recent runs</h3>
          <ErrorNotice error={botRuns.error}/>
          {finished.slice(0, 8).map(run => <RecentRun key={run.id} run={run}/>)}
          {botRuns.data && !finished.length && <p className="panel-empty">No finished runs yet</p>}
        </section>
        <section className="panel-section"><h3>Upcoming</h3>
          {(upcoming.data?.items ?? []).map(item => <Row key={item.id} icon={item.kind === 'routine' ? Repeat : Clock} title={item.title} meta={`${new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(item.dueAtMs))}${item.blockedReason ? ` · ${item.blockedReason}` : ''}`} onClick={() => navigate(item.routineId ? { screen: 'routines', id: item.routineId, botId: item.botId } : { screen: 'upcoming', botId: item.botId })}/>)}
          {upcoming.data && !upcoming.data.items.length && <p className="panel-empty">Nothing scheduled</p>}
        </section>
        <section className="panel-section"><h3>Recent activity</h3>
          {(activity.data?.items ?? []).map(item => <Row key={item.id} icon={Activity} title={item.title} meta={`${item.summary ? `${item.summary} · ` : ''}${relativeTime(item.occurredAtMs)}`} onClick={item.conversationId ? () => navigate({ screen: 'conversation', id: item.taskConversationId || item.conversationId || undefined, entryId: item.entryId || undefined }) : undefined}/>)}
          {activity.data && !activity.data.items.length && <p className="panel-empty">No recent activity</p>}
        </section>
        <section className="panel-section"><h3>Tasks and threads</h3>
          {tasks.map(room => <Row key={room.id} icon={GitBranch} title={room.name} meta={room.activity.length ? 'Working…' : relativeTime(room.updatedAtMs)} onClick={() => navigate({ screen: 'conversation', id: room.id })}/>)}
          {!tasks.length && <p className="panel-empty">No tasks yet</p>}
        </section>
        {bot && <Row icon={ListChecks} title="All activity" onClick={() => navigate({ screen: 'activity', botId: bot.id })}/>}
      </>}
      {tab === 'details' && <>
        {bot && <>
          <section className="panel-section"><h3>Persona</h3>
            <Row icon={Pencil} title="Instructions" meta={bot.instructions ? <span className="clamp-2">{bot.instructions}</span> : 'None yet'} onClick={() => navigate({ screen: 'bot.edit', id: bot.id, botId: bot.id })}/>
            <Row icon={Sparkles} title="Skills" meta={`${bot.skillIds.length} enabled`} onClick={() => navigate({ screen: 'skills', botId: bot.id })}/>
            <Row icon={Settings2} title="Model and profile" meta="Model, runtime profile and limits" onClick={() => navigate({ screen: 'bot.settings', id: bot.id, botId: bot.id })}/>
          </section>
          <section className="panel-section"><h3>Placement</h3>
            <Row icon={Monitor} title={machine?.name || 'Machine'} meta={machineMeta} onClick={() => navigate({ screen: 'machine.detail', id: bot.machineId, botId: bot.id })}/>
            <Row icon={Languages} title="Voice and language" meta={`${bot.voice.voiceId || 'Default voice'} · ${bot.language || 'Auto language'}`} onClick={() => navigate({ screen: 'bot.edit', id: bot.id, botId: bot.id, tab: 'voice' })}/>
            <label className="inspector-row toggle-row"><span className="inspector-row-text"><strong>Notifications</strong><small>Alerts when this Bot finishes or needs you</small></span><input type="checkbox" role="switch" checked={bot.sidebar.notificationsEnabled} disabled={!online || action.busy} onChange={event => void action.run(async () => { await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, notificationsEnabled: event.target.checked } }); await refresh(); })}/></label>
            <ErrorNotice error={action.error}/>
          </section>
          <section className="panel-section"><h3>Trust and history</h3>
            <Row icon={ShieldCheck} title="Bot authorization" meta="What it may do on its own" onClick={() => navigate({ screen: 'bot.settings', id: bot.id, botId: bot.id })}/>
            <Row icon={History} title="Preference history" onClick={() => navigate({ screen: 'preference.changes', id: bot.id, botId: bot.id })}/>
            <Row icon={LayoutGrid} title="Connected apps" onClick={() => navigate({ screen: 'connect.apps', botId: bot.id })}/>
            <Row icon={Pencil} title="Edit identity" meta="Name, label, avatar and job" onClick={() => navigate({ screen: 'bot.edit', id: bot.id, botId: bot.id })}/>
          </section>
        </>}
        <section className="panel-section"><h3>This conversation</h3><ConversationDetails conversation={conversation} changed={changed}/></section>
        {bot && <button className="quiet-link" onClick={() => navigate({ screen: 'bot.settings', id: bot.id, botId: bot.id })}>Duplicate, move, reset or delete…</button>}
      </>}
      {tab === 'library' && <section className="panel-section">
        {bot ? <>
          <Row icon={FileText} title="Reference files" meta={`${bot.referenceAttachmentIds.length} file${bot.referenceAttachmentIds.length === 1 ? '' : 's'}`} onClick={() => navigate({ screen: 'bot.overview', id: bot.id, botId: bot.id })}/>
          <Row icon={Brain} title="Memory" meta="What this Bot remembers" onClick={() => navigate({ screen: 'memory', id: bot.id, botId: bot.id })}/>
          <Row icon={Repeat} title="Routines" meta="This Bot’s scheduled work" onClick={() => navigate({ screen: 'routines', botId: bot.id })}/>
          <Row icon={Sparkles} title="Skills library" onClick={() => navigate({ screen: 'skills', botId: bot.id })}/>
          <Row icon={BookOpen} title="Templates" meta="Start a similar Bot" onClick={() => navigate({ screen: 'templates' })}/>
        </> : <p className="panel-empty">Open a Bot’s own chat to see its library.</p>}
      </section>}
    </div>
  </aside>;
}

