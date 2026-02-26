import type { WireServerMessage } from '@lemon-web/shared';
import type { LemonState } from './useLemonStore';
import { createUiNotifyNotification } from './notificationHelpers';

interface UiMessageRouteContext {
  state: LemonState;
  message: WireServerMessage;
  debugLog: WireServerMessage[];
  now: number;
}

export function routeUiMessage({
  state,
  message,
  debugLog,
  now,
}: UiMessageRouteContext): LemonState | null {
  if (message.type === 'ui_request') {
    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        requestsQueue: [...state.ui.requestsQueue, message],
      },
    };
  }

  if (message.type === 'ui_notify') {
    return {
      ...state,
      debugLog,
      notifications: [...state.notifications, createUiNotifyNotification(message.params, now)],
    };
  }

  if (message.type === 'ui_status') {
    const key = String(message.params.key ?? '');
    if (!key) {
      return { ...state, debugLog };
    }

    const status = { ...state.ui.status };
    if (message.params.text === null) {
      delete status[key];
    } else if (message.params.text !== undefined) {
      status[key] = String(message.params.text);
    }

    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        status,
      },
    };
  }

  if (message.type === 'ui_widget') {
    const key = String(message.params.key ?? '');
    if (!key) {
      return { ...state, debugLog };
    }

    if (message.params.content === null) {
      const widgets = { ...state.ui.widgets };
      delete widgets[key];

      return {
        ...state,
        debugLog,
        ui: {
          ...state.ui,
          widgets,
        },
      };
    }

    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        widgets: {
          ...state.ui.widgets,
          [key]: {
            key,
            content: message.params.content,
            opts: message.params.opts as Record<string, unknown> | undefined,
          },
        },
      },
    };
  }

  if (message.type === 'ui_working') {
    const rawMessage = message.params.message ?? null;
    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        workingMessage: rawMessage ? String(rawMessage) : null,
      },
    };
  }

  if (message.type === 'ui_set_title') {
    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        title: String(message.params.title ?? 'Lemon'),
      },
    };
  }

  if (message.type === 'ui_set_editor_text') {
    return {
      ...state,
      debugLog,
      ui: {
        ...state.ui,
        editorText: String(message.params.text ?? ''),
      },
    };
  }

  return null;
}
