## Contributing to Win11 Update Control

Thank you for your interest in contributing to **Win11 Update Control**.  
Contributions of any kind (bug fixes, new features, documentation improvements) are welcome.

---

### Getting started

1. **Fork** the repository on GitHub.
2. Create a new descriptive branch:

   ```bash
   git checkout -b feature/your-feature-name
   # or
   git checkout -b fix/your-bug-name
   ```

3. Make your changes on that branch.
4. Make sure the script:
   - Does not introduce PowerShell errors (lint/tests if available).
   - Keeps compatibility with Windows 11 (recent releases).

5. Open a **Pull Request (PR)** against the `main` branch.

---

### Pull Request guidelines

- Clearly describe:
  - The problem you are solving.
  - Previous behavior and new behavior.
  - Any impact on profiles, modules or security.
- When possible, include:
  - Example commands used (`-Action`, `-Profile`, etc.).
  - Log excerpts (`run_*.log`), with any sensitive information removed.

---

### PowerShell coding style

- Use `Set-StrictMode -Version Latest` (already present in the main script).
- Avoid adding non-standard dependencies unless strictly necessary.
- Prefer small, focused functions (modular style, consistent with existing code).
- Avoid unnecessary comments: explain only *why* when the intent is not obvious from the code.

---

### Issues and bug reports

When opening an **issue**, please include:

- Windows version (for example `Windows 11 Pro 23H2`).
- Output of:

  ```powershell
  $PSVersionTable
  ```

- Command used, for example:

  ```powershell
  .\Win11UpdateControl.ps1 -Action Apply -Profile WorkstationStable
  ```

- Any logs (`logs/run_*.log`) with sensitive information removed.

---

### Security

If you believe you have found a **security vulnerability**, please do NOT open a public issue.  
Instead, follow the policy in `SECURITY.md` and use the indicated contact for responsible disclosure.

---

Thank you for helping keep **Windows 11 updates under control**.

