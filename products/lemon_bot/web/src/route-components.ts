import { lazy } from 'react';

// Keep feature implementations out of the shell and load only the destination in use.
export const BotsScreen = lazy(() => import('./features/bots').then(module => ({ default: module.BotsScreen })));
export const ConversationScreen = lazy(() => import('./features/chat').then(module => ({ default: module.ConversationScreen })));
export const FileViewer = lazy(() => import('./features/chat').then(module => ({ default: module.FileViewer })));
export const MachinesScreen = lazy(() => import('./features/machines').then(module => ({ default: module.MachinesScreen })));
export const WorkScreen = lazy(() => import('./features/work').then(module => ({ default: module.WorkScreen })));
export const SettingsScreen = lazy(() => import('./features/settings').then(module => ({ default: module.SettingsScreen })));
export const OwnerControlsScreen = lazy(() => import('./features/enterprise').then(module => ({ default: module.OwnerControlsScreen })));
export const PairingScreen = lazy(() => import('./features/pairing').then(module => ({ default: module.PairingScreen })));
