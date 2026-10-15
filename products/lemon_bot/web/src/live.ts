import type { Conversation, Draft, Run, TranscriptEntry, VoiceSession } from '@lemon-bot/sdk';
import { Brain, Calendar, FileText, Globe, Mail, Pencil, Send, Sparkles, SquareTerminal, Wrench, type LucideIcon } from 'lucide-react';

/** Shared live-work presentation, mirroring LivePresentation.swift so every client words work the same way. */
export const liveRunStatuses: Record<string, true> = { reserved: true, queued: true, running: true, awaiting_input: true };
/** Statuses the server still treats as active for Stop (includes unconfirmed outcomes). */
export const stoppableRunStatuses: Record<string, true> = { ...liveRunStatuses, outcome_unknown: true };
export const draftStateLabels: Record<Draft['state'], string> = { editable: 'Draft', sending: 'Sending…', sent: 'Sent', discarded: 'Discarded', failed: 'Not sent', outcome_unknown: 'Send status unknown' };
export const voiceStateLabels: Record<VoiceSession['state'], string> = { active: 'Call in progress', ended: 'Call ended', failed: 'Call interrupted' };

export interface LiveStep { title: string; tool?: string; sinceMs?: number; needsInput: boolean }

/** The current human-readable step for live work in a conversation, or undefined when idle. */
export function currentStep(runs: Run[], entries: TranscriptEntry[], conversation: Pick<Conversation, 'activity'> | undefined): LiveStep | undefined {
  const live = runs.filter(run => liveRunStatuses[run.status]);
  const phases = conversation?.activity ?? [];
  if (!live.length && !phases.length) return undefined;
  const runIds = new Set(live.map(run => run.id));
  const startedTimes = live.map(run => run.startedAtMs).filter((value): value is number => value !== null);
  const started = startedTimes.length ? Math.min(...startedTimes) : undefined;
  if (live.some(run => run.status === 'awaiting_input')) return { title: 'Waiting for you', sinceMs: started, needsInput: true };
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index];
    if (entry.kind === 'tool_call' && entry.status === 'started' && (entry.runId ? runIds.has(entry.runId) : runIds.size === 0)) return { title: entry.title || humanize(entry.tool), tool: entry.tool, sinceMs: entry.timestampMs, needsInput: false };
  }
  if (entries.some(entry => entry.kind === 'message' && entry.streaming)) return { title: 'Writing a reply', sinceMs: started, needsInput: false };
  const phase = phases[0]?.phase;
  if (phase) return { title: phase === 'reading' ? 'Reading' : phase === 'typing' ? 'Writing a reply' : 'Working', sinceMs: started, needsInput: false };
  if (live.every(run => run.status === 'reserved' || run.status === 'queued')) return { title: 'Queued', needsInput: false };
  return { title: 'Thinking', sinceMs: started, needsInput: false };
}

export function humanize(value: string) { const text = value.replaceAll(/[_.-]+/g, ' ').trim(); return text ? text[0].toUpperCase() + text.slice(1) : 'Working'; }

/** Icon for a tool name in compact step rows. */
export function toolIcon(tool: string): LucideIcon {
  const t = tool.toLowerCase();
  if (/search|web|browse/.test(t)) return Globe;
  if (/read|file|open/.test(t)) return FileText;
  if (/write|edit|patch/.test(t)) return Pencil;
  if (/bash|shell|exec|terminal|command/.test(t)) return SquareTerminal;
  if (/mail/.test(t)) return Mail;
  if (/calendar/.test(t)) return Calendar;
  if (/memory/.test(t)) return Brain;
  if (/message|slack|send/.test(t)) return Send;
  if (/think|plan/.test(t)) return Sparkles;
  return Wrench;
}

/** Compact relative duration: "4s", "2m", "1h 5m". */
export function compactDuration(fromMs: number, toMs = Date.now()) {
  const seconds = Math.max(0, Math.round((toMs - fromMs) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** Date separator: "Today 7:22 PM", "Yesterday 8:05 PM", "Sun, Aug 30 11:11 AM", "Aug 30, 2025 11:11 AM". */
export function separatorDate(ms: number, now = Date.now()) {
  const date = new Date(ms), today = new Date(now), yesterday = new Date(now - 86400000);
  const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(date);
  if (date.toDateString() === today.toDateString()) return `Today ${time}`;
  if (date.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;
  if (date.getFullYear() !== today.getFullYear()) return `${new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric' }).format(date)} ${time}`;
  return `${new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).format(date)} ${time}`;
}

/** Relative "x ago" for inspector meta lines. */
export function relativeTime(ms: number, now = Date.now()) {
  const seconds = Math.round((now - ms) / 1000);
  if (seconds < 45) return 'just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  const days = Math.round(hours / 24);
  return days < 7 ? `${days} day${days === 1 ? '' : 's'} ago` : new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(new Date(ms));
}

/** Markdown → one plain line ("**Done** — `x`" → "Done — x"). */
export function plainLine(markdown: string) {
  return markdown.split('\n').map(line => line.replace(/^\s*(?:[#>]+|[-*+]|\d+[.)])\s+/, '')).filter(line => line.trim() && !line.startsWith('```')).join(' ')
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/(\*\*|__|\*|_|~~|`)/g, '').trim();
}

/** One-line last-message preview for a sidebar row (SidebarPreview in Swift). */
export function previewText(entry: TranscriptEntry): string | undefined {
  switch (entry.kind) {
    case 'message': {
      const body = plainLine(entry.text);
      if (!body && !entry.attachmentIds.length) return entry.role === 'user' || entry.streaming ? undefined : 'Couldn’t finish the last request';
      const content = body || 'Sent an attachment';
      return entry.role === 'user' ? `You: ${content}` : content;
    }
    case 'user_attachment': return 'You: Sent an attachment';
    case 'card': return 'Needs a look';
    case 'voice_call': return 'Voice chat';
    case 'notice': return entry.text;
    default: return undefined;
  }
}
