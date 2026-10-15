import { type ControlPlaneMethods, METHOD } from "../protocol/methods.ts";
import type { AppStore } from "./app-store.ts";

/** Read-only and optional: older or unavailable daemons never add error notices. */
export async function refreshSetupStatus(
	store: AppStore,
	methods: ControlPlaneMethods,
): Promise<void> {
	try {
		store.setupStatus = methods.supports(METHOD.setupStatus)
			? await methods.setupStatus({ queueIfOffline: false })
			: undefined;
	} catch {
		store.setupStatus = undefined;
	}
	store.events.emit("setup-changed", undefined);
}
