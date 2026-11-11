import { useRef, useState } from 'react';
import { LemonBotError, nonce, type Bot, type AgentMessageReceipt } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, Loading, useAction, useQuery } from '../../ui';
import { IntentNotice, useIntent } from './shared';
import './bots.css';

/** Address existing agents; never touches the conversation's unsent composer draft. */
export function AgentControls({ bot, conversationId = bot.mainConversationId }: { bot: Bot; conversationId?: string }) {
  const { client, snapshot } = useApp();
  const key = `lemonbot.agent-message:${client.baseUrl}:${snapshot.workspace.id}:${snapshot.user.id}:${bot.id}:${conversationId}`;
  return <AgentControlsSession key={key} bot={bot} conversationId={conversationId} storageKey={key} />;
}

function AgentControlsSession({ bot, conversationId, storageKey }: { bot: Bot; conversationId: string; storageKey: string }) {
  const { client, online, snapshot, refresh } = useApp();
  // This records dispatched intent only, never an offline queue or an automatic retry.
  const [saved] = useState<{ messageId?: string; target?: string; text?: string; error?: Error }>(() => {
    try {
      const raw = sessionStorage.getItem(storageKey);
      if (!raw) return {};
      const value: unknown = JSON.parse(raw);
      if (!value || typeof value !== 'object' || !('messageId' in value) || typeof value.messageId !== 'string' || !value.messageId ||
          !('target' in value) || typeof value.target !== 'string' || !('text' in value) || typeof value.text !== 'string') throw new Error('Invalid saved receipt');
      return { messageId: value.messageId, target: value.target, text: value.text };
    } catch { return { error: new Error('The saved agent-message intent could not be read. Reconcile prior messages before sending again; no message was replayed.') }; }
  });
  const identity = useQuery(`agent-identity:${bot.id}`, () => client.agentIdentity(bot.id));
  const [query, setQuery] = useState('');
  const roster = useQuery(`agents:${bot.id}:${query}`, () => client.agents(bot.id, { query, limit: 100 }));
  const [name, setName] = useState('');
  const [target, setTarget] = useState(saved.target ?? '');
  const [text, setText] = useState(saved.text ?? '');
  const [messageId, setMessageId] = useState<string | undefined>(saved.messageId);
  const reserved = useRef(!!saved.messageId);
  const [receipt, setReceipt] = useState<AgentMessageReceipt>();
  const rename = useIntent();
  const send = useAction();
  const status = useAction();
  const editable = online && bot.ownerUserId === snapshot.user.id && !saved.error;
  async function renameTo(value: string | null) {
    await rename.run(async () => {
      await client.renameAgent(bot.id, value, nonce());
      await identity.reload(); await roster.reload(); await refresh();
    });
  }
  async function submit() {
    if (!editable || reserved.current || send.busy) return;
    const id = nonce();
    await send.run(async () => {
      sessionStorage.setItem(storageKey, JSON.stringify({ messageId: id, target: target.trim(), text }));
      reserved.current = true; setMessageId(id);
      try { setReceipt(await client.messageAgent(bot.id, { clientNonce: id, target: target.trim(), text, conversationId })); }
      catch (error) {
        if (error instanceof LemonBotError && !error.outcomeUnknown) { sessionStorage.removeItem(storageKey); reserved.current = false; setMessageId(undefined); }
        throw error;
      }
    });
  }
  return <section className="panel stack" aria-label="Agent addressing">
    <h3>Agent handle</h3>
    <p>A handle addresses this existing Bot, not a new persona. Your display name stays unchanged.</p>
    {identity.loading && <Loading />}
    <ErrorNotice error={identity.error} />
    {identity.data && <><strong>{identity.data.agent.name ? `@${identity.data.agent.name}` : 'No handle set'}</strong><code className="preserve-lines">{identity.data.agent.id}</code></>}
    <form onSubmit={event => { event.preventDefault(); void renameTo(name.trim()); }}>
      <fieldset disabled={!editable || rename.disabled}><legend>Set a separate handle</legend>
        <Field label="Agent handle"><input value={name} onChange={event => setName(event.target.value)} placeholder="@bob" maxLength={65} pattern="@?[A-Za-z][A-Za-z0-9_-]{0,63}" required /></Field>
        <button>Set handle</button><button type="button" onClick={() => void renameTo(null)}>Clear handle</button>
      </fieldset>
    </form>
    <IntentNotice intent={rename} reconcile={identity.reload} />
    <details><summary>Reachable agents and messages</summary>
      <p>Only agents you may address are listed. Offline or unknown status does not mean idle.</p>
      <Field label="Find agent"><input type="search" value={query} onChange={event => setQuery(event.target.value)} /></Field>
      <button disabled={roster.loading} onClick={() => void roster.reload().catch(() => undefined)}>Refresh agents</button>
      <ErrorNotice error={roster.error} />
      {roster.loading && <Loading />}
      {roster.data?.agents.length === 0 && <p>No matching agents.</p>}
      <ul>{roster.data?.agents.map(agent => <li key={agent.id}><strong>{agent.name ? `@${agent.name}` : agent.label}</strong> · {agent.status ?? 'unknown'}<br/><code>{agent.id}</code><button disabled={!editable || !!messageId || agent.id === identity.data?.agent.id || agent.status === 'offline'} onClick={() => setTarget(agent.id)}>Address this agent</button></li>)}</ul>
      <form onSubmit={event => { event.preventDefault(); void submit(); }}>
        <fieldset disabled={!editable || !!messageId || send.busy}><legend>Message from {bot.name}</legend>
          <Field label="Target handle or stable ID"><input required value={target} onChange={event => setTarget(event.target.value)} /></Field>
          <Field label="Message to agent"><textarea required value={text} onChange={event => setText(event.target.value)} /></Field>
          <button disabled={!target.trim() || !text.trim()}>Send to agent</button>
        </fieldset>
      </form>
      <ErrorNotice error={send.error} /><ErrorNotice error={status.error} />
      <ErrorNotice error={saved.error} />
      {messageId && <div role="status"><p>Message ID: <code>{messageId}</code></p>
        <p>{receipt?.status === 'completed' ? 'Completed' : receipt?.status === 'failed' ? 'Failed' : receipt?.status === 'accepted' ? 'Accepted — waiting for an answer, not completed.' : 'Outcome unknown — do not resend. Check this message ID.'}</p>
        {receipt?.response && <p className="preserve-lines">{receipt.response}</p>}
        <button disabled={!online || status.busy} onClick={() => void status.run(async () => setReceipt(await client.agentMessage(bot.id, messageId)))}>Check message status</button>
        {(receipt?.status === 'completed' || receipt?.status === 'failed') && <button onClick={() => void status.run(async () => { sessionStorage.removeItem(storageKey); reserved.current = false; setMessageId(undefined); setReceipt(undefined); setText(''); })}>New message</button>}
      </div>}
    </details>
    <p className="small muted">In this Bot’s chat: <code>/agent-name bob</code>, <code>/agent-name --clear</code>, <code>/agents</code>, or <code>/tell @bob your message</code>. Replies return to the Bot’s conversation.</p>
  </section>;
}
