<#
  Disable-FpPowerSaving.ps1

  Re-applies "do not allow the computer to turn off this device to save power"
  for one or more PnP devices and verifies the result in the registry.

  Why this exists: some UMDF drivers (for example EgisTec fingerprint sensors)
  declare WdfDefaultIdleInWorkingState=1 in their INF. On every device start the
  WUDF framework writes IdleInWorkingState=1, overwriting whatever the user set
  in Device Manager. Neither the driver settings nor the registry can prevent
  that write, so the only reliable fix is to write it back afterwards.

  Runs as SYSTEM from a scheduled task. Output is ASCII only, so Windows
  PowerShell 5.1 can read this file under any code page.

  Exit code: 0 = every target verified IdleInWorkingState=0, 1 = something failed.
#>
[CmdletBinding()]
param(
    [string[]]$InstanceId,                      # device instance IDs; default = targets.txt next to this script
    [string]$LogFile = '',                        # default: fix.log next to this script
    [int]$TimeoutSeconds = 180,                 # retry budget per device
    [switch]$Quiet                              # do not log "already disabled"
)

$ErrorActionPreference = 'Continue'

# Write next to this script, so a custom -InstallDir keeps its own log.
if (-not $LogFile) {
    if ($PSScriptRoot) { $LogFile = Join-Path $PSScriptRoot 'fix.log' }
    else { $LogFile = Join-Path (Get-Location) 'fix.log' }
}

function Write-Log([string]$Message) {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# ---- targets -------------------------------------------------------------
if (-not $InstanceId -or $InstanceId.Count -eq 0) {
    $listFile = Join-Path $PSScriptRoot 'targets.txt'
    if (Test-Path $listFile) {
        $InstanceId = @(Get-Content $listFile | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
    }
}
if (-not $InstanceId -or $InstanceId.Count -eq 0) {
    Write-Log 'ERROR: no target device (pass -InstanceId or create targets.txt)'
    exit 1
}

# ---- helpers -------------------------------------------------------------
function Get-PowerInstance([string]$Dev) {
    try {
        @(Get-CimInstance -Namespace root/WMI -ClassName MSPower_DeviceEnable -ErrorAction Stop) |
            Where-Object { $_.InstanceName -like "*$Dev*" } | Select-Object -First 1
    } catch { $null }
}

function Get-IdleValue([string]$Dev) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Dev\Device Parameters\WudfPowerPolicySettings"
    try { (Get-ItemProperty -Path $key -Name IdleInWorkingState -ErrorAction Stop).IdleInWorkingState }
    catch { 'n/a' }
}

Write-Log ('--- run start  pid={0} user={1}' -f $PID, $env:USERNAME)

# ---- main ----------------------------------------------------------------
$allOk = $true
foreach ($dev in $InstanceId) {
    $dev = $dev.Trim().TrimEnd('\')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $done = $false

    while (-not $done -and (Get-Date) -lt $deadline) {
        $inst = Get-PowerInstance $dev
        if ($null -eq $inst) {
            Write-Log ("  {0}: power policy instance not available yet" -f $dev)
            Start-Sleep -Seconds 2
            continue
        }

        if ($inst.Enable -ne $false) {
            try {
                $inst.Enable = $false
                Set-CimInstance -InputObject $inst -ErrorAction Stop
                Write-Log ("  {0}: Enable=true -> false" -f $dev)
            } catch {
                Write-Log ("  {0}: set failed: {1}" -f $dev, $_.Exception.Message)
            }
        } elseif (-not $Quiet) {
            Write-Log ("  {0}: already disabled" -f $dev)
        }

        $idle = Get-IdleValue $dev
        if ($idle -eq 0) {
            Write-Log ("  {0}: verified IdleInWorkingState=0" -f $dev)
            $done = $true
        } else {
            Write-Log ("  {0}: IdleInWorkingState={1}, retrying" -f $dev, $idle)
            Start-Sleep -Seconds 2
        }
    }

    if (-not $done) {
        $allOk = $false
        Write-Log ("  {0}: FAILED after {1}s" -f $dev, $TimeoutSeconds)
    }
}

Write-Log ('--- run end  ok={0}' -f $allOk)
if ($allOk) { exit 0 } else { exit 1 }
