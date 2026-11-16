# OptiScaler 管理器

一个 Windows x64 窗口，管理官方 OptiScaler nightly、Mochizuki、OptiPatcher、MFG Unlocker，以及可选的 OpenRR 和 ANR。不把 OptiScaler 替换为第三方 fork。

## 开始使用

1. 从 [Releases](https://github.com/luxingzhi27/optiscaler-nightly-mochizuki/releases/latest) 下载管理器 ZIP，解压到长期保留的目录。只需双击 **OptiScaler Manager.cmd**；保留旁边的 `app` 文件夹。若 Windows 提示来源，请核对 GitHub Release 和 SHA-256。
2. 点 **添加游戏**，选择实际运行的 EXE。能识别的旧组合包直接显示「已安装」，添加不会修改游戏文件，也不用先卸载。新游戏点「安装组合包」。
3. 第一次用到 NR 或 OpenRR 时，从窗口导入自己的 DLL。以后新增游戏或更新同类组件，不需要再选择。现有游戏做原地更新，不要求重新导入 DLL 或提取模型。

## 每款游戏分开设置

- **检查更新 / 更新此游戏 / 更新已安装游戏**：检查正式 Release；每套组件下载并校验一次，再逐款原地更新。保留现有 INI、模型和 OpenRR/ANR 配置，不会把停用的 MFG Unlocker 打开。
- **帧生成**：退出游戏，选 ANR 或 XeMFG，再点「切换帧生成」。已装的组件直接复用；没有所选组件才下载。切换后重新启动游戏。ANR 需要游戏提供 NVIDIA/DLSS 帧生成；官方 nightly 的 XeMFG 路径是 DX12 超分输入。切换不会移除 OpenRR，也不会保证所有组合都能在每款游戏中同时生效。
- **启用 OpenRR**：当前面向 RX 9000，需要支持 DLSS 光线重建的游戏。实验性的 OptiFG 宿主桥接不启用。
- **回退**：从选中游戏的备份恢复最近一次可回退的更新或配置操作。文件后来有改动时，管理器会先拒绝覆盖，避免丢设置。

## 本地文件

DLL 库固定在 **`%LOCALAPPDATA%\OptiScaler-Mochizuki\Manager\dlls`**，按类型、版本和哈希保存，原文件移走也能复用。NR 用 `nvngx_dlssnr.dll`（Mochizuki v0.0.9 当前支持 310.9.16 和 310.8.0）；OpenRR 用 `nvngx_dlssd.dll`（310.9.1）。两个 DLL 不能混用。游戏列表和默认 DLL 选项也保存在本机，不上传游戏路径、DLL、配置或模型。

管理器识别本组合的安装布局。现有安装归属不明、游戏仍在运行、模型与新版不兼容，或校验失败时，不会盲目覆盖；请先查看窗口里的提示。新装和更新先在单机游戏测试，不用于带反作弊的网游。

## 发布

GitHub Actions 定时检查上游，并以资产哈希及安装器内容去重。历史 Release 保留。管理器按需更新游戏组件，不自行替换程序代码；只有管理器协议或兼容性变化时才需要新版 ZIP。

上游：[OptiScaler](https://github.com/OptiScaler/OptiScaler) · [Mochizuki](https://gitlab.com/mochizuki0323/DLSSNR-AMD) · [MFG Unlocker](https://github.com/dashdogy/MFG-Unlocker) · [OptiPatcher](https://github.com/optiscaler/OptiPatcher) · [OpenRR-ASI](https://github.com/TheAutomatic/OpenRR-ASI) · [ANR](https://github.com/apex-compute/ANR)
