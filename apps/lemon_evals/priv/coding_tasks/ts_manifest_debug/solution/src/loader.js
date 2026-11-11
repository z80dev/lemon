export function flatten(documents, entry) {
  const active = new Set;
  const stack = [];
  const output = [];
  function visit(name) {
    if (active.has(name))
      throw new Error(`Manifest cycle: ${[...stack, name].join(" -> ")}`);
    if (!Object.hasOwn(documents, name))
      throw new Error(`Unknown manifest: ${name}`);
    const doc = documents[name];
    active.add(name);
    stack.push(name);
    for (const included of doc.includes ?? [])
      visit(included);
    output.push(...doc.artifacts ?? []);
    stack.pop();
    active.delete(name);
  }
  visit(entry);
  return output;
}
