# AndroidDeck

面向 Apple Silicon Mac 的原生 Android 工作台。使用 Swift、AppKit 和 Metal 构建桌面界面，基于 Android Emulator 运行真实 Android 和 APK，支持键盘到多点触摸的自定义映射。

本仓库仅发布工程源码、测试与构建脚本，采用 **GPL-3.0-only**。不包含安装包、第三方 APK、Android SDK、虚拟设备、账号数据或签名密钥。

## 功能

- 真实 Android 14 ARM64 虚拟设备及 APK 安装。
- 点击、长按、连点、滑动轨迹、双指缩放与旋转、方向摇杆和声音按键。
- 每个应用独立保存键位方案，支持导入、导出和快速点选设键。
- 原始 RGBA 画面、Metal 显示，以及 H.264 / VideoToolbox 兼容通道。
- 应用滚轮翻页、横竖屏、720p 至 4K 分辨率偏好、6 / 8 GB 运存配置。
- 原生全屏、悬浮工具栏、外接屏投影及已授权 Android 设备投屏。
- 设备磁盘、内存、系统版本和 CPU 信息。

它使用成熟的 Android 虚拟化引擎，不是从零实现的 CPU、GPU 或 Android 内核。

## 构建要求

- Apple Silicon Mac，macOS 13 或更高版本。
- Xcode 或 Command Line Tools，包含 Swift、Clang 和 macOS SDK。
- Python 3.9 或更高版本；构建原生界面不需要 Node.js 或 Electron。
- 运行 Android 需要自行准备 Google Android Emulator、Android 14 AOSP ARM64 镜像及 ADB。

## 从源码构建

```sh
git clone https://github.com/fanjiashu/AndroidDeck.git
cd AndroidDeck
python3 scripts/build-native.py
```

应用生成在仓库上一级目录的 `AndroidDeck.app`。源码版允许缺省图标与应用图片，会使用系统图标或文字标记；无需商业应用素材也能编译。

可通过环境变量指定构建缓存与输出包名：

```sh
ANDROIDDECK_BUILD_CACHE="$PWD/.cache/swift-modules" \
ANDROIDDECK_BUNDLE_NAME=AndroidDeck-dev.app \
python3 scripts/build-native.py
```

## 准备 Android 运行依赖

安装脚本从 Google 官方源获取校验固定版本的 Emulator 与系统镜像，并准备 ADB；scrcpy 服务组件从其官方 GitHub Release 下载并校验 SHA256。依赖体积较大，使用前请阅读各自许可与使用条款。

```sh
python3 scripts/setup-runtime.py
./启动.command --runtime-root="$PWD"
```

显式指定 `--runtime-root` 可让开发设备保存在当前源码目录中，避免与已安装版本共用设备。`.runtime/` 和 `data/` 均已忽略，不应提交到 Git。

开源版的内置第三方应用清单默认为空。启动设备后，通过“安装 APK”选择你自行取得、有权使用的 APK。

## 测试用 APK

触控试验场的 Java 源码和清单位于 `demo/`。构建它还需要 JDK、Android SDK build-tools 与 platforms：

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
python3 scripts/build-demo.py
```

生成的 `assets/TouchLab.apk` 和开发测试密钥仅用于本机，不进入仓库。

## 检查与测试

```sh
python3 -m py_compile scripts/*.py
python3 scripts/test-native.py
```

以下检查会与真实设备交互，只应用于独立测试设备：

```sh
python3 scripts/test-joystick.py emulator-5580
python3 scripts/test-gestures.py emulator-5580
```

不要对正在使用的账号设备执行集成测试。测试可能安装触控试验场、改变方向或重新启动测试设备。

## 运行说明

画面默认使用内存管道，避免高频写入普通磁盘文件；快速启动快照默认关闭，可显式使用 `--quick-boot`，`--cold-boot` 优先禁用快照。保留的文件支持 mmap 实验通道不代表零 SSD 写入，不作为默认传输方式。

分辨率偏好按应用保存。切换应用保留当前 Android 进程与实际分辨率；点击“应用分辨率并重启”才改变设备物理画面尺寸。静态页面的画面更新计数可能为 0，它不是游戏内部战斗帧率。

`native/EGLCompatibility.md` 说明针对固定 AOSP 驱动的 EGL 上下文标志兼容修正。项目不提供规避游戏反作弊或模拟器检测的承诺。

## 目录

| 目录 | 内容 |
| --- | --- |
| `native/` | Swift/AppKit 界面、C HTTP/2 桥接、设备生命周期、画面与输入引擎 |
| `scripts/` | 构建、依赖准备、打包和验证脚本 |
| `demo/` | Android 触控试验场源码 |
| `src/`、`tests/` | 保留的旧 Electron 实现及历史测试；当前原生应用不加载它们 |
| `assets/` | 空的内置应用清单及第三方许可说明 |

旧版 Electron 实现可在安装对应依赖后使用 `npm run legacy:start`。它只作为历史实现保留。

## 许可

AndroidDeck 自有源码使用 [GNU General Public License v3.0](LICENSE)，SPDX 标识为 `GPL-3.0-only`。

Google Android 组件、scrcpy 以及平台框架遵循各自许可，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。商业游戏、应用名称及图标的权利属于各自权利人，不包含在本仓库的开源授权中。

