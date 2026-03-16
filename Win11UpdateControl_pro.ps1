[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Apply','Restore','Status')]
    [string]$ScriptAction,

    [ValidateSet('SafeDesktop','ControlledDesktop','WorkstationStable','KioskLab','ExtremeAirgapped','Custom')]
    [string]$Profile,

    [string[]]$Modules,

    [ValidateSet('Default','Off','NotifyDownload','ManualOnly')]
    [string]$UpdateMode = 'NotifyDownload',

    [ValidateSet('Default','Disable')]
    [string]$DriverUpdateMode = 'Default',

    [ValidateSet('Default','DisableAutoUpdate')]
    [string]$StoreUpdateMode = 'Default',

    [ValidateSet('Default','Disable')]
    [string]$DeliveryOptimizationMode = 'Default',

    [ValidateSet('Default','Freeze')]
    [string]$FeatureUpdateMode = 'Default',

    [ValidateSet('Untouched','SignatureOnly','DisableScheduledTasks')]
    [string]$DefenderMode = 'Untouched',

    [ValidateSet('Default','Disable')]
    [string]$MaintenanceMode = 'Default',

    [string]$TargetReleaseVersion = '',
    [string]$ExportPresetPath = '',
    [string]$ImportPresetPath = '',
    [switch]$CreateRestorePoint,
    [switch]$DisableServices,
    [switch]$UseServiceAclLockdown,
    [switch]$RenameUsoClient,
    [switch]$SkipRestorePoint,
    [switch]$Force,
    [switch]$Quiet,
    [string]$StateRoot = "$env:ProgramData\Win11UpdateControl"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================
# GLOBALS
# ============================

$script:Version = '3.0.0'
$script:StateFile = Join-Path $StateRoot 'state.json'
$script:RegistryBackupDir = Join-Path $StateRoot 'registry'
$script:LogDir = Join-Path $StateRoot 'logs'
$script:PresetDir = Join-Path $StateRoot 'presets'
$script:LogFile = Join-Path $script:LogDir ("run_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:UseInteractive = -not $PSBoundParameters.ContainsKey('ScriptAction')
$script:UseImportedPreset = $false
$script:SelectedExportPresetPath = $null
$script:OperationResults = New-Object System.Collections.Generic.List[object]

$script:ModuleCatalog = [ordered]@{
    RebootPolicy          = 'Policy anti-riavvio automatico e active hours'
    RebootTasks           = 'Disabilita task reboot di UpdateOrchestrator'
    UpdatePolicy          = 'Configura comportamento Windows Update'
    UpdateServices        = 'Gestisce servizi Windows Update / BITS / Medic / Orchestrator'
    DriverUpdates         = 'Blocca driver update via Windows Update'
    FeatureUpdates        = 'Congela feature update / target release version'
    StoreAutoUpdate       = 'Disabilita auto-update Microsoft Store'
    DeliveryOptimization  = 'Disabilita Delivery Optimization'
    AutomaticMaintenance  = 'Riduce/disabilita manutenzione automatica'
    DefenderControl       = 'Controllo selettivo di Defender lato task/politiche leggere'
    UsoClientRename       = 'Rinomina UsoClient.exe (opzione estrema)'
    ServiceAclLockdown    = 'Applica sdset ai servizi update (opzione esperta)'
}

$script:ServiceList = @('wuauserv','UsoSvc','WaaSMedicSvc','BITS')
$script:RebootTasks = @(
    '\Microsoft\Windows\UpdateOrchestrator\Reboot',
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_AC',
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery'
)
$script:MaintenanceTasks = @(
    '\Microsoft\Windows\TaskScheduler\Regular Maintenance',
    '\Microsoft\Windows\TaskScheduler\Idle Maintenance',
    '\Microsoft\Windows\TaskScheduler\Maintenance Configurator'
)
$script:DefenderTasks = @(
    '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
    '\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
    '\Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
    '\Microsoft\Windows\Windows Defender\Windows Defender Verification'
)

$script:RegistryPaths = @(
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
    'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching',
    'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization',
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'
)

$script:UsoClientPath = "$env:SystemRoot\System32\UsoClient.exe"
$script:UsoClientBlockedPath = "$env:SystemRoot\System32\UsoClient_blocked.exe"

# ============================
# UTILS
# ============================

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO'
    )

    Ensure-Directory -Path $script:LogDir
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line

    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            'WARN'  { Write-Host $Message -ForegroundColor Yellow }
            'OK'    { Write-Host $Message -ForegroundColor Green }
            default { Write-Host $Message }
        }
    }
}

function Add-Result {
    param([string]$Area,[string]$Name,[string]$Status,[string]$Detail)
    $script:OperationResults.Add([pscustomobject]@{
        Area   = $Area
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-IsAdmin) { return }

    if ($script:UseInteractive) {
        Write-Host 'Richiesti privilegi amministrativi. Tentativo di ri-esecuzione elevata...' -ForegroundColor Yellow
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        foreach ($kvp in $PSBoundParameters.GetEnumerator()) {
            $key = "-$($kvp.Key)"
            $value = $kvp.Value
            if ($value -is [switch]) {
                if ($value.IsPresent) { $argList += $key }
            } elseif ($value -is [System.Array]) {
                foreach ($item in $value) { $argList += $key; $argList += "`"$item`"" }
            } else {
                $argList += $key
                $argList += "`"$value`""
            }
        }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
        exit
    }

    throw 'Eseguire lo script come amministratore.'
}

function Invoke-Safely {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        Add-Result -Area $Area -Name $Name -Status 'OK' -Detail 'Completato'
        Write-Log "$Area :: $Name completato" 'OK'
    }
    catch {
        Add-Result -Area $Area -Name $Name -Status 'ERROR' -Detail $_.Exception.Message
        Write-Log "$Area :: $Name fallito - $($_.Exception.Message)" 'ERROR'
        if (-not $Force) { throw }
    }
}

function Export-RegistryPath {
    param([Parameter(Mandatory)][string]$RegistryPath)

    Ensure-Directory -Path $script:RegistryBackupDir
    $safeName = ($RegistryPath -replace '[\\/:*?"<>| ]','_') + '.reg'
    $destination = Join-Path $script:RegistryBackupDir $safeName
    & reg.exe export $RegistryPath $destination /y | Out-Null
    return $destination
}

function Get-ServiceStartMode {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
    return $svc.StartMode
}

function Set-ServiceStartupSmart {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic','Manual','Disabled')][string]$Mode
    )
    try {
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
    }
    catch {
        $map = @{ Automatic = 'auto'; Manual = 'demand'; Disabled = 'disabled' }
        & sc.exe config $Name start= $map[$Mode] | Out-Null
    }
}

function Parse-TaskReference {
    param([Parameter(Mandatory)][string]$TaskPathFull)
    $trimmed = $TaskPathFull.TrimStart('\')
    $parts = $trimmed -split '\\'
    $taskName = $parts[-1]
    $taskPath = '\'
    if ($parts.Length -gt 1) {
        $taskPath = '\' + (($parts[0..($parts.Length - 2)] -join '\') + '\')
    }
    return [pscustomobject]@{ TaskPath = $taskPath; TaskName = $taskName }
}

function Get-ScheduledTaskStateSafe {
    param([Parameter(Mandatory)][string]$TaskPathFull)
    $parsed = Parse-TaskReference -TaskPathFull $TaskPathFull
    $task = Get-ScheduledTask -TaskPath $parsed.TaskPath -TaskName $parsed.TaskName -ErrorAction Stop
    return [pscustomobject]@{
        TaskPath = $parsed.TaskPath
        TaskName = $parsed.TaskName
        Enabled  = $task.Settings.Enabled
        State    = (Get-ScheduledTaskInfo -TaskPath $parsed.TaskPath -TaskName $parsed.TaskName -ErrorAction SilentlyContinue).State
    }
}

function Set-TaskEnabledSafe {
    param([Parameter(Mandatory)][string]$TaskPathFull,[Parameter(Mandatory)][bool]$Enabled)
    $parsed = Parse-TaskReference -TaskPathFull $TaskPathFull
    if ($Enabled) {
        Enable-ScheduledTask -TaskPath $parsed.TaskPath -TaskName $parsed.TaskName -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $parsed.TaskPath -TaskName $parsed.TaskName -ErrorAction Stop | Out-Null
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String')][string]$Type = 'DWord'
    )

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegistryValueSafe {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}

function Save-State {
    param([Parameter(Mandatory)][hashtable]$State)
    Ensure-Directory -Path $StateRoot
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        throw "Nessun file di stato trovato in $script:StateFile"
    }
    return Get-Content -Path $script:StateFile -Raw | ConvertFrom-Json -Depth 10
}

function Save-PresetFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Preset)
    Ensure-Directory -Path (Split-Path -Parent $Path)
    $Preset | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Load-PresetFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Preset non trovato: $Path" }
    return Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 10
}

function New-StateSnapshot {
    $snapshot = [ordered]@{
        CreatedAt = (Get-Date).ToString('o')
        ScriptVersion = $script:Version
        RegistryExports = @()
        Services = @()
        Tasks = @()
        Policies = @()
        Sddl = @()
        Files = @()
    }

    foreach ($regPath in $script:RegistryPaths) {
        try {
            $exported = Export-RegistryPath -RegistryPath $regPath
            $snapshot.RegistryExports += [pscustomobject]@{ Path = $regPath; Export = $exported }
        } catch {
            Write-Log "Export registry fallito per ${regPath}: $($_.Exception.Message)" 'WARN'
        }
    }

    foreach ($svc in $script:ServiceList) {
        try {
            $service = Get-Service -Name $svc -ErrorAction Stop
            $snapshot.Services += [pscustomobject]@{
                Name = $svc
                Status = [string]$service.Status
                StartMode = Get-ServiceStartMode -Name $svc
            }
            try {
                $sddl = (& sc.exe sdshow $svc) -join ''
                if ($sddl) { $snapshot.Sddl += [pscustomobject]@{ Name = $svc; Value = $sddl.Trim() } }
            } catch {
                Write-Log "Backup SDDL fallito per $svc" 'WARN'
            }
        } catch {
            Write-Log "Servizio $svc non trovato durante snapshot" 'WARN'
        }
    }

    foreach ($taskRef in ($script:RebootTasks + $script:MaintenanceTasks + $script:DefenderTasks)) {
        try { $snapshot.Tasks += Get-ScheduledTaskStateSafe -TaskPathFull $taskRef }
        catch { Write-Log "Task $taskRef non trovato durante snapshot" 'WARN' }
    }

    if ((Test-Path -LiteralPath $script:UsoClientPath) -or (Test-Path -LiteralPath $script:UsoClientBlockedPath)) {
        $snapshot.Files += [pscustomobject]@{
            Original = $script:UsoClientPath
            Blocked  = $script:UsoClientBlockedPath
            OriginalExists = (Test-Path -LiteralPath $script:UsoClientPath)
            BlockedExists  = (Test-Path -LiteralPath $script:UsoClientBlockedPath)
        }
    }

    return $snapshot
}

function New-SystemRestorePointSafe {
    if ($SkipRestorePoint) {
        Write-Log 'Creazione restore point saltata su richiesta.' 'WARN'
        return
    }

    try { Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction Stop }
    catch { Write-Log 'Enable-ComputerRestore non disponibile o già attivo.' 'WARN' }

    try {
        Checkpoint-Computer -Description 'Win11UpdateControl pre-change' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Punto di ripristino creato.' 'OK'
    } catch {
        Write-Log "Impossibile creare il restore point: $($_.Exception.Message)" 'WARN'
    }
}

function Resolve-ProfileDefinition {
    param([Parameter(Mandatory)][string]$Name)

    switch ($Name) {
        'SafeDesktop' {
            return [ordered]@{
                Modules = @('RebootPolicy','RebootTasks','UpdatePolicy')
                Settings = [ordered]@{
                    UpdateMode='NotifyDownload'; DriverUpdateMode='Default'; StoreUpdateMode='Default'
                    DeliveryOptimizationMode='Default'; FeatureUpdateMode='Default'; DefenderMode='Untouched'
                    MaintenanceMode='Default'; DisableServices=$false; RenameUsoClient=$false; UseServiceAclLockdown=$false
                }
            }
        }
        'ControlledDesktop' {
            return [ordered]@{
                Modules = @('RebootPolicy','RebootTasks','UpdatePolicy','DriverUpdates')
                Settings = [ordered]@{
                    UpdateMode='ManualOnly'; DriverUpdateMode='Disable'; StoreUpdateMode='Default'
                    DeliveryOptimizationMode='Default'; FeatureUpdateMode='Default'; DefenderMode='Untouched'
                    MaintenanceMode='Default'; DisableServices=$false; RenameUsoClient=$false; UseServiceAclLockdown=$false
                }
            }
        }
        'WorkstationStable' {
            return [ordered]@{
                Modules = @('RebootPolicy','RebootTasks','UpdatePolicy','DriverUpdates','FeatureUpdates','StoreAutoUpdate','DefenderControl')
                Settings = [ordered]@{
                    UpdateMode='ManualOnly'; DriverUpdateMode='Disable'; StoreUpdateMode='DisableAutoUpdate'
                    DeliveryOptimizationMode='Default'; FeatureUpdateMode='Freeze'; DefenderMode='SignatureOnly'
                    MaintenanceMode='Default'; DisableServices=$false; RenameUsoClient=$false; UseServiceAclLockdown=$false
                }
            }
        }
        'KioskLab' {
            return [ordered]@{
                Modules = @('RebootPolicy','RebootTasks','UpdatePolicy','UpdateServices','DriverUpdates','FeatureUpdates','StoreAutoUpdate','DeliveryOptimization','AutomaticMaintenance','DefenderControl')
                Settings = [ordered]@{
                    UpdateMode='Off'; DriverUpdateMode='Disable'; StoreUpdateMode='DisableAutoUpdate'
                    DeliveryOptimizationMode='Disable'; FeatureUpdateMode='Freeze'; DefenderMode='SignatureOnly'
                    MaintenanceMode='Disable'; DisableServices=$true; RenameUsoClient=$false; UseServiceAclLockdown=$false
                }
            }
        }
        'ExtremeAirgapped' {
            return [ordered]@{
                Modules = @('RebootPolicy','RebootTasks','UpdatePolicy','UpdateServices','DriverUpdates','FeatureUpdates','StoreAutoUpdate','DeliveryOptimization','AutomaticMaintenance','DefenderControl','UsoClientRename','ServiceAclLockdown')
                Settings = [ordered]@{
                    UpdateMode='Off'; DriverUpdateMode='Disable'; StoreUpdateMode='DisableAutoUpdate'
                    DeliveryOptimizationMode='Disable'; FeatureUpdateMode='Freeze'; DefenderMode='DisableScheduledTasks'
                    MaintenanceMode='Disable'; DisableServices=$true; RenameUsoClient=$true; UseServiceAclLockdown=$true
                }
            }
        }
        'Custom' {
            return [ordered]@{
                Modules = $Modules
                Settings = [ordered]@{
                    UpdateMode=$UpdateMode; DriverUpdateMode=$DriverUpdateMode; StoreUpdateMode=$StoreUpdateMode
                    DeliveryOptimizationMode=$DeliveryOptimizationMode; FeatureUpdateMode=$FeatureUpdateMode
                    DefenderMode=$DefenderMode; MaintenanceMode=$MaintenanceMode
                    DisableServices=[bool]$DisableServices; RenameUsoClient=[bool]$RenameUsoClient
                    UseServiceAclLockdown=[bool]$UseServiceAclLockdown
                }
            }
        }
    }
}

function Show-MenuHeader {
    Clear-Host
    Write-Host ''
    Write-Host 'Win11 Update Control v3' -ForegroundColor Cyan
    Write-Host 'Framework modulare per controllo update / reboot / hardening leggero'
    Write-Host ''
}

function Read-Choice {
    param([string]$Prompt,[string[]]$Allowed)
    do {
        $v = Read-Host $Prompt
    } until ($Allowed -contains $v)
    return $v
}

function Initialize-SelectionsInteractive {
    Show-MenuHeader
    Write-Host '1 = Apply preset o configurazione custom'
    Write-Host '2 = Restore configurazione precedente'
    Write-Host '3 = Status / audit'
    Write-Host '4 = Applica preset JSON'
    Write-Host ''

    $selection = Read-Choice -Prompt 'Seleziona azione' -Allowed @('1','2','3','4')
    switch ($selection) {
        '1' { $script:SelectedAction = 'Apply' }
        '2' { $script:SelectedAction = 'Restore' }
        '3' { $script:SelectedAction = 'Status' }
        '4' { $script:SelectedAction = 'Apply'; $script:UseImportedPreset = $true }
    }

    if ($script:SelectedAction -eq 'Apply') {
        if ($script:UseImportedPreset) {
            $script:SelectedImportPresetPath = Read-Host 'Percorso preset JSON da importare'
            return
        }

        Write-Host ''
        Write-Host 'Preset disponibili:'
        Write-Host '1 = SafeDesktop'
        Write-Host '2 = ControlledDesktop'
        Write-Host '3 = WorkstationStable'
        Write-Host '4 = KioskLab'
        Write-Host '5 = ExtremeAirgapped'
        Write-Host '6 = Custom'
        Write-Host ''
        $profileSelection = Read-Choice -Prompt 'Seleziona profilo' -Allowed @('1','2','3','4','5','6')
        switch ($profileSelection) {
            '1' { $script:SelectedProfile = 'SafeDesktop' }
            '2' { $script:SelectedProfile = 'ControlledDesktop' }
            '3' { $script:SelectedProfile = 'WorkstationStable' }
            '4' { $script:SelectedProfile = 'KioskLab' }
            '5' { $script:SelectedProfile = 'ExtremeAirgapped' }
            '6' { $script:SelectedProfile = 'Custom' }
        }

        if ($script:SelectedProfile -eq 'Custom') {
            Write-Host ''
            Write-Host 'Moduli disponibili:'
            $index = 1
            $keys = @($script:ModuleCatalog.Keys)
            foreach ($key in $keys) { Write-Host ("{0} = {1} - {2}" -f $index, $key, $script:ModuleCatalog[$key]); $index++ }
            Write-Host ''
            $customModulesRaw = Read-Host 'Inserisci i numeri dei moduli separati da virgola'
            $selected = @()
            foreach ($item in ($customModulesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $pos = [int]$item - 1
                if ($pos -ge 0 -and $pos -lt $keys.Count) { $selected += $keys[$pos] }
            }
            $script:SelectedModules = $selected | Select-Object -Unique
            if (-not $script:SelectedModules) { throw 'Nessun modulo selezionato.' }

            $script:SelectedUpdateMode = Read-Host 'Update mode (Default/Off/NotifyDownload/ManualOnly) [NotifyDownload]'; if (-not $script:SelectedUpdateMode) { $script:SelectedUpdateMode = 'NotifyDownload' }
            $script:SelectedDriverUpdateMode = Read-Host 'Driver updates (Default/Disable) [Default]'; if (-not $script:SelectedDriverUpdateMode) { $script:SelectedDriverUpdateMode = 'Default' }
            $script:SelectedStoreUpdateMode = Read-Host 'Store auto update (Default/DisableAutoUpdate) [Default]'; if (-not $script:SelectedStoreUpdateMode) { $script:SelectedStoreUpdateMode = 'Default' }
            $script:SelectedDeliveryOptimizationMode = Read-Host 'Delivery Optimization (Default/Disable) [Default]'; if (-not $script:SelectedDeliveryOptimizationMode) { $script:SelectedDeliveryOptimizationMode = 'Default' }
            $script:SelectedFeatureUpdateMode = Read-Host 'Feature Updates (Default/Freeze) [Default]'; if (-not $script:SelectedFeatureUpdateMode) { $script:SelectedFeatureUpdateMode = 'Default' }
            $script:SelectedDefenderMode = Read-Host 'Defender (Untouched/SignatureOnly/DisableScheduledTasks) [Untouched]'; if (-not $script:SelectedDefenderMode) { $script:SelectedDefenderMode = 'Untouched' }
            $script:SelectedMaintenanceMode = Read-Host 'Automatic Maintenance (Default/Disable) [Default]'; if (-not $script:SelectedMaintenanceMode) { $script:SelectedMaintenanceMode = 'Default' }
            $script:SelectedTargetReleaseVersion = Read-Host 'Target release version (es. 24H2, opzionale)'
            $script:SelectedDisableServices = ((Read-Host 'Disabilitare servizi update? (s/n) [n]') -match '^[sSyY]$')
            $script:SelectedRenameUsoClient = ((Read-Host 'Rinominare UsoClient.exe? (s/n) [n]') -match '^[sSyY]$')
            $script:SelectedUseServiceAclLockdown = ((Read-Host 'Applicare sdset ai servizi? (s/n) [n]') -match '^[sSyY]$')
        }

        $script:SelectedCreateRestorePoint = ((Read-Host 'Creare restore point prima di applicare? (s/n) [s]') -notmatch '^[nN]$')
        $shouldExport = ((Read-Host 'Esportare anche un preset JSON di questa configurazione? (s/n) [n]') -match '^[sSyY]$')
        if ($shouldExport) {
            Ensure-Directory -Path $script:PresetDir
            $defaultPreset = Join-Path $script:PresetDir ("preset_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date))
            $script:SelectedExportPresetPath = Read-Host "Percorso preset JSON [$defaultPreset]"
            if (-not $script:SelectedExportPresetPath) { $script:SelectedExportPresetPath = $defaultPreset }
        }
    }
}

function Resolve-Selections {
    if ($script:UseInteractive) {
        Initialize-SelectionsInteractive
        $ScriptAction = $script:SelectedAction
        if ($script:UseImportedPreset) { $ImportPresetPath = $script:SelectedImportPresetPath }
        if ($ScriptAction -eq 'Apply' -and -not $script:UseImportedPreset) {
            $Profile = $script:SelectedProfile
            if ($Profile -eq 'Custom') {
                $Modules = $script:SelectedModules
                $UpdateMode = $script:SelectedUpdateMode
                $DriverUpdateMode = $script:SelectedDriverUpdateMode
                $StoreUpdateMode = $script:SelectedStoreUpdateMode
                $DeliveryOptimizationMode = $script:SelectedDeliveryOptimizationMode
                $FeatureUpdateMode = $script:SelectedFeatureUpdateMode
                $DefenderMode = $script:SelectedDefenderMode
                $MaintenanceMode = $script:SelectedMaintenanceMode
                $TargetReleaseVersion = $script:SelectedTargetReleaseVersion
                $DisableServices = [bool]$script:SelectedDisableServices
                $RenameUsoClient = [bool]$script:SelectedRenameUsoClient
                $UseServiceAclLockdown = [bool]$script:SelectedUseServiceAclLockdown
            }
            $CreateRestorePoint = [bool]($script:SelectedCreateRestorePoint -or $CreateRestorePoint)
            if ($script:SelectedExportPresetPath) { $ExportPresetPath = $script:SelectedExportPresetPath }
        }
    }

    $resolved = [ordered]@{
        Action = $ScriptAction
        Profile = $Profile
        Modules = @()
        Settings = [ordered]@{}
        ExportPresetPath = $ExportPresetPath
    }

    if ($ImportPresetPath) {
        $preset = Load-PresetFile -Path $ImportPresetPath
        $resolved.Profile = [string]$preset.Profile
        $resolved.Modules = @($preset.Modules)
        $resolved.Settings = [ordered]@{}
        foreach ($p in $preset.Settings.PSObject.Properties) { $resolved.Settings[$p.Name] = $p.Value }
        if (-not $resolved.Profile) { $resolved.Profile = 'Custom' }
        return $resolved
    }

    if ($resolved.Action -eq 'Apply') {
        if (-not $resolved.Profile) { throw 'Profile obbligatorio per Action=Apply.' }
        if ($resolved.Profile -eq 'Custom' -and -not $Modules) { throw 'Per Custom devi specificare almeno un modulo.' }

        $profileDef = Resolve-ProfileDefinition -Name $resolved.Profile
        $resolved.Modules = @($profileDef.Modules)
        $resolved.Settings = $profileDef.Settings
        if ($TargetReleaseVersion) { $resolved.Settings.TargetReleaseVersion = $TargetReleaseVersion }
    }

    return $resolved
}

# ============================
# MODULES - APPLY
# ============================

function Apply-RebootPolicy {
    Invoke-Safely -Area 'Registry' -Name 'Reboot policy' -ScriptBlock {
        $WU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        $UX = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

        Set-RegistryValue -Path $WU -Name 'SetActiveHours' -Value 1
        Set-RegistryValue -Path $AU -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1
        Set-RegistryValue -Path $AU -Name 'AlwaysAutoRebootAtScheduledTime' -Value 0
        Set-RegistryValue -Path $AU -Name 'AlwaysAutoRebootAtScheduledTimeMinutes' -Value 0
        Set-RegistryValue -Path $AU -Name 'RebootRelaunchTimeoutEnabled' -Value 0
        Set-RegistryValue -Path $AU -Name 'RebootWarningTimeoutEnabled' -Value 0
        Set-RegistryValue -Path $UX -Name 'ActiveHoursStart' -Value 0
        Set-RegistryValue -Path $UX -Name 'ActiveHoursEnd' -Value 23
        Set-RegistryValue -Path $UX -Name 'SmartActiveHoursState' -Value 0
    }
}

function Apply-RebootTasks {
    foreach ($taskRef in $script:RebootTasks) {
        Invoke-Safely -Area 'Tasks' -Name "Disable $taskRef" -ScriptBlock { Set-TaskEnabledSafe -TaskPathFull $taskRef -Enabled $false }
    }
    Invoke-Safely -Area 'System' -Name 'Abort pending shutdown' -ScriptBlock { & shutdown.exe /a 2>$null | Out-Null }
}

function Apply-UpdatePolicy {
    param([Parameter(Mandatory)][string]$Mode)
    Invoke-Safely -Area 'Registry' -Name "Update policy ($Mode)" -ScriptBlock {
        $WU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        switch ($Mode) {
            'Default' { Remove-RegistryValueSafe -Path $AU -Name 'NoAutoUpdate'; Remove-RegistryValueSafe -Path $AU -Name 'AUOptions' }
            'Off' { Set-RegistryValue -Path $AU -Name 'NoAutoUpdate' -Value 1; Set-RegistryValue -Path $AU -Name 'AUOptions' -Value 1 }
            'NotifyDownload' { Remove-RegistryValueSafe -Path $AU -Name 'NoAutoUpdate'; Set-RegistryValue -Path $AU -Name 'AUOptions' -Value 2 }
            'ManualOnly' {
                Remove-RegistryValueSafe -Path $AU -Name 'NoAutoUpdate'
                Set-RegistryValue -Path $AU -Name 'AUOptions' -Value 2
                Set-RegistryValue -Path $WU -Name 'ExcludeWUDriversInQualityUpdate' -Value 1
            }
        }
    }
}

function Apply-UpdateServices {
    param([Parameter(Mandatory)][bool]$Disable)
    if (-not $Disable) { Write-Log 'Modulo UpdateServices selezionato ma DisableServices=false: nessuna modifica ai servizi.' 'WARN'; return }
    foreach ($svc in $script:ServiceList) {
        Invoke-Safely -Area 'Services' -Name "Stop/disable $svc" -ScriptBlock {
            try { Stop-Service -Name $svc -Force -ErrorAction Stop } catch {}
            Set-ServiceStartupSmart -Name $svc -Mode 'Disabled'
        }
    }
}

function Apply-DriverUpdates {
    param([Parameter(Mandatory)][string]$Mode)
    Invoke-Safely -Area 'Registry' -Name "Driver updates ($Mode)" -ScriptBlock {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
        switch ($Mode) {
            'Default' { Remove-RegistryValueSafe -Path $path -Name 'SearchOrderConfig' }
            'Disable' {
                Set-RegistryValue -Path $path -Name 'SearchOrderConfig' -Value 0
                Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'ExcludeWUDriversInQualityUpdate' -Value 1
            }
        }
    }
}

function Apply-FeatureUpdates {
    param([Parameter(Mandatory)][string]$Mode,[string]$TargetVersion)
    Invoke-Safely -Area 'Registry' -Name "Feature updates ($Mode)" -ScriptBlock {
        $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        switch ($Mode) {
            'Default' {
                Remove-RegistryValueSafe -Path $wu -Name 'TargetReleaseVersion'
                Remove-RegistryValueSafe -Path $wu -Name 'TargetReleaseVersionInfo'
                Remove-RegistryValueSafe -Path $wu -Name 'ProductVersion'
            }
            'Freeze' {
                Set-RegistryValue -Path $wu -Name 'TargetReleaseVersion' -Value 1
                Set-RegistryValue -Path $wu -Name 'ProductVersion' -Value 'Windows 11' -Type String
                if ($TargetVersion) { Set-RegistryValue -Path $wu -Name 'TargetReleaseVersionInfo' -Value $TargetVersion -Type String }
            }
        }
    }
}

function Apply-StoreAutoUpdate {
    param([Parameter(Mandatory)][string]$Mode)
    Invoke-Safely -Area 'Registry' -Name "Store auto update ($Mode)" -ScriptBlock {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
        switch ($Mode) {
            'Default' { Remove-RegistryValueSafe -Path $path -Name 'AutoDownload' }
            'DisableAutoUpdate' { Set-RegistryValue -Path $path -Name 'AutoDownload' -Value 2 }
        }
    }
}

function Apply-DeliveryOptimization {
    param([Parameter(Mandatory)][string]$Mode)
    Invoke-Safely -Area 'Registry' -Name "Delivery Optimization ($Mode)" -ScriptBlock {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        switch ($Mode) {
            'Default' { Remove-RegistryValueSafe -Path $path -Name 'DODownloadMode' }
            'Disable' { Set-RegistryValue -Path $path -Name 'DODownloadMode' -Value 0 }
        }
    }
}

function Apply-AutomaticMaintenance {
    param([Parameter(Mandatory)][string]$Mode)
    Invoke-Safely -Area 'Registry' -Name "Automatic Maintenance ($Mode)" -ScriptBlock {
        $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
        switch ($Mode) {
            'Default' { Remove-RegistryValueSafe -Path $path -Name 'MaintenanceDisabled' }
            'Disable' { Set-RegistryValue -Path $path -Name 'MaintenanceDisabled' -Value 1 }
        }
    }
    if ($Mode -eq 'Disable') {
        foreach ($taskRef in $script:MaintenanceTasks) {
            Invoke-Safely -Area 'Tasks' -Name "Disable $taskRef" -ScriptBlock { Set-TaskEnabledSafe -TaskPathFull $taskRef -Enabled $false }
        }
    }
}

function Apply-DefenderControl {
    param([Parameter(Mandatory)][string]$Mode)
    switch ($Mode) {
        'Untouched' { Write-Log 'Defender lasciato invariato.' 'INFO' }
        'SignatureOnly' {
            Write-Log 'Defender: tentativo di mantenere solo la componente leggera, lasciando gli aggiornamenti firme non toccati.' 'INFO'
            foreach ($taskRef in @('\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan')) {
                Invoke-Safely -Area 'Tasks' -Name "Disable $taskRef" -ScriptBlock { Set-TaskEnabledSafe -TaskPathFull $taskRef -Enabled $false }
            }
        }
        'DisableScheduledTasks' {
            foreach ($taskRef in $script:DefenderTasks) {
                Invoke-Safely -Area 'Tasks' -Name "Disable $taskRef" -ScriptBlock { Set-TaskEnabledSafe -TaskPathFull $taskRef -Enabled $false }
            }
        }
    }
}

function Apply-UsoClientRename {
    param([Parameter(Mandatory)][bool]$Enabled)
    if (-not $Enabled) { Write-Log 'RenameUsoClient non abilitato: salto.' 'WARN'; return }
    Invoke-Safely -Area 'Files' -Name 'Rename UsoClient.exe' -ScriptBlock {
        if (Test-Path -LiteralPath $script:UsoClientPath) {
            & takeown.exe /f $script:UsoClientPath | Out-Null
            & icacls.exe $script:UsoClientPath /grant Administrators:F | Out-Null
            Rename-Item -Path $script:UsoClientPath -NewName (Split-Path -Leaf $script:UsoClientBlockedPath) -Force
        }
    }
}

function Apply-ServiceAclLockdown {
    param([Parameter(Mandatory)][bool]$Enabled)
    if (-not $Enabled) { Write-Log 'ServiceAclLockdown non abilitato: salto.' 'WARN'; return }
    foreach ($svc in @('wuauserv','UsoSvc','WaaSMedicSvc')) {
        Invoke-Safely -Area 'Security' -Name "sdset $svc" -ScriptBlock { & sc.exe sdset $svc 'D:(D;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)' | Out-Null }
    }
}

# ============================
# RESTORE
# ============================

function Restore-RegistryFromExports {
    param($State)
    foreach ($entry in $State.RegistryExports) {
        Invoke-Safely -Area 'Restore' -Name "Registry $($entry.Path)" -ScriptBlock {
            if ($entry.Export -and (Test-Path -LiteralPath $entry.Export)) { & reg.exe import $entry.Export | Out-Null }
        }
    }
}

function Restore-ServicesFromState {
    param($State)
    foreach ($svc in $State.Services) {
        Invoke-Safely -Area 'Restore' -Name "Service $($svc.Name)" -ScriptBlock {
            $mode = switch ($svc.StartMode) {
                'Auto' { 'Automatic' }
                'Manual' { 'Manual' }
                'Disabled' { 'Disabled' }
                default { 'Manual' }
            }
            Set-ServiceStartupSmart -Name $svc.Name -Mode $mode
            if ($svc.Status -eq 'Running') { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
        }
    }
}

function Restore-TasksFromState {
    param($State)
    foreach ($task in $State.Tasks) {
        Invoke-Safely -Area 'Restore' -Name "Task $($task.TaskPath)$($task.TaskName)" -ScriptBlock {
            if ($task.Enabled) { Enable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop | Out-Null }
        }
    }
}

function Restore-ServiceAclFromState {
    param($State)
    foreach ($entry in $State.Sddl) {
        Invoke-Safely -Area 'Restore' -Name "SDDL $($entry.Name)" -ScriptBlock {
            if ($entry.Value) { & sc.exe sdset $entry.Name $entry.Value | Out-Null }
        }
    }
}

function Restore-FilesFromState {
    param($State)
    foreach ($file in $State.Files) {
        Invoke-Safely -Area 'Restore' -Name 'UsoClient.exe' -ScriptBlock {
            if ((Test-Path -LiteralPath $file.Blocked) -and -not (Test-Path -LiteralPath $file.Original)) {
                Rename-Item -Path $file.Blocked -NewName (Split-Path -Leaf $file.Original) -Force
            }
        }
    }
}

# ============================
# STATUS
# ============================

function Get-RegistryValueSafe {
    param([string]$Path,[string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

function Show-Status {
    Write-Host ''
    Write-Host '=== STATUS / AUDIT ===' -ForegroundColor Cyan

    $AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $WU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $UX = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $DS = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
    $WS = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $MT = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'

    @(
        [pscustomobject]@{ Area='Policy'; Name='NoAutoRebootWithLoggedOnUsers'; Value=(Get-RegistryValueSafe -Path $AU -Name 'NoAutoRebootWithLoggedOnUsers') }
        [pscustomobject]@{ Area='Policy'; Name='AUOptions'; Value=(Get-RegistryValueSafe -Path $AU -Name 'AUOptions') }
        [pscustomobject]@{ Area='Policy'; Name='NoAutoUpdate'; Value=(Get-RegistryValueSafe -Path $AU -Name 'NoAutoUpdate') }
        [pscustomobject]@{ Area='Policy'; Name='TargetReleaseVersionInfo'; Value=(Get-RegistryValueSafe -Path $WU -Name 'TargetReleaseVersionInfo') }
        [pscustomobject]@{ Area='Policy'; Name='ExcludeWUDriversInQualityUpdate'; Value=(Get-RegistryValueSafe -Path $WU -Name 'ExcludeWUDriversInQualityUpdate') }
        [pscustomobject]@{ Area='Policy'; Name='ActiveHoursStart'; Value=(Get-RegistryValueSafe -Path $UX -Name 'ActiveHoursStart') }
        [pscustomobject]@{ Area='Policy'; Name='ActiveHoursEnd'; Value=(Get-RegistryValueSafe -Path $UX -Name 'ActiveHoursEnd') }
        [pscustomobject]@{ Area='Policy'; Name='Driver SearchOrderConfig'; Value=(Get-RegistryValueSafe -Path $DS -Name 'SearchOrderConfig') }
        [pscustomobject]@{ Area='Policy'; Name='Store AutoDownload'; Value=(Get-RegistryValueSafe -Path $WS -Name 'AutoDownload') }
        [pscustomobject]@{ Area='Policy'; Name='DODownloadMode'; Value=(Get-RegistryValueSafe -Path $DO -Name 'DODownloadMode') }
        [pscustomobject]@{ Area='Policy'; Name='MaintenanceDisabled'; Value=(Get-RegistryValueSafe -Path $MT -Name 'MaintenanceDisabled') }
    ) | Format-Table -AutoSize

    Write-Host ''
    Write-Host '=== SERVICES ===' -ForegroundColor Cyan
    $svcRows = foreach ($svc in $script:ServiceList) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            [pscustomobject]@{ Service=$svc; Status=[string]$s.Status; StartMode=(Get-ServiceStartMode -Name $svc) }
        } catch {
            [pscustomobject]@{ Service=$svc; Status='NotFound'; StartMode='N/A' }
        }
    }
    $svcRows | Format-Table -AutoSize

    Write-Host ''
    Write-Host '=== TASKS ===' -ForegroundColor Cyan
    $taskRows = foreach ($taskRef in ($script:RebootTasks + $script:MaintenanceTasks + $script:DefenderTasks)) {
        try {
            $t = Get-ScheduledTaskStateSafe -TaskPathFull $taskRef
            [pscustomobject]@{ Task="$($t.TaskPath)$($t.TaskName)"; Enabled=$t.Enabled; State=$t.State }
        } catch {
            [pscustomobject]@{ Task=$taskRef; Enabled='Unknown'; State='NotFound' }
        }
    }
    $taskRows | Format-Table -AutoSize

    Write-Host ''
    Write-Host '=== FILES ===' -ForegroundColor Cyan
    [pscustomobject]@{
        UsoClientExe = (Test-Path -LiteralPath $script:UsoClientPath)
        UsoClientBlockedExe = (Test-Path -LiteralPath $script:UsoClientBlockedPath)
        StateFile = (Test-Path -LiteralPath $script:StateFile)
        LastStatePath = $script:StateFile
    } | Format-List
}

function Show-OperationSummary {
    if (-not $script:OperationResults.Count) { return }
    Write-Host ''
    Write-Host '=== RIEPILOGO OPERAZIONI ===' -ForegroundColor Cyan
    $script:OperationResults | Format-Table -AutoSize
    Write-Host ''
    Write-Host "Log: $script:LogFile"
    if (Test-Path -LiteralPath $script:StateFile) { Write-Host "State: $script:StateFile" }
}

# ============================
# MAIN
# ============================

try {
    Ensure-Directory -Path $StateRoot
    Ensure-Directory -Path $script:LogDir
    Ensure-Directory -Path $script:PresetDir
    Ensure-Admin

    $resolved = Resolve-Selections
    Write-Log "Azione: $($resolved.Action)" 'INFO'
    if ($resolved.Profile) { Write-Log "Profilo: $($resolved.Profile)" 'INFO' }

    if ($resolved.ExportPresetPath) {
        $preset = [ordered]@{
            ScriptVersion = $script:Version
            Profile = $resolved.Profile
            Modules = @($resolved.Modules)
            Settings = $resolved.Settings
        }
        Save-PresetFile -Path $resolved.ExportPresetPath -Preset $preset
        Write-Log "Preset esportato in $($resolved.ExportPresetPath)" 'OK'
    }

    switch ($resolved.Action) {
        'Apply' {
            if ($CreateRestorePoint) { New-SystemRestorePointSafe }

            $snapshot = New-StateSnapshot
            $snapshot.Policies += [pscustomobject]@{
                Profile = $resolved.Profile
                Modules = @($resolved.Modules)
                Settings = $resolved.Settings
            }
            Save-State -State $snapshot
            Write-Log 'Snapshot iniziale salvato.' 'OK'

            foreach ($module in $resolved.Modules) {
                switch ($module) {
                    'RebootPolicy'         { Apply-RebootPolicy }
                    'RebootTasks'          { Apply-RebootTasks }
                    'UpdatePolicy'         { Apply-UpdatePolicy -Mode $resolved.Settings.UpdateMode }
                    'UpdateServices'       { Apply-UpdateServices -Disable ([bool]$resolved.Settings.DisableServices) }
                    'DriverUpdates'        { Apply-DriverUpdates -Mode $resolved.Settings.DriverUpdateMode }
                    'FeatureUpdates'       {
                        $target = $null
                        if ($resolved.Settings.ContainsKey('TargetReleaseVersion')) { $target = [string]$resolved.Settings.TargetReleaseVersion }
                        Apply-FeatureUpdates -Mode $resolved.Settings.FeatureUpdateMode -TargetVersion $target
                    }
                    'StoreAutoUpdate'      { Apply-StoreAutoUpdate -Mode $resolved.Settings.StoreUpdateMode }
                    'DeliveryOptimization' { Apply-DeliveryOptimization -Mode $resolved.Settings.DeliveryOptimizationMode }
                    'AutomaticMaintenance' { Apply-AutomaticMaintenance -Mode $resolved.Settings.MaintenanceMode }
                    'DefenderControl'      { Apply-DefenderControl -Mode $resolved.Settings.DefenderMode }
                    'UsoClientRename'      { Apply-UsoClientRename -Enabled ([bool]$resolved.Settings.RenameUsoClient) }
                    'ServiceAclLockdown'   { Apply-ServiceAclLockdown -Enabled ([bool]$resolved.Settings.UseServiceAclLockdown) }
                    default                { Write-Log "Modulo sconosciuto: $module" 'WARN' }
                }
            }

            Invoke-Safely -Area 'System' -Name 'Final shutdown abort' -ScriptBlock { & shutdown.exe /a 2>$null | Out-Null }
            Write-Log 'Applicazione completata.' 'OK'
        }
        'Restore' {
            $state = Load-State
            Restore-RegistryFromExports -State $state
            Restore-ServicesFromState -State $state
            Restore-TasksFromState -State $state
            Restore-ServiceAclFromState -State $state
            Restore-FilesFromState -State $state
            Write-Log 'Ripristino completato.' 'OK'
        }
        'Status' { Show-Status }
    }
}
catch {
    Write-Log "Errore fatale: $($_.Exception.Message)" 'ERROR'
    throw
}
finally {
    Show-OperationSummary
}
