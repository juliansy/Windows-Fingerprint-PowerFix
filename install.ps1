<#
  install.ps1 -- install the fingerprint power fix.

  Run it normally; it asks for administrator rights by itself (one UAC prompt).

  What it does:
    1. finds biometric device(s) that publish a WUDF idle power policy
    2. copies src\Disable-FpPowerSaving.ps1 to C:\ProgramData\FpPowerFix
    3. registers a SYSTEM scheduled task (at startup + at logon)
    4. runs the task once and prints the resulting IdleInWorkingState

  Options:
    -InstanceId  explicit device instance ID(s); skips auto-detection
    -TaskName    scheduled task name (default FingerprintPowerFix)
    -InstallDir  where the payload and log live
    -SkipVerify  do not run the task right away
    -RemoveLegacyTasks  also delete tasks left behind by earlier versions
                        (by default they are only listed, never deleted)
#>
[CmdletBinding()]
param(
    [string[]]$InstanceId,
    [string]$TaskName = 'FingerprintPowerFix',
    [string]$InstallDir = 'C:\ProgramData\FpPowerFix',
    [switch]$SkipVerify,
    [switch]$RemoveLegacyTasks
)

$ErrorActionPreference = 'Stop'

# ---- self elevate --------------------------------------------------------
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($TaskName -ne 'FingerprintPowerFix') { $argList += @('-TaskName', ('"{0}"' -f $TaskName)) }
    if ($InstallDir -ne 'C:\ProgramData\FpPowerFix') { $argList += @('-InstallDir', ('"{0}"' -f $InstallDir)) }
    if ($InstanceId) { $argList += '-InstanceId'; foreach ($d in $InstanceId) { $argList += ('"{0}"' -f $d) } }
    if ($SkipVerify) { $argList += '-SkipVerify' }
    if ($RemoveLegacyTasks) { $argList += '-RemoveLegacyTasks' }
    Write-Host 'Requesting administrator rights...'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    exit
}

function Step([string]$m) { Write-Host ('[*] ' + $m) }

# ---- locate payload ------------------------------------------------------
$payloadSrc = Join-Path $PSScriptRoot 'src\Disable-FpPowerSaving.ps1'
if (-not (Test-Path $payloadSrc)) { throw "payload not found: $payloadSrc" }

function Test-IdlePolicy([string]$Dev) {
    Test-Path ("HKLM:\SYSTEM\CurrentControlSet\Enum\$Dev\Device Parameters\WudfPowerPolicySettings")
}

# ---- find target devices -------------------------------------------------
$explicit = ($InstanceId -and $InstanceId.Count -gt 0)

if (-not $explicit) {
    Step 'detecting biometric devices'
    $found = @()
    try {
        $found = @(Get-PnpDevice -Class Biometric -Status OK -ErrorAction Stop | ForEach-Object { $_.InstanceId })
    } catch {
        $found = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.ClassGuid -eq '{53d29ef7-377c-4d14-864b-eb3a85769359}' } |
                   ForEach-Object { $_.DeviceID })
    }
    $found = @($found | Where-Object { $_ } | Sort-Object -Unique)

    if ($found.Count -eq 0) {
        throw 'No biometric device found. Re-run with -InstanceId "USB\VID_xxxx&PID_yyyy\serial".'
    }

    $withPolicy = @($found | Where-Object { Test-IdlePolicy $_ })
    if ($withPolicy.Count -eq 0) {
        Write-Host ''
        Write-Host 'Found these biometric devices, but none declares a WUDF idle power policy:'
        foreach ($d in $found) { Write-Host ("    {0}" -f $d) }
        throw 'Nothing to fix automatically. Re-run with -InstanceId to force a device.'
    }
    $InstanceId = $withPolicy
}

foreach ($dev in $InstanceId) {
    if (Test-IdlePolicy $dev) { Step ("target: {0}" -f $dev) }
    else { Write-Warning ("{0} declares no WUDF idle power policy; the fix will not change it" -f $dev) }
}

# ---- install files -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $payloadSrc (Join-Path $InstallDir 'Disable-FpPowerSaving.ps1') -Force
Set-Content -Path (Join-Path $InstallDir 'targets.txt') -Value $InstanceId -Encoding ASCII
Step "files installed in $InstallDir"

# ---- report tasks left by earlier versions -------------------------------
# Deleting other people's tasks is not our business, so by default we only
# list them; -RemoveLegacyTasks does the cleanup for those who want it.
$legacy = @()
foreach ($old in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ($old.TaskName -eq $TaskName) { continue }
    $isOurs = ($old.TaskName -eq 'FpPowerSavingFix')
    foreach ($a in @($old.Actions)) {
        if ($a.Arguments -match 'Disable-FpPowerSaving\.ps1|Disable-FingerprintPowerSaving\.ps1') { $isOurs = $true }
    }
    if ($isOurs) { $legacy += $old }
}

if ($legacy.Count -gt 0) {
    if ($RemoveLegacyTasks) {
        foreach ($old in $legacy) {
            try {
                Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Confirm:$false
                Step ("removed earlier task: {0}{1}" -f $old.TaskPath, $old.TaskName)
            } catch { Write-Warning ("could not remove {0}{1}: {2}" -f $old.TaskPath, $old.TaskName, $_.Exception.Message) }
        }
    } else {
        Write-Host ''
        Write-Host 'These tasks look like earlier versions of this fix:'
        foreach ($old in $legacy) { Write-Host ("    {0}{1}" -f $old.TaskPath, $old.TaskName) }
        Write-Host 'Left untouched. Remove them yourself, or re-run with -RemoveLegacyTasks.'
        Write-Host ''
    }
}

# ---- register the task ---------------------------------------------------
Step "registering scheduled task $TaskName (SYSTEM, at startup + at logon)"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$payloadDst = Join-Path $InstallDir 'Disable-FpPowerSaving.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $payloadDst)
$trigStart = New-ScheduledTaskTrigger -AtStartup
$trigLogon = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) -MultipleInstances IgnoreNew
$settings.RestartCount = 3
$settings.RestartInterval = 'PT1M'

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigStart, $trigLogon) -Principal $principal -Settings $settings -Description 'Keeps the fingerprint sensor powered: re-applies the power setting after each device start.' | Out-Null
Step 'task registered'

if ($SkipVerify) { exit 0 }

# ---- verify now ----------------------------------------------------------
Step 'running the task once and checking the result'
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8

$bad = 0
foreach ($dev in $InstanceId) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Dev\Device Parameters\WudfPowerPolicySettings"
    $v = 'n/a'
    try { $v = (Get-ItemProperty -Path $key -Name IdleInWorkingState -ErrorAction Stop).IdleInWorkingState } catch {}
    if ($v -eq 0) { Write-Host ("    OK   {0}  IdleInWorkingState=0" -f $dev) }
    else { $bad++; Write-Host ("    FAIL {0}  IdleInWorkingState={1}" -f $dev, $v) }
}

Write-Host ''
if ($bad -eq 0) { Write-Host 'Done. Reboot, then sleep and wake the machine with a fingerprint.' }
else { Write-Host 'The task ran but the value is still 1. See the log below, then retry.' }
Write-Host ("Log: {0}\fix.log" -f $InstallDir)
if ($bad -gt 0) { exit 1 }
