import { describe, expect, it } from 'vitest';
import {
  createNotification,
  createUiNotifyNotification,
  normalizeNotificationLevel,
} from './notificationHelpers';

describe('notificationHelpers', () => {
  it('creates normalized notification payloads', () => {
    expect(
      createNotification({
        idPrefix: 'error',
        message: 'Something failed',
        level: 'error',
        now: 123,
      })
    ).toEqual({
      id: 'error-123',
      message: 'Something failed',
      level: 'error',
      createdAt: 123,
    });
  });

  it('normalizes warning levels', () => {
    expect(normalizeNotificationLevel('warn')).toBe('warn');
    expect(normalizeNotificationLevel('warning')).toBe('warn');
    expect(normalizeNotificationLevel('success')).toBe('success');
    expect(normalizeNotificationLevel('error')).toBe('error');
    expect(normalizeNotificationLevel('anything-else')).toBe('info');
  });

  it('builds ui_notify notifications from params with fallback level', () => {
    expect(
      createUiNotifyNotification(
        {
          message: 'Hello',
          notify_type: 'warning',
        },
        500
      )
    ).toEqual({
      id: 'notify-500',
      message: 'Hello',
      level: 'warn',
      createdAt: 500,
    });

    expect(
      createUiNotifyNotification(
        {
          message: 'Hello',
          type: 'error',
        },
        501
      )
    ).toEqual({
      id: 'notify-501',
      message: 'Hello',
      level: 'error',
      createdAt: 501,
    });
  });
});
