import { lazy, Suspense, useState } from 'react';
import { useApp } from '../../app';
import { useVoiceRequest } from './voice-request';
import { ScreenBoundary } from '../../ui';

const Overlay = lazy(() => import('./voice').then(module => ({ default: module.VoiceOverlay })));

export function VoiceOverlay() {
  const { snapshot } = useApp();
  const request = useVoiceRequest();
  const [loaded, setLoaded] = useState(() => !!sessionStorage.getItem(`lemonbot.voiceSession:${snapshot.workspace.id}:${snapshot.user.id}`));
  // Once requested, preserve the call across navigation even after its request clears.
  if (request && !loaded) setLoaded(true);
  return loaded || request ? <ScreenBoundary><Suspense fallback={null}><Overlay/></Suspense></ScreenBoundary> : null;
}
