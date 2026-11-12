import { posix } from "node:path";
export function resolveArtifact(record, env) {
  if (typeof record.path !== "string")
    throw new Error(`Missing path: ${record.id}`);
  const expanded = record.path.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => {
    if (!Object.hasOwn(env, name))
      throw new Error(`Missing variable: ${name}`);
    return env[name];
  });
  const path = posix.normalize(expanded);
  if (!expanded || posix.isAbsolute(expanded) || path === ".." || path.startsWith("../")) {
    throw new Error(`Unsafe path: ${record.id}`);
  }
  return { id: record.id, path };
}
