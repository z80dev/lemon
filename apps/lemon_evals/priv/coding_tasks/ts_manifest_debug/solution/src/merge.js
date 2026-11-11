export function mergeArtifacts(records) {
  const byId = new Map;
  for (const record of records)
    byId.set(record.id, record);
  return [...byId.values()].filter((record) => record.disabled !== true);
}
