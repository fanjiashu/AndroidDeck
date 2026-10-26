# 第三方依赖

本仓库不分发 Android 运行组件或第三方应用二进制。AndroidDeck 自有源码的 GPL-3.0-only 不替代以下项目或平台的许可。

| 依赖 | 来源与许可 |
| --- | --- |
| Android Emulator、ADB、Android 系统镜像 | [Google Android 开发者文档](https://developer.android.com/studio/run/emulator-commandline)，遵循各组件随附条款；由用户单独准备 |
| scrcpy 3.3.4 | [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy/tree/v3.3.4)，Apache License 2.0；正文保留于 `assets/LICENSE-scrcpy.txt`，服务二进制不入库 |
| Swift、AppKit、Metal、VideoToolbox、Accelerate | 由 Apple 工具链和 macOS 提供，遵循各自许可与平台条款 |
| libcurl | 使用 macOS 系统库；[curl 许可](https://curl.se/docs/copyright.html) |
| Electron 及 npm 依赖 | 仅用于 `src/` 中的历史实现，由 `package-lock.json` 记录；依赖不入库，遵循各包许可 |

`native/EGLCompatibility.swift` 保存用于校验本机固定驱动的哈希和少量修正指令，不分发 Google 驱动文件。

第三方 APK、应用图标、游戏资源、用户映射和设备账号数据均不在仓库中。

