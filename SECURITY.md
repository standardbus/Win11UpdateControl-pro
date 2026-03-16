## Security Policy

Thank you for helping improve the security of **Win11 Update Control**.

This project operates on sensitive system components (policies, services, ACLs, system files).  
It is therefore critical to handle any vulnerabilities or dangerous behaviors with care.

---

### Scope

This policy covers:

- Vulnerabilities that could:
  - Bypass the intended update/reboot control behavior.
  - Put the system in a less secure state than expected without sufficient warning.
  - Expose sensitive information via logs or state files.
- Issues where, due to script errors, the system is left in an inconsistent state or cannot be restored through the `Restore` action.

---

### Reporting a vulnerability

1. **Do not** open a public GitHub issue for security problems.
2. Send a private report to:

   - `w11updater@recom.cc`

3. Please include, when possible:

   - Windows and PowerShell versions.
   - Script version (for example `3.0.0`).
   - Command used and parameters (`Action`, `Profile`, specific `Settings`).
   - A clear description of the observed behavior vs. expected behavior.
   - Any logs (`run_*.log`) with sensitive data removed.

---

### What to expect

- We will do our best to:
  - Acknowledge your report within 7 days.
  - Provide an initial assessment within 14 days.
  - Work with you to confirm, classify and fix the issue.

If you decide to publish technical details after a fix is available, we kindly ask that you:

- Mention the version that contains the fix.
- Avoid highly exploitable details if the issue is still unpatched in most environments.

---

### Recommendations for users

- Use this script only on **systems where you have full administrative control**.
- Test aggressive configurations (e.g. `ExtremeAirgapped`, `ServiceAclLockdown`) in test environments first.
- Keep system and data backups up to date.
- Align use of this tool with your organization’s policies on patching and hardening.

---

Thank you for helping make **Win11 Update Control** safer for everyone.

