# OptiScaler Nightly + Mochizuki

给 Windows x64 游戏用的组合安装器。用 [OptiScaler 官方 nightly](https://github.com/OptiScaler/OptiScaler-nightly/releases) 做超分与帧生成，用 [Mochizuki DLSSNR-AMD](https://gitlab.com/mochizuki0323/DLSSNR-AMD/-/releases) 的 ASI 插件做 NR。上游程序文件保持原样。

## 安装

1. 从本仓库的 [Releases](https://github.com/luxingzhi27/optiscaler-nightly-mochizuki/releases) 下载组合安装器 ZIP，解压到本地后运行 `install.cmd`。它会从上游下载指定版本、检查 SHA-256 并组装到 `%LOCALAPPDATA%\OptiScaler-Mochizuki`。
2. 在 Mochizuki 安装界面选游戏实际运行的 EXE（不是启动器），再选 **1) optiscaler**。按所用 Mochizuki 版本的要求选择自己的 `nvngx_dlssnr.dll`；v0.0.9 支持 310.9.16（两套基础模型）和 310.8.0（仅较早的模型）。DLL 由上游安装器在本地读取，不上传。
3. 在兼容游戏里开启 DLSS、FSR 或 XeSS。**Insert** 打开 OptiScaler，**End** 打开 NR Control。卸载时用同一个安装器选择同一个 EXE，再选 **5) Uninstall**。

Windows 的 `tar.exe` 若无法解开 7z，可安装[官方 7-Zip](https://www.7-zip.org/)后重试。请先在单机游戏中测试；不要用于带反作弊的网游。显卡和驱动支持以 Mochizuki 对应 Release 为准。若 D3D12 passthrough 异常，可在 NR Control 的 Network 页面切到 Vulkan bridge 后重启游戏。

## 自动发布

GitHub Actions 每天北京时间 09:17 和 21:17 检查上游，可手动触发。按两边版本组合去重。下载、归档结构或关键配置检查失败时保留旧版，不发新包。Release 是锁定版本的安装引导包，不是离线版；不会镜像 NVIDIA DLL、模型或上游二进制。结构校验通过不等于实际游戏兼容。

## 上游

- [OptiScaler 源码与许可证](https://github.com/OptiScaler/OptiScaler)
- [DLSSNR-AMD 源码与许可证](https://gitlab.com/mochizuki0323/DLSSNR-AMD)
