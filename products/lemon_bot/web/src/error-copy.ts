import { LemonBotError } from '@lemon-bot/sdk';

const errorMessages: Record<string, string> = {
  unauthenticated: 'Your session ended. Sign in again.',
  forbidden: 'You don’t have permission to do this. Ask your workspace owner for help.',
  not_found: 'This item is no longer available. Refresh to check the current list.',
  invalid_request: 'Some details need attention. Review what you entered and try again.',
  revision_conflict: 'This changed on another device. Refresh before editing again.',
  conflict: 'This can’t be changed right now. Refresh to check its current status.',
  expired: 'This request expired. Start again to get a new one.',
  rate_limited: 'Too many requests. Wait a moment, then try again.',
  capability_unavailable: 'This feature isn’t available on this server. Ask your administrator for help.',
  machine_offline: 'This computer is offline. Connect it before trying again.',
  upstream_unavailable: 'The service couldn’t be reached. Check your connection and try again.',
  policy_denied: 'Your current permissions don’t allow this action. Ask your workspace owner for help.',
  confirmation_required: 'Review and confirm this action before continuing.',
  outcome_unknown: 'We couldn’t confirm this went through. Check its current status before trying again so you don’t duplicate it.',
};
export function errorSummary(error: unknown): string {
  if (!(error instanceof LemonBotError)) return 'This couldn’t finish. Check your connection and review Details before trying again.';
  if (error.outcomeUnknown) return errorMessages.outcome_unknown;
  return errorMessages[error.code] ?? 'This request couldn’t finish. Review Details, then refresh and try again.';
}
