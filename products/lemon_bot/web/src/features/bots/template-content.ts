import type { JSONValue, RoutineTrigger, TemplateContent } from '@lemon-bot/sdk';

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function json(value: unknown): value is JSONValue { return value === null || typeof value === 'string' || typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value)) || (Array.isArray(value) ? value.every(json) : object(value) && Object.values(value).every(json)); }
function trigger(value: unknown): value is RoutineTrigger {
  if (!object(value)) return false;
  switch (value.kind) {
    case 'schedule': return typeof value.cron === 'string' && typeof value.timezone === 'string' && Object.keys(value).every(key => ['kind', 'cron', 'timezone'].includes(key));
    case 'webhook': return Object.keys(value).length === 1;
    case 'external_event': return ['github', 'linear', 'sentry', 'pagerduty'].includes(String(value.source)) && Array.isArray(value.eventNames) && value.eventNames.every(item => typeof item === 'string') && object(value.filters) && json(value.filters) && Object.keys(value).every(key => ['kind', 'source', 'eventNames', 'filters'].includes(key));
    case 'channel_event': return typeof value.channelBindingId === 'string' && ['mention', 'message', 'reaction', 'email_received'].includes(String(value.event)) && ['channel', 'phrase', 'reaction'].every(key => value[key] === undefined || typeof value[key] === 'string') && (value.senders === undefined || (Array.isArray(value.senders) && value.senders.every(item => typeof item === 'string'))) && Object.keys(value).every(key => ['kind', 'channelBindingId', 'event', 'channel', 'phrase', 'reaction', 'senders'].includes(key));
    default: return false;
  }
}
export function parseTemplate(text: string): TemplateContent {
  const value: unknown = JSON.parse(text);
  if (!isTemplateContent(value)) throw new Error('This file is not canonical TemplateContent. Export a Bot template, not a Bot resource, history or credentials.');
  return value;
}
function isTemplateContent(value: unknown): value is TemplateContent {
  if (!object(value) || !Object.keys(value).every(key => ['name', 'title', 'job', 'instructions', 'avatar', 'voice', 'skills', 'routines', 'connectorNames'].includes(key))) return false;
  if (!['name', 'title', 'job', 'instructions'].every(key => typeof value[key] === 'string')) return false;
  const avatar = value.avatar; const voice = value.voice;
  if (!object(avatar) || !['character', 'image'].includes(String(avatar.kind)) || typeof avatar.shape !== 'string' || typeof avatar.color !== 'string' || !(avatar.attachmentId === null || typeof avatar.attachmentId === 'string') || !Object.keys(avatar).every(key => ['kind', 'shape', 'color', 'attachmentId'].includes(key))) return false;
  if (!object(voice) || typeof voice.voiceId !== 'string' || typeof voice.speed !== 'number' || voice.speed < 0.5 || voice.speed > 2 || !(voice.language === null || typeof voice.language === 'string') || !Object.keys(voice).every(key => ['voiceId', 'speed', 'language'].includes(key))) return false;
  return Array.isArray(value.skills) && value.skills.every(skill => object(skill) && ['name', 'description', 'markdown'].every(key => typeof skill[key] === 'string') && Object.keys(skill).every(key => ['name', 'description', 'markdown'].includes(key))) && Array.isArray(value.routines) && value.routines.every(routine => object(routine) && typeof routine.name === 'string' && typeof routine.instruction === 'string' && typeof routine.enabled === 'boolean' && trigger(routine.trigger) && Object.keys(routine).every(key => ['name', 'instruction', 'trigger', 'enabled'].includes(key))) && Array.isArray(value.connectorNames) && value.connectorNames.every(name => typeof name === 'string');
}

export function parseFilter(text: string): JSONValue {
  const value: unknown = JSON.parse(text);
  if (!json(value)) throw new Error('Filter must be a JSON value.');
  return value;
}
