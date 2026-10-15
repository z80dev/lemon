import { useSyncExternalStore } from 'react';

interface VoiceRequest { conversationId: string }
let requested: VoiceRequest | null = null;
const listeners = new Set<() => void>();
export function startLiveVoice(conversationId: string) { requested = { conversationId }; for (const listener of listeners) listener(); }
function subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; }
export function clearVoiceRequest() { requested = null; for (const listener of listeners) listener(); }
export function useVoiceRequest() { return useSyncExternalStore(subscribe, () => requested, () => null); }
