export type AuditEntry = { action: string; actorId: string; at: number; subject: string };
export class AuditLog {
  #entries: AuditEntry[] = [];
  record(entry: AuditEntry): void { this.#entries.push({ ...entry }); }
  snapshot(): AuditEntry[] { return this.#entries.map(entry => ({ ...entry })); }
}
