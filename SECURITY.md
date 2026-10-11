# Security policy

Report a suspected vulnerability through
[GitHub private vulnerability reporting](https://github.com/amirm11248/Noty/security/advisories/new).
Include the affected revision, component, and reproduction steps using a
fabricated notebook or test account. Please give the maintainer time to
investigate privately before disclosing a security issue publicly.

Do not put personal notebooks, lecture recordings, account passwords, session
tokens, signed storage URLs, shared-folder links, service-role keys, Backblaze
credentials, signing material, or private logs in public issues or pull requests.
Revoke or rotate exposed secrets through the relevant provider.

Supabase public client configuration is intentionally visible in the app and
browser source. A public client key does not authorize access to someone else's
data. Account authentication, database ownership policies, and server-side
checks govern that access. Server/admin credentials must stay in server secrets.

This personal project receives updates as the maintainer has time. Use the latest
default-branch revision; no long-term support or response-time commitment is
provided. Dependency alerts, secret scanning, push protection, and private
vulnerability reporting are enabled on the GitHub repository.
CodeQL scans web/server JavaScript and TypeScript and the GitHub workflows.
