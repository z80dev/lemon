import { useState } from 'react';
import { type UsageQuery } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Loading, Field, formatTime } from '../../ui';
import { money } from './shared';

const day = 86400000;
export function UsageSettings() {
  const { client, snapshot, navigate, reportError } = useApp();
  const [query, setQuery] = useState<UsageQuery>(() => {
    const now = new Date();
    const toAtMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
    return { fromAtMs: toAtMs - 30 * day, toAtMs, groupBy: 'bot' };
  });
  const [from, setFrom] = useState(() => new Date(query.fromAtMs).toISOString().slice(0, 10));
  const [to, setTo] = useState(() => new Date(query.toAtMs).toISOString().slice(0, 10));
  const [groupBy, setGroupBy] = useState<NonNullable<UsageQuery['groupBy']>>('bot');
  const [botId, setBotId] = useState(''); const [routineId, setRoutineId] = useState(''); const [invalid, setInvalid] = useState('');
  const report = useQuery(`settings:usage:${JSON.stringify(query)}`, () => client.call('GET /usage', { query }));
  const labels: Record<NonNullable<UsageQuery['groupBy']>, string> = { bot: 'Bot', routine: 'Routine', user: 'User', day: 'Day', source: 'Source' };
  const buckets = report.data?.buckets;
  const maxTokens = buckets ? Math.max(1, ...buckets.map(bucket => bucket.inputTokens + bucket.outputTokens)) : 1;
  const maxCost = buckets ? Math.max(0.000001, ...buckets.flatMap(bucket => bucket.costUsd === null ? [] : [bucket.costUsd])) : 1;
  return <div className="stack">
    <section className="panel stack">
      <h2>Actual provider usage</h2>
      <p className="muted">Your workspace usage · Routines and tests, group work and Bot handoffs count toward their recorded initiating user/routine. No Lemon subscription or billing plan is sold here.</p>
      <form className="stack" onSubmit={e => {
        e.preventDefault();
        const fromAtMs = Date.parse(`${from}T00:00:00Z`); const toAtMs = Date.parse(`${to}T00:00:00Z`);
        if (!Number.isFinite(fromAtMs) || !Number.isFinite(toAtMs) || toAtMs <= fromAtMs || toAtMs - fromAtMs > 366 * day) {
          setInvalid('Choose a positive UTC date range no longer than 366 days. End is exclusive.'); return;
        }
        setInvalid(''); setQuery({ fromAtMs, toAtMs, groupBy, ...(botId ? { botId } : {}), ...(routineId ? { routineId } : {}) });
      }}>
        <div className="grid">
          <Field label="From (UTC, inclusive)"><input type="date" required value={from} onChange={e => setFrom(e.target.value)} /></Field>
          <Field label="To (UTC, exclusive)"><input type="date" required value={to} onChange={e => setTo(e.target.value)} /></Field>
          <Field label="Group by"><select value={groupBy} onChange={e => setGroupBy(e.target.value as NonNullable<UsageQuery['groupBy']>)}>{(Object.keys(labels) as NonNullable<UsageQuery['groupBy']>[]).map(key => <option value={key} key={key}>{labels[key]}</option>)}</select></Field>
          <Field label="Bot"><select value={botId} onChange={e => setBotId(e.target.value)}><option value="">All authorized Bots</option>{snapshot.bots.map(bot => <option key={bot.id} value={bot.id}>{bot.name}</option>)}</select></Field>
          <Field label="Routine ID (optional)" hint="Filter an exact routine, including one outside the current Bot selection."><input value={routineId} onChange={e => setRoutineId(e.target.value)} /></Field>
        </div>
        {invalid && <p role="alert">{invalid}</p>}
        <div className="row">
          <button className="primary">Apply range & grouping</button>
          <button type="button" disabled={report.loading} onClick={() => void report.reload().catch(reportError)}>Refresh from provider</button>
          <button type="button" onClick={() => navigate({ screen: 'settings.usage.limit' })}>Spend ceilings & status</button>
        </div>
      </form>
    </section>
    <ErrorNotice error={report.error} />{report.loading && <Loading />}
    {report.data && <>
      <section className="panel stack">
        <h2>Summary</h2><p className="small muted">{formatTime(report.data.fromAtMs)} through {formatTime(report.data.toAtMs)} (exclusive)</p>
        {report.data.incomplete && <p role="alert" className="error-notice">Incomplete provider data or pricing. These are measured partial totals, not a zero-cost guarantee.</p>}
        <div className="grid settings-metrics">
          <article className="card"><span className="muted">Input tokens</span><strong>{report.data.totals.inputTokens.toLocaleString()}</strong></article>
          <article className="card"><span className="muted">Output tokens</span><strong>{report.data.totals.outputTokens.toLocaleString()}</strong></article>
          <article className="card"><span className="muted">Requests</span><strong>{report.data.totals.requests.toLocaleString()}</strong></article>
          <article className="card"><span className="muted">Measured cost</span><strong>{money(report.data.totals.costUsd)}</strong></article>
        </div>
        <p className="muted small">Pricing source: {report.data.pricingSource ?? 'Not available — unknown prices remain unknown'}. External provider billing is authoritative; already admitted work may continue after a ceiling.</p>
      </section>
      <section className="panel stack">
        <h2>Tokens by {labels[query.groupBy ?? 'bot'].toLowerCase()}</h2>
        <figure className="settings-bars" aria-label={`Token usage grouped by ${query.groupBy ?? 'bot'}`}>
          <figcaption className="muted small">Input + output tokens; exact values are available in the table below.</figcaption>
          {buckets?.map(bucket => <div key={bucket.key} className="settings-bar-row"><span>{query.groupBy === 'bot' ? snapshot.bots.find(bot => bot.id === bucket.key)?.name ?? bucket.key : bucket.key}</span><meter min={0} max={maxTokens} value={bucket.inputTokens + bucket.outputTokens}>{bucket.inputTokens + bucket.outputTokens}</meter><span>{(bucket.inputTokens + bucket.outputTokens).toLocaleString()}</span></div>)}
        </figure>
        <h3>Measured costs</h3>
        <figure className="settings-bars" aria-label={`Measured costs grouped by ${query.groupBy ?? 'bot'}`}>
          <figcaption className="muted small">Unknown prices have no fabricated bar and are not treated as zero.</figcaption>
          {buckets?.map(bucket => <div key={bucket.key} className="settings-bar-row"><span>{query.groupBy === 'bot' ? snapshot.bots.find(bot => bot.id === bucket.key)?.name ?? bucket.key : bucket.key}</span>{bucket.costUsd === null ? <span className="muted">Price unavailable</span> : <meter min={0} max={maxCost} value={bucket.costUsd}>{money(bucket.costUsd)}</meter>}<span>{money(bucket.costUsd)}</span></div>)}
        </figure>
        <div className="table-wrap"><table>
          <caption>Actual usage buckets; unknown costs are not treated as zero.</caption>
          <thead><tr><th scope="col">{labels[query.groupBy ?? 'bot']}</th><th scope="col">Input tokens</th><th scope="col">Output tokens</th><th scope="col">Requests</th><th scope="col">Cost (USD)</th></tr></thead>
          <tbody>{buckets?.map(bucket => <tr key={bucket.key}><th scope="row">{query.groupBy === 'bot' ? snapshot.bots.find(bot => bot.id === bucket.key)?.name ?? bucket.key : bucket.key}</th><td>{bucket.inputTokens.toLocaleString()}</td><td>{bucket.outputTokens.toLocaleString()}</td><td>{bucket.requests.toLocaleString()}</td><td>{money(bucket.costUsd)}</td></tr>)}</tbody>
        </table></div>
        {buckets?.length === 0 && <p>No measured usage in this range. This is a successful empty report, not an offline fallback.</p>}
      </section>
    </>}
  </div>;
}
