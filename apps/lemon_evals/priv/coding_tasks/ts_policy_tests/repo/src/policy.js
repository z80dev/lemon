export function canAccess(subject, resource, action) {
  if (!subject)
    return false;
  if (subject.suspended)
    return false;
  if (subject.orgId !== resource.orgId)
    return false;
  if (resource.deniedUserIds?.includes(subject.id))
    return false;
  if (action !== "read" && action !== "write" && action !== "delete")
    return false;
  if (resource.archived && action !== "read")
    return false;
  if (subject.role === "admin")
    return true;
  if (resource.ownerId === subject.id)
    return true;
  if (resource.visibility === "private")
    return false;
  if (action === "read")
    return true;
  return action === "write" && subject.role === "editor";
}
