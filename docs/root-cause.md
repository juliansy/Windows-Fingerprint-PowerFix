# 根因记录：指纹设备「允许计算机关闭此设备以节省电源」每次开机被重置

症状、排除项、失败尝试与最终方案都基于一台机器的取证，结论对其他同类设备通用。

## 1. 现场

| 项目 | 值 |
|---|---|
| 机型 | Acer SFX14-41G，Windows 11（S0 低电量待机 / 现代待机） |
| 设备 | EgisTec Touch Fingerprint Sensor，`USB\VID_1C7A&PID_0575\<序列号>` |
| 驱动 | 3.7.1.1（2020-06-15），`oem35.inf` → `EgisTouchFP0575.inf` |
| 栈 | UMDF：`Service=WUDFRd`、`LowerFilters=WinUsb`、`NTMPDriver=winusb.sys` |
| 症状 | 睡眠后指纹不能唤醒；手动取消勾选后正常，下次开机又回来 |

## 2. 根因

驱动 INF 声明空闲断电，并给出「启用」默认值：

```ini
[Biometric_Device_AddReg]
HKR,,"DeviceIdleEnabled",0x00010001,1
HKR,,"DefaultIdleTimeout",0x00010001,10000
HKR,"WudfPowerPolicySettings","WdfDefaultIdleInWorkingState",0x00010001,1
HKR,"WudfPowerPolicySettings","WdfDefaultWakeFromSleepState",0x00010001,0
```

WUDF 框架据此在**每次设备启动**时写入用户可见的电源策略：

```
HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_1C7A&PID_0575\<序列号>\Device Parameters\WudfPowerPolicySettings
    IdleInWorkingState   REG_DWORD  1   <-- 设备管理器里的勾选
    WakeFromSleepState   REG_DWORD  1
```

按微软文档，这两个值由框架维护，驱动和安装文件不应读写，框架也不保留用户上一次的选择。于是无论开机、重装驱动，还是设备被就地重启（disable/enable），勾选都回到 INF 的默认值。

睡眠时因此发生两件事：设备空闲 10 秒后被集线器挂起断电；进睡眠时它也没有作为唤醒源保持供电。传感器断电后不再上报，唤醒与解锁自然失效。

旁证：System 日志中 provider `Microsoft-Windows-USB-USBHUB3` 的事件 196 约 3 万条，其中约 2.98 万条属该设备（`SkippedAsRecentIoObservered` / `SkippedAsPersistentIoObserved`），说明集线器在待机期间持续尝试断电，被未完成的 IO 挡下。

## 3. 已排除

| 猜测 | 结论 |
|---|---|
| INF 的 AddReg 每次开机重放 | 否。Kernel-PnP 显示该设备只在 2026-08-23 安装过 5 次，此后无 400/410 事件 |
| 计划任务或启动项偷偷改设置 | 否。开机/登录触发器全是系统自带；第三方只有 360 与厂商工具，与指纹无关 |
| 驱动装错型号 | 否。官方包内 INF 与 DLL 同系统内文件 SHA256 逐字节相同 |
| 换新驱动能修 | 否。更新目录该硬件 ID 仅 3.7.0.5 / 3.7.0.6 / 3.7.1.1 / 3.7.2.1，3.7.2.1 电源声明段逐行相同；厂商 25 个新包无一支持 `pid_0575` |
| 用 PnP 事件触发器提前纠正 | 否。`pnputil disable/enable` 不产生 400/410 事件，无法作触发条件 |

## 4. 试过但无效的做法

| 做法 | 结果 |
|---|---|
| `Device Parameters\DeviceIdleEnabled = 0` | 设备重启后仍被写成 1 |
| `Device Parameters\WDF\IdleInWorkingState = 0` | 写进去后被框架当脏数据删除 |
| `Device Parameters\UserSetDeviceIdleEnabled = 0` | 不被识别，仍写 1 |
| `WudfPowerPolicySettings\WdfDefaultIdleInWorkingState = 0` | 仍写 1 |
| 给注册表键加 ACL 阻写 | 未采用：整键粒度会连带挡住 `WakeFromSleepState=1`，最坏导致设备 code 10 |

结论：**没有任何「先手」能阻止这次写入，只能在写入后改回。**

## 5. 最终方案与验收

计划任务 `FingerprintPowerFix`（SYSTEM，开机 + 登录触发）调用 `src/Disable-FpPowerSaving.ps1`，把 `MSPower_DeviceEnable.Enable` 置为 `False` 并回读 `IdleInWorkingState` 校验。

实测时间线：

```
23:00:44  开机
23:00:58  任务启动（框架已把值写成 1）
23:00:59  Enable=false，回读 IdleInWorkingState=0
23:01:49  登录触发再跑一次（already disabled）
23:14:42  进入待机
23:15:06  唤醒，指纹解锁成功
```

同一晚做了 5 次开机/睡眠验收，含「开机后放着不管自动睡」与「开机瞬间合盖」，均未踩中约 12 秒的纠正时间窗，指纹唤醒与解锁正常。

## 6. 残留风险

- 开机后约 12 秒的纠正时间窗内若入睡，仍可能唤不醒；
- 驱动更新或设备就地重启后，需等下一次开机/登录触发；
- 只覆盖「驱动声明 WUDF 空闲策略」的设备；厂商若改用别的机制（自研服务、KMDF 策略），本方案不适用。

## 7. 参考

- [User Control of Device Idle and Wake Behavior](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/user-control-of-device-idle-and-wake-behavior)
- [Microsoft Q&A 3751668](https://learn.microsoft.com/en-us/answers/questions/3751668/)
- Linux 侧逆向结论（设备本体只是「哑」传感器，没有 suspend/resume 命令）：[libfprint MR !317](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/317)、[mzr/EgisTec-EH575](https://github.com/mzr/EgisTec-EH575)
