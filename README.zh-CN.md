<div align="center">
  <img src="docs/assets/logo.png" alt="ModelDock 模型坞图标" width="88">
  <h1>ModelDock · 模型坞</h1>
  <p>本地模型，一处掌控。</p>
  <p><a href="README.md">English</a> · <a href="docs/USER_GUIDE.zh-CN.md">中文使用说明</a> · <a href="docs/USER_GUIDE.md">English guide</a></p>
</div>

模型坞是一款原生 macOS 大模型管理工具，把运行引擎、模型文件、下载任务和 API 服务集中管理。下载模型后，选择兼容基座、配置输入能力，再通过独立服务或统一网关接入客户端。

**Apple Silicon · macOS 14+ · 英语、简体中文、法语、葡萄牙语**

![模型坞 Splash 主图与历史 token 生成速度对比](website/assets/splash-hero.png)

*首图为界面宣传插图。速度来自 M4 Max 历史单次实测，量化与缓存不同；使用说明中的截图使用示例数据。*

## 主要功能

- **运行引擎：**检查安装位置和组件版本，安装与更新支持的发行源，启用或隐藏基座，查看卸载与残留清理范围。
- **模型文件：**导入 GGUF、Safetensors 或完整目录，检查文件完整性与适配关系，修复单个文件，保留多个模型版本并为后续启动选择版本。
- **下载任务：**直接解析 Hugging Face 的 `owner/repo`、完整地址、ModelScope 仓库及支持的文件直链；续传任务，查看每个文件的进度，暂停某个文件或优先下载其他文件。
- **模型服务：**设置端口、上下文、纯文本或多模态、基座支持的运行选项；管理多个独立实例，查看启动阶段及草稿、视觉等配套组件。
- **客户端接入：**向 pi、OpenCode 的配置登记模型，保留已有设置；支持直连或 OpenAI 兼容网关，也可把远程兼容 API 加入网关。
- **菜单栏管理：**查看 CPU、内存、磁盘、下载进度和模型实测性能。默认关闭主界面继续后台运行；点击菜单栏面板外部会自动收起。

## 基座适配

| 基座 | 常见模型格式 | 输入与接入方式 |
| --- | --- | --- |
| Splash | 支持的上游 MLX 模型；旧 packed 模型使用匹配的保留运行组件 | 文本；匹配的新版组合支持图片/PDF，并使用适配草稿模型 |
| Llama / llama.cpp | GGUF | 文本；多模态需要模型支持及匹配投影组件 |
| Ollama | 已登记的 Ollama 模型 | 依模型能力而定，由 Ollama 服务管理已加载模型 |
| MLX-LM / MLX-VLM | MLX Safetensors 目录 | MLX-LM 用于文本；MLX-VLM 用于其支持的多模态模型 |
| LM Studio | 依运行时支持 GGUF / MLX | 通过原应用或支持的命令行加载模型 |
| llama.cpp · Prism | 兼容的 GGUF | 架构与选项取决于本地构建版本 |
| Strata · Niko1221 | 已准备的 Flash-Next GGUF / Metal 组合 | macOS 15+ 的实验性 Apple Silicon 源码安装；匹配 MTP 与可选图片组件；本机或外部 API |

格式适配不代表任何架构都能运行。模型坞检查本地文件与启动约束，具体架构和辅助组件仍由实际运行引擎验证。

## 快速开始

1. 从 [Releases](https://github.com/etongle/ModelDock/releases) 下载 Apple Silicon 的 DMG 或 ZIP。
2. 将 **ModelDock.app** 拖到“应用程序”并打开。当前安装包为临时签名，尚未通过 Apple 公证；可信安装包受系统拦截时，参考 [Apple 官方说明](https://support.apple.com/102445)。
3. 在“运行引擎”选择已安装基座，或安装支持的发行版本。Homebrew 管理的基座需要 Homebrew；模型坞自身已附带网关所需的 Python 环境。
4. 在“下载导入”输入 Hugging Face 模型 ID，解析并下载所需文件；已有模型可在“模型文件”中导入。
5. 选择模型与兼容基座，检查纯文本或多模态设置，再启动服务。
6. 在“模型服务 → 一键接入”登记到 pi、OpenCode，或复制服务地址。

**首次启动默认英语。**点击主界面右上角的**地球/语言按钮**，直接选择英语、简体中文、法语、葡萄牙语或跟随系统。也可按 **⌘,** 打开“设置 → 界面语言”，切换立即生效。

完整操作、下载管理、草稿关联、版本更新、删除保护、网关及常见问题见[带配图的使用说明](docs/USER_GUIDE.zh-CN.md)。

**设置 → 应用更新**提供每天检查 GitHub 正式发行版、自动下载与覆盖安装的开关，也可从 **ModelDock → 检查应用更新…** 立即检查。更新先校验安装包，保留模型文件、设置和运行中的模型服务；下载、引擎操作或模型准备未结束时会延后安装。

Strata 在“运行引擎”从官方源码编译 Metal 组件，下载支持的 Flash-Next 量化版本后，点击“准备模型与组件”，再启动服务。普通 Qwen 27B 权重和 Splash DFlash 草稿不能替代 Strata 的 Flash-Next/MTP 配套组合。本版已验证真实 Metal/图片组件构建及隔离的接口测试，尚未完成整套 Flash-Next 权重的实际推理测试。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools 和用于准备可移植运行环境的 Python 3。

```sh
python3 prepare-runtime.py
python3 prepare-notices.py
MM_PYTHON_RUNTIME_DIR="$PWD/build/runtime-cache/python-3.13.16-20261009" bash build.sh
open build/ModelDock.app
```

运行环境固定版本并检查 SHA-256，来源见 `Resources/python-runtime.json`，第三方许可保留在 `Resources/ThirdPartyNotices`。

生成并检查安装包：

```sh
python3 package.py
python3 Tests/packaged_release_checks.py
```

当前程序最低部署目标为 macOS 14，已在开发者现有 Mac 上验证；最低部署目标不表示已对每个旧版系统完成实机测试。

## GitHub 网站

访问[双语项目网站](https://etongle.github.io/ModelDock/)查看介绍和详细图文说明。`website/` 是无需构建的静态网站；更新网站或手动运行附带的 GitHub Actions 工作流即可部署。维护方法见[网站说明](docs/WEBSITE.md)。

## 许可：禁止商业使用

本项目第一方代码与文档采用 **[PolyForm Noncommercial License 1.0.0](LICENSE)**，允许其规定的非商业用途下使用、修改和再分发；没有授予商业使用许可。再分发须保留许可及 Required Notice。

这是**源码可见的非商业项目**，不属于 OSI 定义的开源项目。外部基座、模型权重和附带依赖继续遵守各自许可，详见[许可说明](docs/LICENSING.md)和[Required Notice](LICENSE-NOTICE.txt)。

GitHub Packages：[包下载与发布](docs/PACKAGES.md)；网站访问量：[统计配置](docs/ANALYTICS.md)。
