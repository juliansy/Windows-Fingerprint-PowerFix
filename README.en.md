# Windows-Fingerprint-PowerFix

<p align="center"><a href="README.md">简体中文</a> | <b>English</b></p>

<div align="center">

![Platform](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=for-the-badge&logo=windows11&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Release](https://img.shields.io/github/v/release/juliansy/Windows-Fingerprint-PowerFix?style=for-the-badge&label=release&color=2ea44f)
[![Downloads](https://img.shields.io/github/downloads/juliansy/Windows-Fingerprint-PowerFix/total?style=for-the-badge&label=downloads&color=orange)](https://github.com/juliansy/Windows-Fingerprint-PowerFix/releases/latest/download/Windows-Fingerprint-PowerFix.zip)
![License](https://img.shields.io/github/license/juliansy/Windows-Fingerprint-PowerFix?style=for-the-badge&color=blue)
![Stars](https://img.shields.io/github/stars/juliansy/Windows-Fingerprint-PowerFix?style=for-the-badge&color=yellow)

![No driver change](https://img.shields.io/badge/driver-untouched-success?style=flat-square)
![No INF change](https://img.shields.io/badge/INF-untouched-success?style=flat-square)
![No resident process](https://img.shields.io/badge/resident%20process-none-success?style=flat-square)
![UAC](https://img.shields.io/badge/install-one%20UAC%20prompt-informational?style=flat-square)
![Reboot](https://img.shields.io/badge/reboot-not%20required-informational?style=flat-square)
![Language](https://img.shields.io/badge/docs-English%20%7C%20%E4%B8%AD%E6%96%87-informational?style=flat-square)

</div>

**Summary**: Windows re-checks the fingerprint sensor's "Allow the computer to turn off this device to save power" option on every boot or restart, so the sensor is powered down before sleep and fingerprint wake-up stops working. This repository installs one SYSTEM scheduled task that sets the option back off after every device start and verifies the change by reading the registry back. No driver changes, no INF changes: one command to install, one to uninstall. Verified on an Acer SFX14-41G (EgisTec 1C7A:0575, Windows 11 modern standby) across five real boots and sleep cycles — the setting is back within about 12 seconds of boot, and fingerprint wake-up and unlock work normally.

**In a hurry? → [Jump to installation](#installation)**

| | |
|---|---|
| **Problem** | The fingerprint does not wake the machine from sleep, and the Device Manager checkbox is re-enabled on every boot |
| **Cause** | The driver INF declares idle power-off support, and the Windows UMDF framework rewrites the user setting to its default on every device start |
| **Fix** | A scheduled task sets the value back after startup and logon, verifies it in the registry, and retries on failure |
| **Cost** | No driver changes, no periodic task, no resident process; one ~12 second correction window after boot |

## Symptoms

- The sensor looks healthy and Windows Hello can enroll and recognize fingers;
- After sleep or hibernate, touching the sensor does nothing — only the keyboard, mouse or power button wakes the machine;
- Device Manager → the device → Power Management: "Allow the computer to turn off this device to save power" is checked;
- Clearing the checkbox fixes everything until the next boot, when it comes back.

## Cause

The power policy of this kind of UMDF device comes from two lines in the driver INF:

```ini
HKR,,"DeviceIdleEnabled",0x00010001,1
HKR,WudfPowerPolicySettings,"WdfDefaultIdleInWorkingState",0x00010001,1
```

The first line declares "this device supports idle power-off"; the second supplies the default value "enabled". On **every device start** the WUDF framework writes that default:

```
HKLM\SYSTEM\CurrentControlSet\Enum\<device instance>\Device Parameters\WudfPowerPolicySettings\IdleInWorkingState = 1
```

The Device Manager checkbox writes the same value, but the framework does not preserve the user's choice, and nothing needs to be reinstalled for it to be overwritten — which is why clearing the checkbox only lasts until the next boot.

Once the value is back to 0: the device stays in D0 and is not idled, the hub does not power it down when the machine sleeps, and `powercfg /devicequery wake_armed` keeps it listed as an armed wake source, so the fingerprint can wake and unlock the machine.

The usual workarounds do not stop the write: `DeviceIdleEnabled=0`, `Device Parameters\WDF\IdleInWorkingState=0` and `UserSetDeviceIdleEnabled=0` are all reverted to 1 when the device restarts. **Correcting the value after the fact is the only reliable approach.**

## How it works

One scheduled task named `FingerprintPowerFix`, running as SYSTEM, triggered at startup and at logon:

1. find the target device through WMI `root\WMI:MSPower_DeviceEnable`;
2. set `Enable` to `False` (the same as clearing the checkbox);
3. read `IdleInWorkingState` back and only stop when it is `0`, otherwise retry every 2 seconds for up to 3 minutes;
4. log everything to `C:\ProgramData\FpPowerFix\fix.log`.

Not tied to one model: the installer enumerates every biometric device (class `Biometric`) and only handles those that declare the WUDF idle policy; several sensors are handled together. No resident process, no polling — removing the task restores everything.

## Installation

Windows 10/11. The script elevates itself; you will see one UAC prompt — click **Yes**.

### Option 1: no command line

1. Download [`Windows-Fingerprint-PowerFix.zip`](https://github.com/juliansy/Windows-Fingerprint-PowerFix/releases/latest/download/Windows-Fingerprint-PowerFix.zip);
2. extract the zip to a folder you can find (for example a new folder on the Desktop);
3. open that folder and **double-click `install.cmd`**;
4. click **Yes** on the UAC prompt and let the window finish;
5. when the last line reads `OK ... IdleInWorkingState=0` it worked — press any key to close.

Two prompts you may see are normal:

- the blue "Windows protected your PC" window → click **More info** → **Run anyway**;
- antivirus software (360, Huorong, ...) blocking PowerShell → choose **Allow** or **Trust**.

If this fixed your problem, please give the repository a ⭐ Star.

### Option 2: command line

PowerShell 5.1 or later (built into Windows 10/11) and git:

```powershell
git clone https://github.com/juliansy/Windows-Fingerprint-PowerFix.git
cd Windows-Fingerprint-PowerFix
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer detects the device automatically and runs the task once:

```
[*] detecting biometric devices
[*] target: USB\VID_1C7A&PID_0575\0E72****
[*] files installed in C:\ProgramData\FpPowerFix
[*] task registered
[*] running the task once and checking the result
    OK   USB\VID_1C7A&PID_0575\0E72****  IdleInWorkingState=0
```

If detection picks the wrong device, pass the instance ID explicitly (Device Manager → Properties → Details → Device instance path):

```powershell
.\install.ps1 -InstanceId 'USB\VID_XXXX&PID_YYYY\serial'
```

Add `-SkipVerify` to install without running the task immediately; add `-RemoveLegacyTasks` to also remove fix tasks left behind by earlier versions.

If this fixed your problem, please give the repository a ⭐ Star.

## Verify

1. Reboot;
2. check that the log ends with `verified IdleInWorkingState=0` (`Get-Content C:\ProgramData\FpPowerFix\fix.log -Tail 20`);
3. sleep, then wake and unlock with the fingerprint;
4. confirm the wake source is still there: `powercfg /devicequery wake_armed`.

## Uninstall

Double-click `uninstall.cmd`, or run this in the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the task and restores the factory default for the device (power saving allowed). `-KeepDeviceSetting` keeps the current setting, `-Purge` also deletes the install directory and logs.

## Scope and limits

- Applies to UMDF devices whose driver declares WUDF idle power-off and whose user setting is rewritten by the framework; fingerprint sensors are the common case;
- a correction window of about 12 seconds after boot: if the machine sleeps between the framework write and the fix, it may still fail to wake;
- if the device instance ID changes (for example after moving to another USB port), run `install.ps1` again;
- after updating or reinstalling the driver, run the task once manually or sign out and back in.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "no biometric devices to handle" | Use `-InstanceId`; make sure the device is enabled and healthy |
| the log ends with `FAILED after 180s` | Check the instance ID; look at the current `IdleInWorkingState` |
| the task exists but the log gets no new lines | Check the task history; confirm it runs as SYSTEM with the startup and logon triggers |
| the fingerprint still cannot wake the machine | Is the device in `powercfg /devicequery wake_armed`? Does the BIOS allow USB wake? |

## Repository layout

```
install.cmd                    double-click: calls install.ps1 (no command line needed)
uninstall.cmd                  double-click: calls uninstall.ps1
install.ps1                    install: self-elevate, detect devices, register task, self-check
uninstall.ps1                  uninstall: self-elevate, remove task, restore factory default
src/Disable-FpPowerSaving.ps1  the worker script the SYSTEM task runs
docs/root-cause.md             root cause, evidence and ruled-out approaches (Chinese)
```

## References

- Microsoft Learn: [User Control of Device Idle and Wake Behavior](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/user-control-of-device-idle-and-wake-behavior)
- Microsoft Q&A: [3751668](https://learn.microsoft.com/en-us/answers/questions/3751668/) (same symptom; Egis reportedly said the problem is on the Windows 11 side)
- Root cause and evidence, in Chinese: [docs/root-cause.md](docs/root-cause.md)

## License

MIT
