# TyFPJDBC 单仓 Release 规格（runtime 合仓 + Actions 全套）

版本：0.1（brainstorming 三节已确认，待评审后转 implementation plan）
日期：2026-10-01
基线：master（Cycle 2 已合入；`TyFPJDBC-Runtimes` 为纯本地仓，无 remote）
目标：runtime 发布收敛到主仓：tag 一打，5 平台 JRE 自动构建、清单回填、挂到同一 Release；bridge/JDK 任一升级都是“打 tag 或点按钮”的事。

## 0. 约束（已确认）

- 单仓：`ACTom/TyFPJDBC` 为唯一远端；`TyFPJDBC-Runtimes` 不再建远端，本地迁移后归档。
- `zips/` 永不进 git（产物只活在 Release assets + CI artifacts）。
- 触发两者都要：`workflow_dispatch`（填参）+ `push.tags: runtime/*`。
- runtime tag 形如 `runtime/jre25.0.4.1-bridge0.9.0`（JDK 与 bridge 双版本进 tag）。
- mautool Release 下载模式本次一起做。
- 除 `GITHUB_TOKEN` 不新增 secret；除主仓 Contributors 不新增权限。

## 1. 合仓迁移（已确认）

- `Runtimes/scripts/build-jlink.ps1`、`build-runtime-zip.ps1` → 主仓
  `scripts/runtime/`（内容先原样搬，跨机 jlink 部分由 §2 废弃；确定性打包脚本一字不动）。
- `manifests/runtimes.json` 并入主仓 `configs/runtimes.json`：字段沿用
  （platform/jdkVersion/jdkVendor/build/modules/asset/packedBytes/
  unpackedBytes/bridgeVersion/url/sha256），新增 `releaseTag`（所属 Release
  的 tag，如 `runtime/jre25.0.4.1-bridge0.9.0`），`url` 改为该 Release 下的
  asset 地址。
- `mautool --verify-manifests` 改为单清单自检：字段齐全、sha256 为 64 位
  hex、体积预算（解包 ≤ 80MB，zip ≤ 50MB）、`bridgeVersion` 等于
  `java/bridge/.../Bridge.java` 的 `VERSION` 常量。
- `Runtimes/logs/` 为空，不迁；`stages/`、`build/` 本来就不提交。
  `.gitignore` 加 `*.zip` 防误提交（`jre-25-*.zip` 形态）。
- 本地 `D:\Projects\TyFPJDBC-Runtimes` 迁移验证后改名归档（删不删另定，
  不在本 spec 内）。

## 2. `runtime-release.yml`（已确认）

- 输入（dispatch）：`jdk_version`（默认 `25.0.4.1`）、`jdk_vendor`
  （默认 `Microsoft`，固定）、`bridge_ref`（默认触发 commit）、
  `platforms`（多选，默认全量：win64/linux-x64/linux-arm64/
  macos-x64/macos-arm64）。tag 触发时从 tag 名解析出 JDK 与 bridge 版本。
- 首步 fail-fast：解析出的 `bridgeVersion` 必须等于主仓
  `Bridge.VERSION`（读文件 grep），不等即 fail。
- `build` 矩阵（平台原生 jlink，删除跨机 workaround）：
  win64→windows runner，linux-x64→ubuntu，linux-arm64→ubuntu-arm，
  macos 双 arch→对应 mac runner（runner label 按实现时 GitHub 在售列表
  钉死并注释；若 macOS-Intel 无可用 runner，该平台回退旧跨机脚本，
  为唯一的例外路径）。
- 每平台步骤：checkout 主仓（`bridge_ref`）→ `setup-java`（microsoft, 25）
  → `javac` 编 `Bridge.java`（HikariCP 5.1.0 + slf4j-api 2.0.9 从 Maven
  Central 拉，校验非空 + `jar tf` 有类）→ 组 `BridgeDir`
  （Bridge.class + 两 jar + drivers/README）→ `jlink`（固定 flags：
  `--disable-plugin generate-jli-classes --vm server`，
  9 模块 `java.base,java.sql,java.naming,java.logging,java.management,
  java.xml,java.security.sasl,jdk.unsupported,java.transaction.xa`，
  `--strip-debug --no-man-pages --no-header-files --compress=zip-9`，
  `--exclude-resources "**/classes*.jsa"`）→ `build-runtime-zip.ps1`
  打包（PowerShell 7 全 runner 自带；时间戳固定逻辑沿用）。
- 每平台验证（fail 即停）：`jvm` 可执行文件存在（win64 另跑
  `java -version`）；`bridge/` 三件套齐；解包/zip 体积预算；
  sha256 落盘到 job 输出。
- `release` job：收齐所选平台包 → 回填 `configs/runtimes.json`
  （packedBytes/unpackedBytes/sha256/bridgeVersion/jdkVersion/
  releaseTag/url）→ commit 回 master（`contents:write`）→ 建 Release
  （tag 即触发 tag；dispatch 触发时 tag 名由输入版本号合成，
  workflow 负责 `git tag`+push）→ 传 5 包 + 构建日志 + 清单片段进
  Release notes。并发组限单跑。
- 权限：`contents: write` 仅此。Secret：无（`GITHUB_TOKEN` 自带）。

## 3. mautool Release 下载（已确认）

- 新模式 `mautool --fetch-runtime --platform <p> --out <dir> [--tag]`
  （`--tag` 缺省读 manifest 的 `releaseTag`）：拼
  `releases/download/<tag>/<asset>` → 复用已修好的下载 plumbing
  （`RunDownload`，无黑框）→ sha 验（取 manifest 同平台条目）→
  原子落盘；`MISMATCH` 删件语义与 `FetchJar` 对齐。
- `--verify-runtime` 语义不变（验本地文件）；`TestDistrib` 加纯 URL
  拼装断言（无网络），真下载手动验一次。
- Step 0 前提：主仓已 push 到 `ACTom/TyFPJDBC`（空仓由人建，remote
  现在是空的，推不上去）。

## 4. 非目标（已确认）

- 全矩阵（PG/MySQL 容器 + FPC 套件）不进 CI，留本机。
- JDK 新版巡检/自动 dispatch（phase 3），本次不做。
- 已有 `ci.yml`（guard）不动；新旧 workflow 共存。

## 5. 验收（已确认）

- 空仓 push → 手动 dispatch 一次全量 → Release 出现 5 包 + manifest
  回填 commit → `mautool --fetch-runtime` 拉回验过 →
  `mautool --verify-manifests` 绿 → 本机矩阵关键段（guard/smoke/
  TestEngine/TestLcl）绿。
