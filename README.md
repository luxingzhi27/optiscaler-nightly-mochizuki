# OptiScaler 管理器

一个 Windows x64 窗口，管理官方 OptiScaler nightly、Mochizuki、OptiPatcher、MFG Unlocker，以及 OpenRR 和 ANR。不把 OptiScaler 替换为第三方 fork。

## 开始使用

1. 从 [Releases](https://github.com/luxingzhi27/optiscaler-nightly-mochizuki/releases/latest) 下载管理器 ZIP，解压到长期保留的目录。只需双击 **OptiScaler Manager.cmd**；保留旁边的 `app` 文件夹。若 Windows 提示来源，请核对 GitHub Release 和 SHA-256。
2. 点 **添加游戏**，选择实际运行的 EXE。能识别的旧组合包直接显示「已安装」，添加不会修改游戏文件，也不用先卸载。新游戏点「安装组合包」。
3. 第一次用到 NR 或 OpenRR 时，从窗口导入自己的 DLL。以后新增游戏或更新同类组件，不需要再选择。现有游戏做原地更新，不要求重新导入 DLL 或提取模型。

## 默认组件与游戏内选择

- **新装或「更新并补齐组件」**：安装 OptiScaler、Mochizuki、OptiPatcher、MFG Unlocker、ANR FG，并准备 OpenRR。旧版如果把 MFG Unlocker 暂停为 `.disabled-anr`，会恢复标准 ASI；**不会重置当前选择的帧生成后端**。每套组件下载校验一次，再逐款使用。
- **帧生成**：按 **Insert** 打开 OptiScaler。在有原生 DLSS 帧生成的游戏里，ANR 选 **NvngxFG 输入**、**FG Nvngx = Apex Neural Rendering FG**；官方 nightly 的 DX12 XeMFG 选 **Upscaler 输入、XeFG 输出**。两者同时装好，一次只运行一个。改完保存，按菜单提示重启；不需要移除插件。
- **OpenRR**：组件默认准备好。仅当识别为 RX 9000 且本机已有匹配的 RR DLL 时才自动启用；否则保持未加载，可在管理器检查并导入后启用。不会启用实验性 OptiFG 宿主桥接。
- **回退**：从选中游戏的备份恢复最近一次可回退的更新或组件操作。文件后来有改动时，会先拒绝覆盖。

## 本地文件

DLL 库固定在 **`%LOCALAPPDATA%\OptiScaler-Mochizuki\Manager\dlls`**，按类型、版本和哈希保存，原文件移走也能复用。NR 用 `nvngx_dlssnr.dll`（Mochizuki v0.0.9 当前支持 310.9.16 和 310.8.0）；OpenRR 用 `nvngx_dlssd.dll`（310.9.1）。两个 DLL 不能混用。游戏列表和默认 DLL 选项也保存在本机，不上传游戏路径、DLL、配置或模型。

管理器识别本组合的安装布局。现有安装归属不明、游戏仍在运行、模型与新版不兼容，或校验失败时，不会盲目覆盖；请先查看窗口里的提示。新装和更新先在单机游戏测试，不用于带反作弊的网游。

## 发布

GitHub Actions 定时检查上游，并以资产哈希及安装器内容去重。历史 Release 保留。管理器按需更新游戏组件，不自行替换程序代码；只有管理器协议或兼容性变化时才需要新版 ZIP。

上游：[OptiScaler](https://github.com/OptiScaler/OptiScaler) · [Mochizuki](https://gitlab.com/mochizuki0323/DLSSNR-AMD) · [MFG Unlocker](https://github.com/dashdogy/MFG-Unlocker) · [OptiPatcher](https://github.com/optiscaler/OptiPatcher) · [OpenRR-ASI](https://github.com/TheAutomatic/OpenRR-ASI) · [ANR](https://github.com/apex-compute/ANR)
