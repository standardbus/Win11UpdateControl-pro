## Win11 Update Control PRO – Block Windows 11 automatic updates and reboots

**Win11 Update Control** is an advanced PowerShell script to **block, control and customize Windows 11 automatic updates and automatic reboots**, designed for both **desktop** and **server-like** scenarios (RDP hosts, lab machines, production systems).

The tool provides **preconfigured profiles**, **modular components**, and a solid **snapshot/restore** mechanism, so you can safely apply deep system changes while always keeping a way back.

---

### Key features

- **Block unwanted automatic reboots**
  - Disables Windows Update reboot tasks (`UpdateOrchestrator`).
  - Configures extended Active Hours and “no auto reboot with logged-on users” policies.

- **Granular Windows Update control**
  - Modes: `Off`, `NotifyDownload`, `ManualOnly`, or `Default`.
  - Optionally blocks driver updates from Windows Update.
  - Freezes Windows 11 version using `TargetReleaseVersion`.

- **Ready-to-use profiles**
  - `SafeDesktop`, `ControlledDesktop`, `WorkstationStable`, `KioskLab`, `ExtremeAirgapped`, `Custom`.
  - Recommended server-style profile example: `ServerConservative` (see Profiles section).
  - Fully customizable `Custom` profile.

- **Server-oriented use**
  - Avoids unexpected reboots on production machines.
  - Lets you block only what you really need (no forced “paranoid” mode).
  - Non-interactive mode suitable for scripts and remote automation.

- **Full snapshot & restore**
  - Automatically exports relevant registry keys.
  - Saves state of services, scheduled tasks, SDDL and key files (`UsoClient.exe`).
  - `Restore` action to go back to the previous state.

- **Detailed logging**
  - Text log for each run (`run_YYYYMMDD_HHMMSS.log`).
  - Final summary of all operations.

---

### Important warnings

- This tool operates on **system policies, services, ACLs, scheduled tasks and system files**.
- **Recommended for experienced administrators only**, or environments where risks are clearly understood:
  - May interfere with patch management solutions (WSUS, Intune, SCCM, etc.).
  - May become incompatible with future Windows 11 builds.
- Before using aggressive profiles (e.g. `ExtremeAirgapped`, `UsoClient.exe` rename, `ServiceAclLockdown`) carefully evaluate:
  - Impact on your environment.
  - Possibility to test on non-critical machines first.

---

### Requirements

- **Operating system**: Windows 11 (desktop/server-capable editions).
- **PowerShell**: 5.1 or later.
- **Privileges**: must be run as **Administrator**.
- **Execution Policy**: `RemoteSigned` or `AllSigned` is recommended in enterprise environments (see Security section).

---

### Installation

#### Option 1 – One-liner (temporary Execution Policy bypass)

From an elevated PowerShell (Run as Administrator):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; irm "https://raw.githubusercontent.com/standardbus/Win11UpdateControl-pro/main/Win11UpdateControl_pro.ps1" | iex
```

This temporarily sets the Execution Policy to `Bypass` for the current process only, then downloads and runs the script from GitHub using `irm | iex`.

#### Option 2 – Download then run locally

1. Download the script:

   ```powershell
   # Example using Invoke-WebRequest
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/standardbus/Win11UpdateControl-pro/main/Win11UpdateControl_pro.ps1" -OutFile "Win11UpdateControl.ps1"
   ```

2. Start PowerShell as **Administrator**.

3. Run the script:

   ```powershell
   Set-Location "path\where\you\saved\the\script"
   .\Win11UpdateControl.ps1
   ```

If you don’t specify parameters, the **interactive menu** will appear.

---

### Quick usage

#### Interactive menu

```powershell
.\Win11UpdateControl.ps1
```

From the menu you can:

- Apply a preset or custom configuration.
- Restore the previous configuration (snapshot).
- Show current status / audit.
- Apply a saved JSON preset.

#### Example: apply safe desktop profile

```powershell
.\Win11UpdateControl.ps1 -Action Apply -Profile SafeDesktop -CreateRestorePoint
```

- Creates a restore point (when possible).
- Applies the **SafeDesktop** profile:
  - Blocks automatic reboots.
  - Keeps Windows Update in a controlled, non-extreme mode.

#### Example: stable workstation with frozen feature updates

```powershell
.\Win11UpdateControl.ps1 -Action Apply -Profile WorkstationStable -CreateRestorePoint
```

#### Example: conservative server (no automatic reboot, manual updates)

```powershell
.\Win11UpdateControl.ps1 -Action Apply -Profile ServerConservative -CreateRestorePoint
```

> Note: the `ServerConservative` profile is meant to avoid extreme measures like renaming `UsoClient.exe` or changing SDDL, to reduce conflicts with patch management tools.

#### Example: apply a JSON preset

```powershell
.\Win11UpdateControl.ps1 -Action Apply -ImportPresetPath "C:\Path\preset_server_conservative.json"
```

#### Example: export preset for the chosen configuration

```powershell
.\Win11UpdateControl.ps1 -Action Apply -Profile WorkstationStable -ExportPresetPath "C:\Presets\my_workstation.json"
```

---

### Available profiles (overview)

**Desktop / workstation**

- **SafeDesktop**
  - Focus: avoid unexpected reboots with a conservative but not extreme update behavior.
- **ControlledDesktop**
  - Focus: updates only when the user decides, driver updates blocked.
- **WorkstationStable**
  - Focus: “work” machines that must remain stable, with frozen feature updates and more controlled Store.

**Kiosk / Lab / Offline**

- **KioskLab**
  - Focus: lab machines, kiosks, demo systems.
  - Disables many automatism, minimizes automatic update interventions.
- **ExtremeAirgapped**
  - Focus: **isolated** environments without Internet access.
  - Uses strong measures: `UsoClient.exe` rename, SDDL lock, disables multiple services and tasks.

**Server (recommended example)**

- **ServerConservative** (suggested profile)
  - No automatic reboot.
  - Manual updates only.
  - Driver updates blocked.
  - Feature updates frozen to a specific release.
  - No extreme changes to `UsoClient.exe` or SDDL, reducing conflicts with patch management tools.

---

### Custom mode

You can build your own custom configuration by selecting individual **modules**:

- `RebootPolicy`, `RebootTasks`, `UpdatePolicy`, `UpdateServices`, `DriverUpdates`,
- `FeatureUpdates`, `StoreAutoUpdate`, `DeliveryOptimization`, `AutomaticMaintenance`,
- `DefenderControl`, `UsoClientRename`, `ServiceAclLockdown`.

In interactive mode, choose the **Custom** profile and:

- Select the modules you want.
- Choose modes (`UpdateMode`, `DriverUpdateMode`, `StoreUpdateMode`, etc.).
- Decide whether to disable update services, rename `UsoClient.exe`, apply `sdset`, etc.

---

### Restore

To restore the previous state:

```powershell
.\Win11UpdateControl.ps1 -Action Restore
```

The script will:

- Re-import saved `.reg` files.
- Restore startup type and state for monitored services.
- Restore state for monitored scheduled tasks.
- Restore any modified service ACLs.
- Restore `UsoClient.exe` if it was renamed.

---

### Status / audit

To show current policy, services, tasks and file status:

```powershell
.\Win11UpdateControl.ps1 -Action Status
```

You will see:

- Key registry values for Windows Update, drivers, Store, DO, maintenance.
- Status and startup type for update-related services.
- Status (enabled/running) of key scheduled tasks.
- Presence of `UsoClient.exe` and the renamed file.

---

### Security and best practices

- **Always take a backup / snapshot** before applying aggressive profiles.
- In **enterprise** environments:
  - Consider **code-signing the script** with a trusted certificate.
  - Use `ExecutionPolicy AllSigned` according to your organization’s policy.
  - Coordinate the use of this tool with the team managing WSUS / Intune / SCCM.

For details on security reports and known issues, see `SECURITY.md`.

---

### How to contribute

Contributions, issues and pull requests are welcome.

- See `CONTRIBUTING.md` for detailed guidelines.
- When opening an issue, please include:
  - Windows version,
  - profile/parameters used,
  - relevant log excerpt (`logs/run_*.log`),
  - `-Action Status` output (if possible without sensitive data).

---

### License

This project is released under the **MIT** license.  
See the `LICENSE` file for full details.


