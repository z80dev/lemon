import { METHOD } from "../protocol/methods.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

interface HermesSkill {
	id: string;
	key: string;
	name: string;
	description: string;
	category: string;
	collection: "bundled" | "optional";
	installed: boolean;
}

interface HermesCategory {
	collection: "bundled" | "optional";
	category: string;
	count: number;
	installedCount: number;
}

interface HermesCatalog {
	skills: HermesSkill[];
	categories: HermesCategory[];
	summary: { count: number; categoryCount: number; installedCount: number };
}

export const skillsCommand: SlashCommand = {
	name: "skills",
	summary: "browse and import official Hermes skills",
	usage: "[search]",
	group: "configuration",
	methods: [METHOD.skillsHermesCatalog, METHOD.skillsInstall],
	async run(ctx, argv) {
		const query = argv.join(" ").trim();
		ctx.ui.notice(
			query
				? `Searching official Hermes skills for “${query}”…`
				: "Loading official Hermes skills…",
		);

		try {
			const catalog = (await ctx.methods.skillsHermesCatalog(
				query ? { query, details: true } : {},
			)) as unknown as HermesCatalog;

			if (query) {
				openSkills(ctx, catalog.skills, `Hermes skills matching “${query}”`);
				return;
			}

			if (catalog.categories.length === 0) {
				ctx.ui.notice("The Hermes catalog is empty.", "warning");
				return;
			}

			ctx.ui.openPicker({
				title: `Hermes skill categories · ${catalog.summary.count} skills`,
				items: catalog.categories.map((category) => ({
					value: `${category.collection}:${category.category}`,
					label: `${category.category} · ${category.collection}`,
					description: `${category.count} skills · ${category.installedCount} installed`,
				})),
				footer: "enter opens category · type to filter",
				onSelect: async (choice) => {
					const [collection, ...categoryParts] = choice.value.split(":");
					const category = categoryParts.join(":");
					ctx.ui.notice(`Loading ${category} skill descriptions…`);
					try {
						const detail = (await ctx.methods.skillsHermesCatalog({
							collection,
							category,
							details: true,
						})) as unknown as HermesCatalog;
						openSkills(ctx, detail.skills, `${category} · ${collection}`);
					} catch (error) {
						ctx.ui.notice(`Could not load Hermes category: ${describeError(error)}`, "error");
					}
				},
			});
		} catch (error) {
			ctx.ui.notice(`Could not load the Hermes catalog: ${describeError(error)}`, "error");
		}
	},
};

function openSkills(ctx: CommandContext, skills: HermesSkill[], title: string): void {
	if (skills.length === 0) {
		ctx.ui.notice("No matching Hermes skills.", "warning");
		return;
	}

	const byId = new Map(skills.map((skill) => [skill.id, skill]));
	const items: PickerChoice[] = skills.map((skill) => ({
		value: skill.id,
		label: skill.name,
		description: skill.description || `${skill.category} · ${skill.collection}`,
	}));

	ctx.ui.openMultiPicker({
		title,
		items,
		disabledValues: skills.filter((skill) => skill.installed).map((skill) => skill.id),
		onConfirm: async (choices) => {
			if (choices.length === 0) {
				ctx.ui.notice("No Hermes skills selected.");
				return;
			}

			let installed = 0;
			const failures: string[] = [];
			for (const choice of choices) {
				const skill = byId.get(choice.value);
				ctx.ui.notice(`Importing ${skill?.name ?? choice.label}…`);
				try {
					await ctx.methods.skillsInstall({ skillKey: choice.value });
					installed += 1;
				} catch (error) {
					failures.push(`${skill?.name ?? choice.label}: ${describeError(error)}`);
				}
			}

			ctx.ui.notice(
				`Imported ${installed}/${choices.length} Hermes skill${choices.length === 1 ? "" : "s"}.`,
				failures.length === 0 ? "info" : "warning",
			);
			if (failures.length > 0) ctx.ui.noticeBlock(failures, "error");
		},
	});
}

function describeError(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
