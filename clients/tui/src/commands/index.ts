/**
 * The command set, in `/help` order.
 *
 * `makeEditorCommand` is the one command that needs a host callback at
 * construction time (the $EDITOR handoff owns the terminal), so the registry is
 * built by a function rather than exported as a constant.
 */

import { approvalsCommand, approveCommand, denyCommand } from "./approvals.ts";
import { blueprintCommand, blueprintsCommand } from "./blueprints.ts";
import { contextCommand } from "./context.ts";
import { copyCommand } from "./copy.ts";
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
import { cronCommand } from "./cron.ts";
import { costCommand, logsCommand, statusCommand, usageCommand } from "./diagnostics.ts";
import { forkCommand } from "./fork.ts";
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
import { ompCommand } from "./omp.ts";
import { planCommand } from "./plan.ts";
import { profileCommand, profilesCommand } from "./profiles.ts";
import { CommandRegistry } from "./registry.ts";
import {
	abortCommand,
	goalCommand,
	queueCommand,
	redirectCommand,
	retryCommand,
	runsCommand,
	steerCommand,
} from "./run.ts";
import {
	historyCommand,
	nameCommand,
	resetCommand,
	resumeCommand,
	sessionCommand,
	sessionsCommand,
} from "./session.ts";
import { rewindCommand, treeCommand } from "./session-tree.ts";
import { skillsCommand } from "./skills.ts";
import { diffCommand, outputCommand, paletteCommand, taskTreeCommand } from "./views.ts";

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
		paletteCommand,
		taskTreeCommand,
		outputCommand,
		diffCommand,
		copyCommand,
		quitCommand,
		clearCommand,
		modeCommand,
		themeCommand,
		makeEditorCommand(openEditor),

		sessionsCommand,
		sessionCommand,
		forkCommand,
		nameCommand,
		treeCommand,
		rewindCommand,
		resetCommand,
		resumeCommand,
		historyCommand,
		compressCommand,
		contextCommand,
		planCommand,
		heartbeatCommand,
		cronCommand,
		profilesCommand,
		profileCommand,
		blueprintsCommand,
		blueprintCommand,

		modelCommand,
		thinkCommand,
		toolPolicyCommand,
		skillsCommand,

		abortCommand,
		queueCommand,
		steerCommand,
		redirectCommand,
		retryCommand,
		backgroundCommand,
		btwCommand,
		runsCommand,
		agentsCommand,
		tasksCommand,
		ompCommand,
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
