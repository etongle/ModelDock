# GitHub Packages

ModelDock publishes its existing macOS DMG/ZIP and checksums as an **OCI release-file artifact** at `ghcr.io/etongle/modeldock`. This provides versioned package storage for automation. Open the extracted DMG/ZIP on an Apple Silicon Mac running macOS 14 or later. The package does not run the Mac GUI inside Docker.

For ordinary installation, download from [Releases](https://github.com/etongle/ModelDock/releases).

## Download with ORAS

Install [ORAS](https://oras.land/docs/installation/), then:

```sh
oras pull ghcr.io/etongle/modeldock:0.10.3 --output modeldock-0.10.3
cd modeldock-0.10.3
shasum -a 256 -c SHA256SUMS.txt
open ModelDock-0.10.3-AppleSilicon.dmg
```

`latest` follows the latest stable GitHub Release. A private package needs an ORAS registry login; after it is public, anonymous downloads work.

## Publication

The **Publish release to GitHub Packages** workflow runs when a Release is published. It can also be started manually with an existing release tag such as `v0.10.3`.

It uses the repository's temporary `GITHUB_TOKEN` with `contents: read` and `packages: write`. No personal token or additional secret is needed. ORAS is pinned to an official release and verified archive checksum.

The workflow downloads only the two installers, `INSTALL.txt`, `release.json`, and `SHA256SUMS.txt`; verifies GitHub metadata, file sizes and SHA-256; adds the license/required notice from the release's commit; publishes them with repository/version annotations; downloads the package again and compares all seven files. The source revision points to the application release tag. Older-release replays do not replace `latest`.

## First publication visibility

GitHub initially creates Container registry packages as **private**, even when the linked source repository is public. Open the package → **Package settings → Change visibility → Public** once to allow everyone to download it. See [GitHub's visibility instructions](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility). New versions retain the package's visibility.

The package retains **PolyForm Noncommercial 1.0.0** and the required notices. External dependencies keep their own licenses. No model weights, credentials, or personal configuration are added.

## 中文

GitHub Packages 存放与 Release 相同的 Mac 安装文件，采用 OCI 文件包，可通过 ORAS 下载、验证校验值，再打开 DMG 安装。普通用户直接从 Release 下载安装即可。

发布新 Release 时自动同步，也可手动选择 `v0.10.3` 等已有版本。流程使用临时工作流令牌，不需要个人密钥；发布前校验两个安装文件，发布后重新下载并比较七个文件的 SHA-256。

首次创建的包默认私有，需要在包页面的 **Package settings → Change visibility → Public** 中切换一次，才能让所有人匿名下载。后续版本沿用该设置。模型文件、个人配置和密钥均不加入包；非商业许可继续适用。
