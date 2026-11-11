# Workspace authorization

`canAccess(subject, resource, action)` applies organization-scoped document access.
Authentication, suspension, organization equality, explicit user denials, recognized
actions, and archive status are mandatory gates. Administrators and resource owners
then have full access. Other users cannot access private documents; editors can
read/write team or public documents, and viewers can only read them. Only owners
and administrators can delete. Archived documents only permit otherwise-authorized
reads. Public documents still require an authenticated same-organization subject.

The policy is synchronous and does not mutate its arguments. Regression tests live
in `test/policy.test.js`. Use `node --test test/*.test.js` on Node 22.
