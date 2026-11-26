# PostgreSQL 自定义扩展构建说明

这个仓库用于在 Supabase Postgres 上维护自定义 PostgreSQL 扩展构建。当前模式是：在本仓库的定制分支中维护扩展补丁，GitHub Action 自动基于 Supabase upstream 最新稳定 PG17 release 签出源码，叠加本仓库的扩展修改，然后构建 Nix 包和多架构 Docker 镜像。

## 当前自定义扩展列表

| 扩展 | 当前版本 | 上游地址 | 接入范围 | 是否预加载 | 说明 |
| --- | --- | --- | --- | --- | --- |
| `pg_durable` | `0.2.9` | `https://github.com/microsoft/pg_durable` | `psql_17`、`psql_17_slim`、`psql_orioledb-17`、`psql_orioledb-17_slim` | 是，追加 `pg_durable` | Durable SQL Functions for PostgreSQL。上游明确支持 PG17/PG18；本仓库将其作为标准 PG17 和 OrioleDB17 共享扩展构建。 |
| `pg_duckdb` | `1.2.2` | `https://github.com/duckdb/pg_duckdb` | `psql_17`、`psql_17_slim` | 是，追加 `pg_duckdb` | DuckDB Embedded in Postgres。当前只接入标准 PG17；暂不接入 OrioleDB17，因为 OrioleDB 的 `TableAmRoutine` ABI 与标准 PostgreSQL 17 不兼容。 |

### 当前版本说明

- 2026-11-26 已将 pg_duckdb 1.2.2 升级及上游 Nix 打包接口修复合并到默认分支 `custom-extensions`，并通过 [完整发布工作流](https://github.com/deluxebear/postgres/actions/runs/45824804647) 发布标准版 [17.12.0.005](https://github.com/deluxebear/postgres/releases/tag/postgres-17.12.0.005) 和 [17.11.0.024-orioledb](https://github.com/deluxebear/postgres/releases/tag/postgres-17.11.0.024-orioledb)。四个原生架构任务均完成 Nix 构建、安装及升级测试、Docker 构建推送，两组多架构 manifest 和 GitHub Release 均发布成功。标准版包含 pg_duckdb `1.2.2`，两类镜像均包含 pg_durable `0.2.9`，浮动标签 `17`、`orioledb-17` 已更新。
- 标准版 manifest 为 `sha256:df97707e94993d732579615d6f1a3434bee1e50a72e2e7ffa94c91f12a16da57`，OrioleDB 版为 `sha256:57ce940cc01d291f680821ac69f37f3743fc6ec6faeba965b3126255831ef4bd`。发布源码提交分别为 `ff0ce61269609e82ad26a9933294cabe29deb7c8` 和 `b5386ca7b37e41201a83a60c026a19a05b994a42`，标签指向叠加定制补丁的上游源码快照。

- `pg_durable 0.2.9` 是官方 GitHub 于 2026-10-07 发布的最新稳定版本，release 见 [v0.2.9](https://github.com/microsoft/pg_durable/releases/tag/v0.2.9)。上游源码继续使用 pgrx `0.16.1`，保留 `pg17` 构建特性，并提供 `pg_durable--0.2.8--0.2.9.sql` 升级路径。源码包和 `Cargo.lock` 均固定到该 release 并校验 SHA-256。
- `0.2.9` 新增共享控制运行时的多数据库安装、`df.with_http_options`、HTTP 端点和显式 secret 绑定，并加强内部 SQL 的名称解析。HTTP 策略从 Cargo 特性迁移到需要重启的 `pg_durable.http_security` 参数，默认 `restricted`；通过 `pg_durable.http_allowed_domains` 配置域名。原有 `http-allow-azure-domains` 构建特性已移除，本仓库使用上游默认的 Azure 服务子域和 `api.github.com` 白名单。
- 从 `0.2.8` 升级时，先安装新二进制并重启，等待控制运行时就绪，再执行 `ALTER EXTENSION pg_durable UPDATE TO '0.2.9'`，之后创建卫星数据库安装。为已有 HTTP 用户启用新增的端点接口时，重新调用 `df.grant_usage('角色名', include_http => true)`。此前禁用 HTTP 的部署应在重启前设置 `pg_durable.http_security = 'disabled'`。详见上游 [升级指南](https://github.com/microsoft/pg_durable/blob/v0.2.9/docs/upgrade-testing.md#v028--v029)。
- 2026-10-12 已通过 [GitHub Actions 验证](https://github.com/deluxebear/postgres/actions/runs/38158866754) 完成标准 PG17 `17.11.0.004` 与 OrioleDB17 `17.11.0.004-orioledb` 的 amd64/arm64 原生 Nix 构建、全新安装及真实二进制升级测试：使用 `0.2.8` 创建数据库并执行工作流，重启到 `0.2.9` 后执行 `ALTER EXTENSION UPDATE`，确认原有函数 OID、已完成工作流结果、新 HTTP 接口和后续工作流执行均正常。测试不覆盖升级时仍在运行的历史回放。本次仅验证构建，未发布 Docker 镜像或 GitHub Release；下方已发布镜像的验证记录仍对应 `0.2.8`。
- 升级到 `0.2.8` 前，应先清空已在第 100,000 次迭代记录旧终止失败路径且要求连续回放的长循环；这类执行历史不能在新的 8,388,608 次循环上限下重放。
- 从 `0.2.5` 或更早版本升级时，应检查是否存在依赖未公开函数 `df.ensure_durofut(text)` 的自定义对象；该函数已在 `0.2.6` 移除。应用不应持久化内部 `Durofut` JSON envelope 后跨版本回放。
- `pg_duckdb 1.2.2` 发布于 2026-11-23，内嵌 DuckDB `2.0.1`，SQL 扩展版本为 `1.2.2`。本次源码、DuckDB 子模块和 httpfs 均按该标签固定并校验 SHA-256。构建使用上游 `ReleaseStaticSystem` 模式，静态链接 DuckDB/httpfs，并使用 Nix 提供的 curl/OpenSSL。见 [上游 release](https://github.com/duckdb/pg_duckdb/releases/tag/v1.2.2)。
- 从旧包 `1.1.1` 升级时，数据库中的旧 SQL 版本为 `1.1.0`。安装新二进制并重启后，在每个已安装扩展的数据库中执行 `ALTER EXTENSION pg_duckdb UPDATE TO '1.2.2';`。上游提供连续的 `1.1.0 → 1.2.0 → 1.2.1 → 1.2.2` 升级脚本。
- `1.2` 系列新增非 public schema 安装、`read_vortex`、`read_text`、`read_blob` 和 `duckdb.variant`，并调整 `iceberg_snapshots` 的返回类型。升级前检查依赖该函数及其返回类型的自定义对象，升级脚本会删除并重建它们。MotherDuck、远程存储和额外下载的 DuckDB 扩展需要各自验证服务及版本兼容性。见 [SQL 升级脚本](https://github.com/duckdb/pg_duckdb/blob/v1.2.2/sql/pg_duckdb--1.1.0--1.2.0.sql)。
- `scripts/test-pg-duckdb-upgrade.sh` 覆盖 SQL 升级、非 public schema 全新安装、heap 表聚合、内嵌引擎版本、httpfs 加载和 dump/restore，并接入标准 PG17 的 amd64/arm64 发布构建。该脚本使用新版二进制验证旧 SQL 对象的升级路径，2026-11-26 已在本机 Linux ARM64 容器中完成标准 PG17 17.6 的 Nix 源码构建和该脚本验证，另以旧版 1.1.1 二进制创建数据后重启到新版，确认升级成功且旧表聚合结果正确。GitHub Actions 的多架构验证结果见下一项记录。
- 2026-11-26 已通过 [GitHub Actions 验证](https://github.com/deluxebear/postgres/actions/runs/45811317501)，构建提交为 `8af9ea4e48801d8b1c46b4e765b62d8e6a88e014`。标准 PG17 `17.12.0.005` 与 OrioleDB17 `17.11.0.024-orioledb` 的 amd64/arm64 原生 Nix 构建均成功。标准 PG17 两个架构通过 pg_duckdb SQL 升级、非 public schema 安装、引擎版本及 httpfs 检查、heap 表查询和 dump/restore，四个构建均通过 pg_durable 安装及真实旧二进制升级回归。本次同步上游 PostgreSQL 包入口、pgroonga 与 Rust 工具链参数，并修复旧版升级测试的项目工具链导入。运行参数为 `build_docker=false`，Docker 构建、镜像发布及 GitHub Release 发布未执行。
- `pg_durable` 的 Cargo 依赖通过 crates.io 官方静态下载地址获取，避开 API 下载端点的 HTTP 403；仍使用上游 `Cargo.lock` 中的固定版本和 SHA-256 校验和。
- 2026-09-13 已通过 [GitHub Actions 定向重建](https://github.com/deluxebear/postgres/actions/runs/34705317456) 完成标准 PG17 `17.6.1.171` 与 OrioleDB17 `17.9.0.024-orioledb` 的 amd64/arm64 Nix 构建、Docker 推送、多架构 manifest 和 GitHub Release 更新（[标准版 Release](https://github.com/deluxebear/postgres/releases/tag/postgres-17.6.1.171)、[OrioleDB 版 Release](https://github.com/deluxebear/postgres/releases/tag/postgres-17.9.0.024-orioledb)）。镜像 `deluxebear/postgres:17.6.1.171` 的 manifest digest 为 `sha256:416ba1fe084c6bb942ee73a5e47b679458e0b28d7349d2728269502574bfc519`，`deluxebear/postgres:17.9.0.024-orioledb` 的 manifest digest 为 `sha256:70646a3b1fbc0aba472ba331d4e5d9c6b2c580c7515ac972a41cb3d63cadd072`。直接检查 ARM64 镜像确认两者均包含 Nix 包 `pg_durable-0.2.8`、`pg_durable.control` 默认版本 `0.2.8` 和升级脚本 `pg_durable--0.2.7--0.2.8.sql`；数据库运行时也已分别通过全新安装，以及复用 `0.2.7` 数据目录后执行 `ALTER EXTENSION pg_durable UPDATE TO '0.2.8'` 的原地升级验证。

## 使用项目技能

本项目提供了一个本地 Codex 技能：

```text
$postgres-custom-extension-build
```

技能位置：

```text
.codex/skills/postgres-custom-extension-build/
```

当需要引入或升级自定义扩展时，可以直接这样提需求：

```text
Use $postgres-custom-extension-build to add <extension-name> to PostgreSQL 17.
Use $postgres-custom-extension-build to update <extension-name> to its latest stable release for PostgreSQL 17 and OrioleDB 17.
```

这个技能会引导 Codex 按本项目约定处理：

- 对每个指定扩展检查其官方 GitHub 仓库的最新稳定 release
- 分别验证标准 PostgreSQL 与 OrioleDB 目标兼容性，通过后才更新版本
- 在专门分支维护自定义扩展代码
- 添加 `nix/ext/<extension>.nix`
- 将扩展接入 `psql_17`，并在确认兼容时接入 `psql_orioledb-17`
- 正确处理 `shared_preload_libraries`
- 更新 Dockerfile、Ansible、pgctld 模板和测试快照
- 同步更新 README 中的版本、目标范围、预加载要求和兼容性说明
- 通过 GitHub Action 基于 upstream release 重新构建
- 发布 Docker Hub 镜像和对应 GitHub Release

开始前可以运行技能自带检查脚本：

```bash
.codex/skills/postgres-custom-extension-build/scripts/check_repo_state.sh
```

## 自定义扩展接入与升级流程

推荐在定制分支上工作：

```bash
git checkout custom-extensions/pg-durable
```

升级已有扩展时，先从扩展的官方 GitHub Releases 确认最新稳定版本，排除 draft、prerelease、RC、preview 和 nightly 版本；再检查 release notes、上游 PostgreSQL 支持声明及构建配置，并对标准 PG17 与 OrioleDB17 分别构建和测试。只有所有请求目标都通过兼容性验证后才更新版本、源码与依赖哈希、必要的升级脚本及下方扩展列表。若某个目标不兼容，保留当前版本和接入范围并说明阻塞原因，不静默降级、拆分版本或移除目标。

新增扩展时，通常需要完成这些修改：

1. 在 `nix/ext/` 下添加扩展 Nix 包，例如：

```text
nix/ext/pg_durable.nix
```

2. 在 `nix/packages/postgres.nix` 中加入目标扩展集合。

当前 PG17 扩展按兼容性拆分。

只适用于标准 PostgreSQL 17 的扩展使用：

```nix
pg17StandardOnlyExtensions = [
  ../ext/pg_duckdb.nix
];
```

同时适用于标准 PostgreSQL 17 和 OrioleDB17 的扩展使用：

```nix
pg17SharedExtensions = [
  ../ext/pg_durable.nix
];
```

`pg17StandardOnlyExtensions` 会被加入：

```text
psql_17
psql_17_slim
```

`pg17SharedExtensions` 会被加入：

```text
psql_17
psql_17_slim
psql_orioledb-17
psql_orioledb-17_slim
```

例如：`pg_duckdb v1.2.2` 可以编入标准 PG17，但当前不能直接编入 OrioleDB17，因为 OrioleDB 的 `TableAmRoutine` ABI 和标准 PostgreSQL 17 不一致；`pg_durable` 当前继续作为共享扩展编入两类 PG17 构建。

3. 如果扩展需要预加载，追加到 `shared_preload_libraries`，不要覆盖已有值。

重点检查这些文件：

```text
nix/tools/run-server.sh.in
ansible/tasks/stage2-setup-postgres.yml
Dockerfile-17
Dockerfile-orioledb-17
Dockerfile-multigres
docker/pgctld/postgresql.conf.tmpl
docker/pgctld/orioledb-postgresql.conf.tmpl
```

4. 如果扩展改变了可见 SQL 接口，更新 `nix/tests/sql/` 和 `nix/tests/expected/` 中对应 PG17 和 OrioleDB17 的测试快照。

5. 确认 GitHub Action 的 `patch_paths` 包含新增或修改的文件：

```text
.github/workflows/upstream-pg17-release-build.yml
```

## 构建方式

### 便携二进制包（无需 Docker / Nix）

`.github/workflows/cli-release.yml` 基于上游 `v17.12.0.005-cli` 的 CLI Release 流程改造，独立于下方 Docker 发布流程。每 6 小时检查 Supabase 最新稳定 PG17 `*-cli` release；排除 draft、prerelease、test、RC、preview 等版本，已发布的上游版本直接跳过。只有出现新的上游 CLI release 时才自动构建，扩展单独发布新版不会触发重发。

每次构建都从官方 GitHub Releases 解析 `pg_duckdb` 和 `pg_durable` 的最新稳定版本，固定 release tag、commit、源码 SHA-256、DuckDB/httpfs 子模块及 Cargo.lock。动态版本只写入当次上游源码快照，不修改当前 Docker/Nix 包的版本固定值。如果上游构建布局、PostgreSQL 支持或 pgrx/Rust 工具链不兼容，任务失败并停止发布，不退回旧扩展版本。新增 pgrx/Rust 组合需要先在项目的 `nix/cargo-pgrx/versions.json` 中维护并验证支持。

沿用上游的三个原生构建目标：Linux x64、Linux ARM64、macOS ARM64（使用当前支持的 `macos-15` runner）。保留 CLI 精简扩展，并加入 `pg_duckdb` 和 `pg_durable`；配置模板保留已有预加载库并追加这两个库。打包后在独立的无 `/nix/store` runner 上验证重定位、初始化、扩展安装、DuckDB 查询与 httpfs 加载、durable 工作流执行、重启、dump/restore 和 pg_duckdb 随包可安装的前序 SQL 版本升级。已有定制便携版 release 时，还会下载并校验对应平台的前版包，用真实旧二进制创建数据和执行 durable 工作流，再切换新二进制升级两个扩展，验证数据、已完成结果及新工作流；首次发布没有前版包时明确记录未执行该项。不保证升级时仍在运行的 durable 工作流能够跨版本回放。

发布 tag 示例为 `postgres-17.12.0.005-cli`，指向实际构建的定制上游源码快照；不覆盖已有 tag 或完成的 release。全部平台通过后才上传草稿并正式发布。附件包括各平台 `.tar.gz`、`.sha256` 和 `.extensions.json`；包内的 `portable-release.json` 记录源码和依赖哈希。Release 说明包含两个定制扩展的版本、官方 release 链接，以及从实际 `.control` 文件提取的全部随包 SQL 扩展默认版本。三平台扩展版本或来源不一致时停止发布。

可手动验证或发布：

```bash
# 只构建和测试，不推送 tag 或发布；即使已有 release 也会执行验证
gh workflow run cli-release.yml --ref custom-extensions -f publish=false

# 发布最新稳定上游版本（已发布则跳过）
gh workflow run cli-release.yml --ref custom-extensions -f publish=true

# 指定一个稳定 PG17 CLI release 进行构建验证
gh workflow run cli-release.yml --ref custom-extensions \
  -f upstream_ref=v17.12.0.005-cli -f publish=false

# 仅修改测试脚本时，复用某次运行已成功构建的三平台产物，避免重新编译
# 此模式只验证，禁止发布，不改写原始产物及其来源记录
gh workflow run cli-release.yml --ref custom-extensions \
  -f artifact_run_id=<run-id> -f publish=false
```

定时任务需要此 workflow 存在于仓库默认分支，并在 Actions 设置中启用。Linux 包以 Ubuntu 24.04 为无 Nix 验证环境，仍依赖宿主 glibc，不适用于原生 Alpine/musl。解压后可通过 `bin/initdb`、`bin/pg_ctl` 和 `bin/psql` 管理数据库；生产部署的用户、数据目录、认证、密钥管理及 systemd 服务需另行配置。

此流程的验证统一在 GitHub Actions 上执行：源码准备任务运行发布逻辑单元测试和 Shell 静态检查，随后执行三个平台的原生构建与无 Nix 运行测试。运行测试通过后，即使 `publish=false` 也会核对三平台全部扩展版本、来源和 SHA-256，并生成可审阅的发布说明附件。开发时通过 `publish=false` 触发验证，不在本机进行构建或运行验证；仅调整验证脚本时可使用 `artifact_run_id` 对同一份已构建产物重测，该模式没有发布权限路径。

其中逻辑 dump/restore 检查针对独立数据库中的 pg_duckdb 与用户表；pg_durable 检查工作流执行及重启后已完成结果保留。未验证 durable 控制数据库的逻辑备份恢复，不应将控制数据库直接用通用 pg_restore 复制为卫星数据库。

便携版在附件上传完成并转为正式发布时自动设为 GitHub Latest，常规发布和补发流程均适用；草稿阶段不更改 Latest。

### Docker 镜像

核心 Action：

```text
.github/workflows/upstream-pg17-release-build.yml
```

它会自动：

- 从 `supabase/postgres` releases 中选择最新稳定 PG17 release
- 排除 draft、prerelease 和包含 `test` 的 release
- 分别选择标准 PG17 和 OrioleDB17
- checkout upstream release 源码
- 将本分支的自定义扩展 patch 应用到 upstream 源码树
- 在原生架构 runner 上执行 Nix build
- 构建并推送 Docker Hub 镜像
- 创建指向 patched upstream source commit 的 GitHub Release

架构构建方式：

```text
amd64 -> ubuntu-latest
arm64 -> ubuntu-24.04-arm
```

不会使用 QEMU 进行 ARM64 Nix 构建。

## Docker 镜像发布

GitHub 仓库需要配置：

```text
secrets.DOCKER_USERNAME
secrets.DOCKER_PASSWORD
```

可选配置：

```text
vars.DOCKERHUB_REPOSITORY
```

如果没有设置 `DOCKERHUB_REPOSITORY`，默认推送到：

```text
${DOCKER_USERNAME}/postgres
```

镜像 tag 不包含扩展名。示例：

```text
<repo>:17.6.1.141
<repo>:17
<repo>:17.6.0.098-orioledb
<repo>:orioledb-17
```

中间架构 tag 用于合并 multi-arch manifest：

```text
<repo>:17.6.1.141-amd64
<repo>:17.6.1.141-arm64
<repo>:17.6.0.098-orioledb-amd64
<repo>:17.6.0.098-orioledb-arm64
```

## 手动触发 Action

在 GitHub Actions 页面选择：

```text
Build Upstream PG17 Release with custom extensions
```

然后点击 `Run workflow`。

也可以用 GitHub CLI 查看运行状态：

```bash
gh run list --repo deluxebear/postgres --branch custom-extensions/pg-durable --limit 8
gh run view <run-id> --repo deluxebear/postgres --json status,conclusion,jobs,url
```

## 本地 Docker Build

本地构建标准 PG17：

```bash
docker build -f Dockerfile-17 -t postgres:17-custom .
```

首次启动空数据目录时必须提供非空的 `POSTGRES_PASSWORD`。下面的参数可直接用于本地运行：

```bash
export POSTGRES_PASSWORD='replace-with-a-strong-password'

docker run -d \
  --name postgres-17-custom \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -p 5432:5432 \
  -v postgres-17-custom-data:/var/lib/postgresql/data \
  postgres:17-custom
```

首次初始化会执行 `/docker-entrypoint-initdb.d/` 中的迁移，通常需要 30–60 秒。查看启动进度和健康状态：

```bash
docker logs -f postgres-17-custom
docker inspect --format '{{.State.Health.Status}}' postgres-17-custom
```

日志出现 `database system is ready to accept connections` 且健康状态为 `healthy` 后即可连接：

```bash
docker exec -it postgres-17-custom psql -U supabase_admin -d postgres
```

本地构建 OrioleDB17：

```bash
docker build -f Dockerfile-orioledb-17 -t postgres:orioledb-17-custom .
```

本地构建 multigres 变体：

```bash
docker build -f Dockerfile-multigres --target variant-17 -t multigres:17-custom .
docker build -f Dockerfile-multigres --target variant-orioledb-17 -t multigres:orioledb-17-custom .
```

多架构本地构建需要 Docker Buildx：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f Dockerfile-17 \
  -t <repo>:17-local \
  --push \
  .
```

本地多架构构建如果不是原生 ARM64，会走 QEMU，可能比 GitHub 原生 ARM64 runner 慢，也可能遇到 Nix/seccomp 兼容问题。正式发布建议使用 GitHub Action。

## 本地校验

提交前至少运行：

```bash
git diff --check
actionlint .github/workflows/upstream-pg17-release-build.yml
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/upstream-pg17-release-build.yml"); puts "yaml ok"'
```

如果修改了项目技能，也运行：

```bash
python3 /Users/xiongyanlin/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  .codex/skills/postgres-custom-extension-build
```

## Release 规则

GitHub Release 的 tag 必须指向实际构建源码：

```text
upstream release source + custom extension patch
```

不要把 release tag 指向 workflow 分支 commit。

当前 tag 命名示例：

```text
postgres-17.6.1.141
postgres-17.6.0.098-orioledb
```

Release 描述中会包含：

- upstream release
- upstream commit
- patched source commit
- Docker Hub image URL
- `docker pull` 命令

## 注意事项

- 不要随意扩大 workflow 中的 `patch_paths`。
- 不要覆盖 `shared_preload_libraries`，只追加需要的库。
- 没有稳定 release 的扩展，不要直接 pin 随机 commit，先确认策略。
- 不要把扩展名加入最终 Docker image version tag，除非明确需要。
- 不要强推或删除 release tag，除非明确确认。
