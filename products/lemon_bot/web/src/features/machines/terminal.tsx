import { useEffect, useRef, useState } from 'react';
import { Terminal as Xterm } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { LemonBotError, nonce } from '@lemon-bot/sdk';
import type { Machine, Terminal } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, ErrorNotice, Field, useAction } from '../../ui';
import { IntentNotice, base64FromBytes, bytesFromBase64, useIntent } from './shared';
import '@xterm/xterm/css/xterm.css';

export function MachineTerminal({ machine, terminalId }: { machine: Machine; terminalId?: string }) {
  const { client, device, online, realtime, navigate, reportError } = useApp();
  const [terminal, setTerminal] = useState<Terminal>();
  const [cwd, setCwd] = useState('');
  const [accepted, setAccepted] = useState(false);
  const [cols, setCols] = useState(100);
  const [rows, setRows] = useState(30);
  const [gap, setGap] = useState<{ earliest: number; latest: number }>();
  const [disconnectedAt, setDisconnectedAt] = useState<number>();
  const [now, setNow] = useState(Date.now());
  const [notice, setNotice] = useState('');
  const [inputBusy, setInputBusy] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  const view = useRef<Xterm | null>(null);
  const fit = useRef<FitAddon | null>(null);
  const sequence = useRef(0);
  const inputPending = useRef(false);
  const intent = useIntent();
  const read = useAction();
  const active = useRef({ terminal, online, uncertain: intent.uncertain, gap });
  active.current = { terminal, online, uncertain: intent.uncertain, gap };
  const sendInput = useRef<(data: string) => void>(() => {});
  sendInput.current = data => {
    const current = active.current;
    if (!current.online || !current.terminal || current.terminal.state !== 'open' || current.uncertain || current.gap || inputPending.current) {
      setNotice('Input was not sent: terminal is disconnected, awaiting an acknowledgement, or requires reconciliation. Nothing is queued.');
      return;
    }
    inputPending.current = true; setInputBusy(true);
    void intent.run(async () => {
      const bytes = new TextEncoder().encode(data);
      for (let offset = 0; offset < bytes.length; offset += 65536) {
        if (!active.current.online || active.current.terminal?.state !== 'open') throw new Error('Connection changed. Remaining input was not sent and will not be replayed.');
        await client.call('POST /terminals/:id/input', { params: { id: current.terminal!.id }, body: { clientNonce: nonce(), dataBase64: base64FromBytes(bytes.subarray(offset, offset + 65536)) } });
      }
    }).finally(() => { inputPending.current = false; setInputBusy(false); });
  };
  useEffect(() => {
    if (!container.current) return;
    const term = new Xterm({ cursorBlink: !window.matchMedia('(prefers-reduced-motion: reduce)').matches, scrollback: 3000, screenReaderMode: true, convertEol: false, fontSize: 14, theme: { background: '#121723', foreground: '#e9edf4', cursor: '#f5d86a' } });
    const addon = new FitAddon(); term.loadAddon(addon); term.open(container.current); view.current = term; fit.current = addon;
    const input = term.onData(data => sendInput.current(data));
    const observer = new ResizeObserver(() => { addon.fit(); }); observer.observe(container.current); addon.fit();
    return () => { observer.disconnect(); input.dispose(); term.dispose(); view.current = null; fit.current = null; };
  }, []);
  useEffect(() => { if (view.current) view.current.options.disableStdin = !online || terminal?.state !== 'open' || intent.disabled || inputBusy || !!gap; }, [online, terminal?.state, intent.disabled, inputBusy, gap]);

  async function inspect(id = terminal?.id || terminalId) {
    if (!id && intent.error instanceof LemonBotError) {
      const resourceIds = intent.error.details?.resourceIds;
      if (Array.isArray(resourceIds)) id = resourceIds.find((value): value is string => typeof value === 'string');
    }
    if (!id) throw new Error('No acknowledged terminal ID was returned. Reconnect and inspect controller state before opening another shell; this unknown open remains fenced.');
    const result = await client.call('GET /terminals/:id', { params: { id } });
    if (result.machineId !== machine.id || result.deviceId !== device?.id) throw new Error('This shell does not belong to this host and registered device.');
    setTerminal(result);
    return result;
  }
  useEffect(() => { if (terminalId) void read.run(() => inspect(terminalId)); }, [terminalId, device?.id]);
  useEffect(() => {
    if (!terminal || terminal.state !== 'open') return;
    if (!online) setDisconnectedAt(previous => previous ?? Date.now());
    else setDisconnectedAt(undefined);
  }, [online, terminal?.id, terminal?.state]);
  useEffect(() => {
    if (!disconnectedAt) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [disconnectedAt]);
  useEffect(() => {
    if (!realtime) return;
    async function subscribe() {
      const current = active.current;
      if (!current.terminal || current.terminal.state !== 'open') return;
      try {
        const result = await inspect(current.terminal.id);
        if (result.state === 'open') realtime!.send({ type: 'terminal_subscribe', terminalId: result.id, afterSeq: sequence.current });
      } catch (error) { reportError(error); setNotice('Could not reattach shell. Reconcile its authoritative state; no input or resize was replayed.'); }
    }
    const unsubscribe = realtime.subscribe(frame => {
      if (frame.type === 'ready') { void subscribe(); return; }
      const current = active.current.terminal;
      if (!current || !('terminalId' in frame) || frame.terminalId !== current.id) return;
      if (frame.type === 'terminal_output') {
        if (frame.seq <= sequence.current) return;
        if (frame.seq !== sequence.current + 1) {
          setGap({ earliest: sequence.current + 1, latest: frame.seq });
          setNotice('Output sequence gap detected. Buffered output must be explicitly reconciled before input resumes.'); return;
        }
        try { view.current?.write(bytesFromBase64(frame.dataBase64)); sequence.current = frame.seq; }
        catch (error) { reportError(error); setGap({ earliest: frame.seq, latest: frame.seq }); }
      } else if (frame.type === 'terminal_gap') {
        setGap({ earliest: frame.earliestSeq, latest: frame.latestSeq });
        view.current?.writeln('\r\n[Output gap: some earlier terminal bytes are no longer retained.]\r\n');
      } else if (frame.type === 'terminal_exit') {
        setTerminal(previous => previous ? { ...previous, state: 'closed', exitCode: frame.code } : previous);
        setNotice(`Process exited${frame.code === null ? ' (exit code unavailable)' : ` with code ${frame.code}`}. This does not stop Bots.`);
      }
    });
    if (online && terminal?.state === 'open') void subscribe();
    return unsubscribe;
  }, [realtime, online, terminal?.id]);
  const grace = disconnectedAt ? Math.max(0, Math.min(60, 60 - Math.floor((now - disconnectedAt) / 1000))) : null;
  return <section className="panel stack"><div className="row spread"><h2>Full-access PTY</h2><Badge tone={terminal?.state === 'open' && online ? 'good' : 'warning'}>{terminal ? terminal.state === 'closed' ? 'Closed' : online ? 'Open' : 'Disconnected' : 'Not opened'}</Badge></div><p className="machine-warning">Commands execute as the destination OS user with its actual files and credentials. Only this user and registered opening device can reattach, input, resize or close this shell. Shell output is ephemeral and is never stored in workspace transcript/audit/push.</p><IntentNotice intent={intent} reconcile={async () => { await inspect(); setNotice('Authoritative shell state inspected. Input was not replayed.'); }} /><ErrorNotice error={read.error} />{!device && <p className="error-notice">A caller-owned registered browser device is required. Register this installation in the session before opening a terminal.</p>}{!terminal && <form className="stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => {
    if (!device || !realtime) throw new Error('A registered device and authenticated realtime connection are required.');
    const result = await client.call('POST /machines/:id/terminals', { params: { id: machine.id }, body: { clientNonce: nonce(), deviceId: device.id, ...(cwd ? { cwd } : {}), cols, rows } });
    sequence.current = 0; setGap(undefined); view.current?.reset(); setTerminal(result);
    navigate({ screen: 'machine.terminal', id: machine.id, entryId: result.id });
  }); }}><Field label="Destination working directory (optional)"><input value={cwd} onChange={event => setCwd(event.target.value)} placeholder="Host default cwd" /></Field><div className="row"><Field label="Columns"><input type="number" required min={20} max={500} value={cols} onChange={event => setCols(Number(event.target.value))} /></Field><Field label="Rows"><input type="number" required min={5} max={300} value={rows} onChange={event => setRows(Number(event.target.value))} /></Field></div><label className="row"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} />I understand this is a privileged host shell, not a sandbox.</label><button className="primary" disabled={!accepted || !device || !realtime || machine.status !== 'online' || intent.disabled || !!terminalId}>Open real host shell</button></form>}{terminal && <><p><code>{terminal.id}</code> · <code>{terminal.cwd}</code> · host PTY {terminal.cols} × {terminal.rows} · last correlated output sequence {sequence.current}</p><div className="row"><button disabled={read.busy || !online} onClick={() => void read.run(() => inspect())}>Inspect / reconcile shell</button><button disabled={intent.disabled || terminal.state !== 'open' || !!gap} onClick={() => void intent.run(async () => {
    fit.current?.fit(); const fittedCols = Math.max(20, Math.min(500, view.current?.cols || cols)); const fittedRows = Math.max(5, Math.min(300, view.current?.rows || rows));
    setTerminal(await client.call('POST /terminals/:id/resize', { params: { id: terminal.id }, body: { clientNonce: nonce(), cols: fittedCols, rows: fittedRows } }));
  })}>Fit PTY to view</button><button className="danger" disabled={intent.disabled || terminal.state !== 'open'} onClick={() => void intent.run(async () => { setTerminal(await client.call('DELETE /terminals/:id', { params: { id: terminal.id }, body: { clientNonce: nonce() } })); })}>Close shell</button></div></>}{grace !== null && <p role="status">Disconnected: {grace > 0 ? `${grace}s of the server’s 60-second reattach grace remain (server state is authoritative).` : 'Grace may have expired. GET the shell to check closure.'} Input and resize are disabled and never replayed.</p>}{gap && <aside className="error-notice" role="alert"><p>Output gap · available sequence {gap.earliest}–{gap.latest}. Earlier bytes may be permanently unavailable; do not infer missing command results.</p><button disabled={!online || !realtime || read.busy || terminal?.state !== 'open'} onClick={() => void read.run(async () => { const result = await inspect(); if (result.state !== 'open') return; sequence.current = Math.max(0, gap.earliest - 1); setGap(undefined); realtime!.send({ type: 'terminal_subscribe', terminalId: result.id, afterSeq: sequence.current }); })}>Explicitly resume available output buffer</button></aside>}{notice && <p role="status">{notice}</p>}{inputBusy && <p role="status">Awaiting input acknowledgement. Additional input is disabled, not queued.</p>}<div ref={container} className="machine-terminal" aria-label={`VT terminal for ${machine.name}`} /><p className="small muted">View size tracks its container; “Fit PTY to view” explicitly sends the server resize. Disconnect reconnects output only; commands/input/resize/close are never automatically replayed. Leaving this page detaches the viewer; close explicitly when finished.</p></section>;
}
