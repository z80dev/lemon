/**
 * The command set, in `/help` order.
 *
 * `makeEditorCommand` is the one command that needs a host callback at
 * construction time (the $EDITOR handoff owns the terminal), so the registry is
 * built by a function rather than exported as a constant.
 */

import { approvalsCommand, approveCommand, denyCommand } from "./approvals.ts";
import {
	clearCommand,
	debugCommand,
	helpCommand,
	makeEditorCommand,
	modeCommand,
	quitCommand,
	reconnectCommand,
	themeCommand,
} from "./core.ts";
import { costCommand, logsCommand, statusCommand, usageCommand } from "./diagnostics.ts";
import {
	agentsCommand,
	backgroundCommand,
	btwCommand,
	commandsCommand,
	compressCommand,
	heartbeatCommand,
	tasksCommand,
} from "./hermes.ts";
import { modelCommand, thinkCommand, toolPolicyCommand } from "./model.ts";
import { CommandRegistry } from "./registry.ts";
import { abortCommand, goalCommand, queueCommand, runsCommand, steerCommand } from "./run.ts";
import {
	historyCommand,
	resetCommand,
	resumeCommand,
	sessionCommand,
	sessionsCommand,
} from "./session.ts";
import { skillsCommand } from "./skills.ts";

export interface RegistryOptions {
	/** Opens $EDITOR on the draft. Defaults to a notice that it is unavailable. */
	openExternalEditor?: () => Promise<void>;
}

export function createCommandRegistry(options: RegistryOptions = {}): CommandRegistry {
	const openEditor =
		options.openExternalEditor ??
		(() => Promise.reject(new Error("no external editor is wired up")));
	return new CommandRegistry().registerAll([
		helpCommand,
		commandsCommand,
		quitCommand,
		clearCommand,
		modeCommand,
		themeCommand,
		makeEditorCommand(openEditor),

		sessionsCommand,
		sessionCommand,
		resetCommand,
		resumeCommand,
		historyCommand,
		compressCommand,
		heartbeatCommand,

		modelCommand,
		thinkCommand,
		toolPolicyCommand,
		skillsCommand,

		abortCommand,
		queueCommand,
		steerCommand,
		backgroundCommand,
		btwCommand,
		runsCommand,
		agentsCommand,
		tasksCommand,
		goalCommand,

		approvalsCommand,
		approveCommand,
		denyCommand,

		statusCommand,
		usageCommand,
		costCommand,
		logsCommand,

		reconnectCommand,
		debugCommand,
	]);
}

export type {
	CommandContext,
	CommandHost,
	MultiPickerSpec,
	PickerChoice,
	PickerSpec,
	SlashCommand,
} from "./registry.ts";
export { CommandRegistry, parseCommandLine, splitArgs } from "./registry.ts";
