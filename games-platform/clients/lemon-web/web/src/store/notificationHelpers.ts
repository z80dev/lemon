import type { Notification } from './useLemonStore';

interface CreateNotificationParams {
  idPrefix: string;
  message: string;
  level: Notification['level'];
  now: number;
}

export function createNotification({
  idPrefix,
  message,
  level,
  now,
}: CreateNotificationParams): Notification {
  return {
    id: `${idPrefix}-${now}`,
    message,
    level,
    createdAt: now,
  };
}

export function normalizeNotificationLevel(level: string): Notification['level'] {
  switch (level) {
    case 'success':
      return 'success';
    case 'warn':
    case 'warning':
      return 'warn';
    case 'error':
      return 'error';
    default:
      return 'info';
  }
}

export function createUiNotifyNotification(
  params: Record<string, unknown>,
  now: number
): Notification {
  const noteType = params.notify_type;
  const fallbackType = params.type;
  const rawLevel =
    (typeof noteType === 'string' ? noteType : undefined) ||
    (typeof fallbackType === 'string' ? fallbackType : 'info');

  return createNotification({
    idPrefix: 'notify',
    message: String(params.message ?? ''),
    level: normalizeNotificationLevel(rawLevel),
    now,
  });
}
