/**
 * OverlayManager - handles UI overlay display and interaction.
 * Extracted from LemonTUI to improve modularity.
 */

import {
  TUI,
  Text,
  Editor,
  Input,
  Container,
  SelectList,
  SettingsList,
  matchesKey,
  type SettingItem,
  type SelectItem,
} from '@mariozechner/pi-tui';
import { AgentConnection } from './agent-connection.js';
import { StateStore } from './state.js';
import type {
  UIRequestMessage,
  SelectParams,
  ConfirmParams,
  InputParams,
  EditorParams,
} from './types.js';
import { saveTUIConfigKey } from './config.js';
import { ansi, setTheme, getThemeName, getAvailableThemes } from './theme.js';
import { selectListTheme, editorTheme, getSettingsListTheme } from './component-themes.js';
import { BorderBox } from './components/border-box.js';
import { RecentPathAutocompleteProvider } from './autocomplete.js';

/**
 * Callbacks for OverlayManager to communicate state changes back to LemonTUI.
 */
export interface OverlayManagerCallbacks {
  /** Get the current overlay handle */
  getOverlayHandle: () => { hide: () => void } | null;
  /** Set the current overlay handle */
  setOverlayHandle: (handle: { hide: () => void } | null) => void;
  /** Get the current overlay request ID */
  getCurrentOverlayRequestId: () => string | null;
  /** Set the current overlay request ID */
  setCurrentOverlayRequestId: (id: string | null) => void;
  /** Get the input editor component for focus restoration */
  getInputEditor: () => { handleInput?: (data: string) => void } | null;
  /** Get the sessions list component for focus restoration */
  getSessionsList: () => SelectList | null;
  /** Called when an overlay is hidden and focus should be restored */
  onOverlayHidden: () => void;
}

/**
 * OverlayManager handles the display and interaction of overlay dialogs.
 * This includes server-requested UI overlays (select, confirm, input, editor)
 * as well as local overlays (settings, session selection, etc.).
 */
export class OverlayManager {
  private tui: TUI;
  private store: StateStore;
  private connection: AgentConnection;
  private callbacks: OverlayManagerCallbacks;

  constructor(
    tui: TUI,
    store: StateStore,
    connection: AgentConnection,
    callbacks: OverlayManagerCallbacks
  ) {
    this.tui = tui;
    this.store = store;
    this.connection = connection;
    this.callbacks = callbacks;
  }

  // ============================================================================
  // Server-requested UI Overlays
  // ============================================================================

  /**
   * Shows an overlay based on a UI request from the server.
   */
  showUIOverlay(request: UIRequestMessage): void {
    this.callbacks.setCurrentOverlayRequestId(request.id);

    switch (request.method) {
      case 'select':
        this.showSelectOverlay(request.id, request.params as SelectParams);
        break;

      case 'confirm':
        this.showConfirmOverlay(request.id, request.params as ConfirmParams);
        break;

      case 'input':
        this.showInputOverlay(request.id, request.params as InputParams);
        break;

      case 'editor':
        this.showEditorOverlay(request.id, request.params as EditorParams);
        break;
    }
  }

  /**
   * Shows a select list overlay for server requests.
   */
  showSelectOverlay(id: string, params: SelectParams): void {
    const items: SelectItem[] = params.options.map((opt) => ({
      label: opt.label,
      value: opt.value,
      description: opt.description || undefined,
    }));

    const titleText = new Text(ansi.bold(params.title), 1, 0);
    const selectList = new SelectList(items, Math.min(10, items.length), selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      this.connection.respondToUIRequest(id, item.value);
      this.hideOverlay();
    };

    selectList.onCancel = () => {
      this.connection.respondToUIRequest(id, null);
      this.hideOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    const handle = this.tui.showOverlay(box, {
      width: '80%',
      maxHeight: '50%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(selectList);
  }

  /**
   * Shows a confirmation dialog overlay for server requests.
   */
  showConfirmOverlay(id: string, params: ConfirmParams): void {
    const items: SelectItem[] = [
      { label: 'Yes', value: 'yes', description: 'Confirm' },
      { label: 'No', value: 'no', description: 'Cancel' },
    ];

    const header = new Text(`${ansi.bold(params.title)}\n${params.message}`, 1, 1);
    const selectList = new SelectList(items, 2, selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      this.connection.respondToUIRequest(id, item.value === 'yes');
      this.hideOverlay();
    };

    selectList.onCancel = () => {
      this.connection.respondToUIRequest(id, false);
      this.hideOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    const handle = this.tui.showOverlay(box, {
      width: 60,
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(selectList);
  }

  /**
   * Shows an input overlay for server requests.
   */
  showInputOverlay(id: string, params: InputParams): void {
    const header = new Text(ansi.bold(params.title), 1, 0);
    const input = new Input();

    // Note: pi-tui Input doesn't support placeholder, but we show it in the header
    if (params.placeholder) {
      header.setText(`${ansi.bold(params.title)}\n${ansi.muted(params.placeholder)}`);
    }

    input.onSubmit = (text: string) => {
      this.connection.respondToUIRequest(id, text);
      this.hideOverlay();
    };

    input.onEscape = () => {
      this.connection.respondToUIRequest(id, null);
      this.hideOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(input);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    const handle = this.tui.showOverlay(box, {
      width: '80%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(input);
  }

  /**
   * Shows an editor overlay for server requests.
   */
  showEditorOverlay(id: string, params: EditorParams): void {
    const header = new Text(
      `${ansi.bold(params.title)}\n${ansi.muted('Enter to submit, Shift+Enter for newline, Escape to cancel')}`,
      1,
      0
    );
    const editorOverlay = new Editor(this.tui, editorTheme);

    if (params.prefill) {
      editorOverlay.setText(params.prefill);
    }

    editorOverlay.onSubmit = (text: string) => {
      this.connection.respondToUIRequest(id, text);
      this.hideOverlay();
    };

    // Store original handleInput for escape handling using matchesKey
    const originalHandleInput = editorOverlay.handleInput?.bind(editorOverlay);
    editorOverlay.handleInput = (data: string) => {
      if (matchesKey(data, 'escape')) {
        this.connection.respondToUIRequest(id, null);
        this.hideOverlay();
        return;
      }
      originalHandleInput?.(data);
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(editorOverlay);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    const handle = this.tui.showOverlay(box, {
      width: '90%',
      maxHeight: '80%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(editorOverlay);
  }

  /**
   * Hides the current server-requested overlay and processes the queue.
   */
  hideOverlay(): void {
    const overlayHandle = this.callbacks.getOverlayHandle();
    if (overlayHandle) {
      overlayHandle.hide();
      this.callbacks.setOverlayHandle(null);
    }
    this.callbacks.setCurrentOverlayRequestId(null);

    // Dequeue the current request
    this.store.dequeueUIRequest();

    // Let the caller know to check for next overlay
    this.callbacks.onOverlayHidden();
  }

  // ============================================================================
  // Local Overlays (not server-requested)
  // ============================================================================

  /**
   * Shows a local select overlay (not server-requested).
   */
  showLocalSelectOverlay(
    title: string,
    items: SelectItem[],
    onSelect: (item: SelectItem) => void
  ): void {
    if (this.callbacks.getOverlayHandle()) {
      return;
    }

    const titleText = new Text(ansi.bold(title), 1, 0);
    const selectList = new SelectList(items, Math.min(10, items.length), selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      onSelect(item);
      this.hideLocalOverlay();
    };

    selectList.onCancel = () => {
      this.hideLocalOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.callbacks.setCurrentOverlayRequestId('__local__');
    const handle = this.tui.showOverlay(box, {
      width: '80%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(selectList);
  }

  /**
   * Shows a local input overlay (not server-requested).
   */
  showLocalInputOverlay(
    title: string,
    prefill: string,
    onSubmit: (value: string) => void
  ): void {
    if (this.callbacks.getOverlayHandle()) {
      return;
    }

    const header = new Text(ansi.bold(title), 1, 0);
    const input = new Input();

    if (prefill) {
      input.setValue(prefill);
    }

    input.onSubmit = (text: string) => {
      this.hideLocalOverlay();
      onSubmit(text);
    };

    input.onEscape = () => {
      this.hideLocalOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(input);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.callbacks.setCurrentOverlayRequestId('__local__');
    const handle = this.tui.showOverlay(box, {
      width: '80%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(input);
  }

  /**
   * Shows a local path input overlay with autocomplete support.
   */
  showLocalPathInputOverlay(
    title: string,
    prefill: string,
    recentDirectories: string[],
    onSubmit: (value: string) => void
  ): void {
    if (this.callbacks.getOverlayHandle()) {
      return;
    }

    const header = new Text(
      `${ansi.bold(title)}\n${ansi.muted('Enter to submit, Esc to cancel')}`,
      1,
      0
    );
    const editor = new Editor(this.tui, editorTheme);

    if (prefill) {
      editor.setText(prefill);
    }

    const basePath = this.store.getState().cwd || process.cwd();
    editor.setAutocompleteProvider(
      new RecentPathAutocompleteProvider(basePath, recentDirectories)
    );

    editor.onSubmit = (text: string) => {
      this.hideLocalOverlay();
      onSubmit(text.trim());
    };

    const originalHandleInput = editor.handleInput?.bind(editor);
    editor.handleInput = (data: string) => {
      if (matchesKey(data, 'escape')) {
        this.hideLocalOverlay();
        return;
      }
      originalHandleInput?.(data);
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(editor);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.callbacks.setCurrentOverlayRequestId('__local__');
    const handle = this.tui.showOverlay(box, {
      width: '90%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(editor);
  }

  /**
   * Hides a local overlay and restores focus appropriately.
   */
  hideLocalOverlay(): void {
    const overlayHandle = this.callbacks.getOverlayHandle();
    if (overlayHandle) {
      overlayHandle.hide();
      this.callbacks.setOverlayHandle(null);
    }
    this.callbacks.setCurrentOverlayRequestId(null);

    const currentRequest = this.store.getCurrentUIRequest();
    if (currentRequest) {
      this.showUIOverlay(currentRequest);
    } else {
      const state = this.store.getState();
      const sessionsList = this.callbacks.getSessionsList();
      const inputEditor = this.callbacks.getInputEditor();

      if (!state.activeSessionId && sessionsList) {
        this.tui.setFocus(sessionsList);
      } else if (inputEditor) {
        this.tui.setFocus(inputEditor as any);
      }
    }
  }

  // ============================================================================
  // Settings Overlay
  // ============================================================================

  /**
   * Shows the settings overlay.
   */
  showSettingsOverlay(): void {
    const state = this.store.getState();

    // Get available themes and format them for display (capitalize first letter)
    const availableThemeNames = getAvailableThemes();
    const formatThemeName = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);
    const themeValues = availableThemeNames.map(formatThemeName);

    const items: SettingItem[] = [
      {
        id: 'debug',
        label: 'Debug Mode',
        description: 'Enable debug logging and diagnostics',
        currentValue: state.debug ? 'On' : 'Off',
        values: ['On', 'Off'],
      },
      {
        id: 'theme',
        label: 'Theme',
        description: 'Color theme for the TUI',
        currentValue: formatThemeName(getThemeName()),
        values: themeValues,
      },
      {
        id: 'model',
        label: 'Model',
        description: 'Current AI model provider and ID',
        currentValue: state.ready ? `${state.model.provider}:${state.model.id}` : 'Not connected',
      },
      {
        id: 'cwd',
        label: 'Working Directory',
        description: 'Current working directory for the agent',
        currentValue: state.cwd || process.cwd(),
      },
    ];

    const titleText = new Text(ansi.bold('Settings'), 1, 0);
    const settingsList = new SettingsList(
      items,
      Math.min(10, items.length + 2),
      getSettingsListTheme(),
      (id: string, newValue: string) => {
        // Handle setting changes
        if (id === 'debug') {
          const debugEnabled = newValue === 'On';
          this.store.setDebug(debugEnabled);
          settingsList.updateValue('debug', debugEnabled ? 'On' : 'Off');
          saveTUIConfigKey('debug', debugEnabled);  // Persist to config file
        } else if (id === 'theme') {
          // Convert display name back to theme key (lowercase)
          const themeName = newValue.toLowerCase();
          if (setTheme(themeName)) {
            settingsList.updateValue('theme', newValue);
            // Request a full re-render to apply the new theme
            this.tui.requestRender();
            saveTUIConfigKey('theme', themeName);  // Persist to config file
          }
        }
        // Other settings are info-only for now
      },
      () => {
        // onCancel
        this.hideSettingsOverlay();
      }
    );

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(settingsList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    const handle = this.tui.showOverlay(box, {
      width: '80%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.callbacks.setOverlayHandle(handle);
    this.tui.setFocus(settingsList);
  }

  /**
   * Hides the settings overlay.
   */
  hideSettingsOverlay(): void {
    const overlayHandle = this.callbacks.getOverlayHandle();
    if (overlayHandle) {
      overlayHandle.hide();
      this.callbacks.setOverlayHandle(null);
    }
    const inputEditor = this.callbacks.getInputEditor();
    if (inputEditor) {
      this.tui.setFocus(inputEditor as any);
    }
  }

  // ============================================================================
  // Utility Methods
  // ============================================================================

  /**
   * Returns true if an overlay is currently visible.
   */
  isOverlayVisible(): boolean {
    return this.callbacks.getOverlayHandle() !== null;
  }

  /**
   * Returns the current overlay request ID.
   */
  getCurrentRequestId(): string | null {
    return this.callbacks.getCurrentOverlayRequestId();
  }
}
