# EGL 上下文标志兼容修正

适用镜像：Android 14 AOSP ARM64 r04。和平精英 1.38.12 在 `eglCreateContext(1755)` 连续收到 `EGL_BAD_ATTRIBUTE`，随后 `libUE4.so` 调用空的纹理函数指针而崩溃。

独立 EGL 探针确认：`EGL_CONTEXT_FLAGS_KHR=0` 被拒绝，`1` 被接受，非法值 `9` 也被接受。驱动的校验为“至少包含一个已知标志位”；[EGL_KHR_create_context](https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_create_context.txt) 规定默认值为零，应拒绝未定义的位。

参考实现：[gfxstream 的 eglCreateContext](https://github.com/google/gfxstream/blob/main/guest/egl/egl.cpp)。本修正把该条件改成“没有未知标志位”，保留已有驱动的其它行为。它不是对全部 EGL 规范条款的重新实现。

## 精确指纹与可复现字节变更

`/vendor/lib64/egl/libEGL_emulation.so` 原始 SHA256：

```
f548cce6ed2fd6481ffb82c4d6dbc151cc8b48f638f79c2e4f30c8afdccdb67c
```

修正后 SHA256：

```
52ee8a9cc324dd7972738a1c4d76bd862fd2c26a8d5d866dd8daf09c7fc0bd2e
```

文件偏移 `0x157f8` 的两个 AArch64 指令，按小端字节编码：

| 位置 | 原指令 | 修正指令 |
| --- | --- | --- |
| `0x157f8` | `720009df`: `tst w14,#7` | `721d71df`: `tst w14,#~7` |
| `0x157fc` | `54fffe81`: `b.ne 0x157cc` | `54fffe80`: `b.eq 0x157cc` |

八字节范围中实际改变三个字节；文件长度、ABI、其它代码和数据不变。`EGLCompatibility.correctedDriver` 对整文件指纹、原指令和结果指纹分别验证，拒绝未知或损坏的驱动。修正值直接从本机原始库生成，打包资源仍使用原始 Google SDK；不额外分发修改后的预编译驱动。

## 加载与恢复

仅在 AndroidDeck 拥有的 AOSP 设备中加载。修正库保留 `same_process_hal_file` 标签，以绑定挂载覆盖当前运行实例的 EGL 库路径；不关闭 SELinux 或修改系统镜像。上传使用独立临时文件，避免改写已经映射的库。驱动指纹进入快速启动兼容键，每次启动、恢复和打开应用会重新核验。

冷启动会回到原系统镜像，再自动准备修正。调试回滚可在本应用拥有的设备中卸载该绑定挂载并重新启动 Android；原始库和游戏 APK 没有被覆盖。

## 验证入口

```sh
ANDROIDDECK_EGL_TEST_DRIVER=/path/to/original/libEGL_emulation.so python3 scripts/test-native.py
python3 scripts/test-egl-runtime.py /private/tmp/AndroidDeck-pubgm-graphics
```

运行后者前，应将停止设备的 AVD 克隆到独立测试目录，并配置只读 SDK 访问。该测试检查硬件渲染、游戏实际映射的 inode、90 秒稳定运行、重复启动、DNF/红果回归及快速启动恢复；它不会自动接受游戏协议或登录。
