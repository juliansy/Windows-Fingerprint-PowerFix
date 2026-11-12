# Windows-Fingerprint-PowerFix

**摘要**：Windows 每次开机或重启，都会把指纹设备的「允许计算机关闭此设备以节省电源」重新勾上，传感器因此在睡眠前被断电，指纹唤醒与解锁随之失效。本仓库用一条 SYSTEM 计划任务，在每次设备启动后把该设置改回「关闭」并回读校验；不改驱动、不改 INF，一条命令安装，一条命令卸载。在一台 Acer SFX14-41G（EgisTec 1C7A:0575，Windows 11 现代待机）上经 5 次真实开机与睡眠验收：开机约 12 秒内恢复，睡眠后指纹唤醒并解锁正常。

**着急的话 → [直接跳到安装](#安装)**。

| | |
|---|---|
| **问题** | 睡眠后指纹唤不醒；设备管理器里那个勾选每次开机都被重新勾上 |
| **原因** | 驱动 INF 声明「支持空闲断电」，Windows 的 UMDF 框架在每次设备启动时按默认值重写用户设置 |
| **方案** | 计划任务在开机与登录后改回设置，并回读注册表校验，失败自动重试 |
| **代价** | 不改驱动、无周期任务、无常驻进程；开机后约 12 秒的纠正时间窗 |

## 症状

- 指纹设备状态正常，Windows Hello 能录入也能用；
- 睡眠或休眠后按指纹没反应，只能靠键盘、鼠标或电源键唤醒；
- 设备管理器 → 该设备 → 电源管理：「允许计算机关闭此设备以节省电源」被勾上；
- 手动取消勾选后一切正常，直到下次开机重启，勾选又回来了。

## 原因

这类 UMDF 设备的电源策略来自驱动 INF 的两行声明：

```ini
HKR,,"DeviceIdleEnabled",0x00010001,1
HKR,WudfPowerPolicySettings,"WdfDefaultIdleInWorkingState",0x00010001,1
```

第一行声明「本设备支持空闲断电」，第二行给出默认值「启用」。WUDF 框架在**每次设备启动**时按默认值写入：

```
HKLM\SYSTEM\CurrentControlSet\Enum\<设备实例>\Device Parameters\WudfPowerPolicySettings\IdleInWorkingState = 1
```

设备管理器里那个复选框改的就是 `IdleInWorkingState`，但框架不保留用户的选择，也不需要重装设备——所以「取消勾选」只能撑到下一次开机。

把该值改回 0 之后：设备保持 D0 不会被空闲挂起；睡眠时集线器不会给它断电；`powercfg /devicequery wake_armed` 里它保持「已启用为唤醒源」，指纹即可唤醒并解锁。

其它常见做法都挡不住这次写入：`DeviceIdleEnabled=0`、`Device Parameters\WDF\IdleInWorkingState=0`、`UserSetDeviceIdleEnabled=0`，设备重启后仍被框架改回 1。**可靠的做法只有事后改回。**

## 方案

一条以 SYSTEM 身份运行的计划任务 `FingerprintPowerFix`，开机与登录各触发一次：

1. 通过 WMI `root\WMI:MSPower_DeviceEnable` 找到目标设备；
2. 把 `Enable` 置为 `False`（等价于取消勾选）；
3. 回读 `IdleInWorkingState` 确认是 `0` 才结束，否则每 2 秒重试，最长 3 分钟；
4. 全过程写入 `C:\ProgramData\FpPowerFix\fix.log`。

不绑定机型：安装脚本自动枚举所有生物识别设备（Class `Biometric`），只处理声明了 WUDF 空闲策略的那些，多颗指纹设备会一起处理。没有常驻进程，没有轮询，删掉任务即完全还原。

## 安装

需要 Windows 10/11 与 PowerShell 5.1 以上。脚本自己申请管理员权限（一次 UAC 提示）。

```powershell
git clone https://github.com/juliansy/Windows-Fingerprint-PowerFix.git
cd Windows-Fingerprint-PowerFix
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

**设备识别是自动的，不需要手抄 InstanceId。** 脚本会列出识别到的设备并当场跑一次任务：

```
[*] detecting biometric devices
[*] target: USB\VID_1C7A&PID_0575\0E72****
[*] files installed in C:\ProgramData\FpPowerFix
[*] task registered
[*] running the task once and checking the result
    OK   USB\VID_1C7A&PID_0575\0E72****  IdleInWorkingState=0
```

识别不对或要指定别的设备时，手动传 InstanceId（设备管理器 → 属性 → 详细信息 → 设备实例路径）：

```powershell
.\install.ps1 -InstanceId 'USB\VID_XXXX&PID_YYYY\序列号'
```

只想装好、不想当场跑一次，加 `-SkipVerify`。

如果机器上还留着旧版本建的计划任务，安装脚本只会把它们列出来、不删除；想顺手清掉加 `-RemoveLegacyTasks`。

## 验证

1. 重启；
2. 看日志末尾是否为 `verified IdleInWorkingState=0`（`Get-Content C:\ProgramData\FpPowerFix\fix.log -Tail 20`）；
3. 睡眠，按指纹唤醒并解锁；
4. 确认唤醒源还在：`powercfg /devicequery wake_armed`。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

删除计划任务，并把设备恢复为出厂默认（允许关闭以节省电源）。`-KeepDeviceSetting` 保留当前设置，`-Purge` 连安装目录和日志一起删除。

## 适用范围与限制

- 适用于「驱动声明 WUDF 空闲断电、用户设置会被框架重写」的 UMDF 设备，指纹传感器是常见一类；
- 开机后约 12 秒的纠正时间窗：框架写入之后、任务改回之前若恰好入睡，仍可能唤不醒。实际很难踩中——开机到进入待机通常远超 30 秒，且键盘、鼠标、电源键仍是唤醒源；
- 设备实例 ID 变化（如换 USB 口导致父集线器变化）后，重新运行 `install.ps1`；
- 更新或重装该设备驱动后，手动运行一次任务，或注销重登。

## 故障排查

| 现象 | 处理 |
|---|---|
| 提示没有可处理的生物识别设备 | 用 `-InstanceId` 指定；确认设备已启用、状态正常 |
| 日志末尾是 `FAILED after 180s` | 核对实例 ID；看 `IdleInWorkingState` 当前值 |
| 任务在但日志没有新行 | 查任务历史记录，确认以 SYSTEM 运行、触发器为「启动时」与「登录时」 |
| 指纹仍不能唤醒 | `powercfg /devicequery wake_armed` 是否含该设备；BIOS 是否允许 USB 唤醒 |

## 仓库结构

```
install.ps1                    安装：自动提权、识别设备、注册任务、自检
uninstall.ps1                  卸载：自动提权、删任务、恢复出厂默认
src/Disable-FpPowerSaving.ps1  实际干活的脚本，由 SYSTEM 计划任务调用
docs/root-cause.md             根因与取证：为什么每次都重置、试过什么、为什么不管用
```

## 参考

- Microsoft Learn：[User Control of Device Idle and Wake Behavior](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/user-control-of-device-idle-and-wake-behavior)
- Microsoft Q&A：[3751668](https://learn.microsoft.com/en-us/answers/questions/3751668/)（同症状，Egis 厂商答复称问题来自 Windows 11）
- 根因与取证细节：[docs/root-cause.md](docs/root-cause.md)

## License

MIT
