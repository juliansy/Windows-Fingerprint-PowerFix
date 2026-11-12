<#
  uninstall.ps1 -- remove the fix.

  Run it normally; it asks for administrator rights by itself.

  Removes the scheduled task and puts the device back to its factory default
  ("allow the computer to turn off this device to save power" = ON).

  Options:
    -KeepDeviceSetting  leave the current power setting untouched
    -Purge              also delete the install folder (and its log)
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'FingerprintPowerFix',
    [string]$InstallDir = 'C:\ProgramData\FpPowerFix',
    [switch]$KeepDeviceSetting,
    [switch]$Purge
)

$ErrorActionPreference = 'Continue'

# ---- self elevate --------------------------------------------------------
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($TaskName -ne 'FingerprintPowerFix') { $argList += @('-TaskName', ('"{0}"' -f $TaskName)) }
    if ($InstallDir -ne 'C:\ProgramData\FpPowerFix') { $argList += @('-InstallDir', ('"{0}"' -f $InstallDir)) }
    if ($KeepDeviceSetting) { $argList += '-KeepDeviceSetting' }
    if ($Purge) { $argList += '-Purge' }
    Write-Host 'Requesting administrator rights...'
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait -ErrorAction Stop
        exit $p.ExitCode
    } catch {
        Write-Host 'Administrator rights were declined.'
        exit 2
    }
}

function Step([string]$m) { Write-Host ('[*] ' + $m) }

# ---- remove task ---------------------------------------------------------
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Step "task removed: $TaskName"
} else {
    Step "task not present: $TaskName"
}

# ---- restore device default ---------------------------------------------
$listFile = Join-Path $InstallDir 'targets.txt'
$targets = @()
if (Test-Path $listFile) { $targets = @(Get-Content $listFile | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) }

if (-not $KeepDeviceSetting) {
    foreach ($dev in $targets) {
        $inst = @(Get-CimInstance -Namespace root/WMI -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue) |
                Where-Object { $_.InstanceName -like "*$dev*" } | Select-Object -First 1
        if ($null -ne $inst) {
            try {
                $inst.Enable = $true
                Set-CimInstance -InputObject $inst -ErrorAction Stop
                Step ("{0}: idle power-off restored to default (ON)" -f $dev)
            } catch { Write-Warning ("{0}: restore failed: {1}" -f $dev, $_.Exception.Message) }
        } else {
            Step ("{0}: device not present, skipped" -f $dev)
        }
    }
}

# ---- cleanup -------------------------------------------------------------
if ($Purge -and (Test-Path $InstallDir)) {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Step "removed $InstallDir"
} else {
    Step ("log kept at {0}\fix.log" -f $InstallDir)
}
