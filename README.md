# PostgreSQL 自定义扩展构建说明

这个仓库用于在 Supabase Postgres 上维护自定义 PostgreSQL 扩展构建。当前模式是：在本仓库的定制分支中维护扩展补丁，GitHub Action 自动基于 Supabase upstream 最新稳定 PG17 release 签出源码，叠加本仓库的扩展修改，然后构建 Nix 包和多架构 Docker 镜像。

## 当前自定义扩展列表

| 扩展 | 当前版本 | 上游地址 | 接入范围 | 是否预加载 | 说明 |
| --- | --- | --- | --- | --- | --- |
| `pg_durable` | `0.2.7` | `https://github.com/microsoft/pg_durable` | `psql_17`、`psql_17_slim`、`psql_orioledb-17`、`psql_orioledb-17_slim` | 是，追加 `pg_durable` | Durable SQL Functions for PostgreSQL。上游明确支持 PG17/PG18；本仓库将其作为标准 PG17 和 OrioleDB17 共享扩展构建。 |
| `pg_duckdb` | `1.1.1` | `https://github.com/duckdb/pg_duckdb` | `psql_17`、`psql_17_slim` | 是，追加 `pg_duckdb` | DuckDB Embedded in Postgres。当前只接入标准 PG17；暂不接入 OrioleDB17，因为 OrioleDB 的 `TableAmRoutine` ABI 与标准 PostgreSQL 17 不兼容。 |

### 当前版本说明

- `pg_durable 0.2.7` 是官方 GitHub 于 2026-09-01 发布的最新稳定版本，release 见 [v0.2.7](https://github.com/microsoft/pg_durable/releases/tag/v0.2.7)。上游源码继续使用 pgrx `0.16.1`，保留 `pg17` 构建特性，并提供 `pg_durable--0.2.6--0.2.7.sql` 升级路径。
- `pg_durable 0.2.7` 新增 `pg_durable.host` 配置，限制模式下的 HTTP 请求现在强制使用 HTTPS，并统一使用规范化 URL 完成校验和传输以修复 allow-list 绕过；工作连接也会原样保留需要引用的数据库角色名。
- 从 `0.2.5` 或更早版本升级时，应检查是否存在依赖未公开函数 `df.ensure_durofut(text)` 的自定义对象；该函数已在 `0.2.6` 移除。应用不应持久化内部 `Durofut` JSON envelope 后跨版本回放。
- `pg_duckdb 1.1.1` 仍是官方 GitHub 最新稳定源码版本，因此本次不改变其 pin 或接入范围。该上游 release 的 `pg_duckdb.control` 仍声明 SQL 扩展版本 `1.1.0`，且没有提供 `1.1.0--1.1.1.sql`；因此镜像中的 Nix 包路径是 `pg_duckdb-1.1.1`，PostgreSQL `extversion` 仍会显示 `1.1.0`，这是上游版本设计而非旧源码残留。
- `pg_durable` 的 Cargo 依赖通过 crates.io 官方静态下载地址获取，避开 API 下载端点的 HTTP 403；仍使用上游 `Cargo.lock` 中的固定版本和 SHA-256 校验和。
- 2026-09-03 已通过 [GitHub Actions 定向重建](https://github.com/deluxebear/postgres/actions/runs/33715610063) 完成 Supabase PG17 `17.6.1.166` 的 amd64/arm64 Nix 构建、Docker 推送、多架构 manifest 及 [GitHub Release](https://github.com/deluxebear/postgres/releases/tag/postgres-17.6.1.166) 更新。镜像 `deluxebear/postgres:17.6.1.166` 的 manifest digest 为 `sha256:50ed9572145a34c4ffa238993832a34ae7da15bc5ae0c37bc2c715b0b336eb58`；直接检查 ARM64 镜像确认 `pg_durable.control` 为 `0.2.7`、升级脚本 `pg_durable--0.2.6--0.2.7.sql` 存在，且 `pg_duckdb` 来自 Nix 包 `pg_duckdb-1.1.1`。本轮未运行数据库安装、升级及 dump/restore 回归测试。

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

例如：`pg_duckdb v1.1.1` 可以编入标准 PG17，但当前不能直接编入 OrioleDB17，因为 OrioleDB 的 `TableAmRoutine` ABI 和标准 PostgreSQL 17 不一致；`pg_durable` 当前继续作为共享扩展编入两类 PG17 构建。

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
