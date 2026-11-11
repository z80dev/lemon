export function mergeArtifacts(records) {
  const byId = new Map;
  for (const record of records) {
    byId.delete(record.id);
    if (!record.disabled)
      byId.set(record.id, record);
  }
  return [...byId.values()];
}
