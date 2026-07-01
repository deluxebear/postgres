# PostgreSQL 自定义扩展构建说明

这个仓库用于在 Supabase Postgres 上维护自定义 PostgreSQL 扩展构建。当前模式是：在本仓库的定制分支中维护扩展补丁，GitHub Action 自动基于 Supabase upstream 最新稳定 PG17 release 签出源码，叠加本仓库的扩展修改，然后构建 Nix 包和多架构 Docker 镜像。

## 使用项目技能

本项目提供了一个本地 Codex 技能：

```text
$postgres-custom-extension-build
```

技能位置：

```text
.codex/skills/postgres-custom-extension-build/
```

当需要引入新的自定义扩展时，直接这样提需求：

```text
Use $postgres-custom-extension-build to add <extension-name> to PostgreSQL 17 and OrioleDB 17.
```

这个技能会引导 Codex 按本项目约定处理：

- 在专门分支维护自定义扩展代码
- 添加 `nix/ext/<extension>.nix`
- 将扩展接入 `psql_17` 和需要时的 `psql_orioledb-17`
- 正确处理 `shared_preload_libraries`
- 更新 Dockerfile、Ansible、pgctld 模板和测试快照
- 通过 GitHub Action 基于 upstream release 重新构建
- 发布 Docker Hub 镜像和对应 GitHub Release

开始前可以运行技能自带检查脚本：

```bash
.codex/skills/postgres-custom-extension-build/scripts/check_repo_state.sh
```

## 自定义扩展接入流程

推荐在定制分支上工作：

```bash
git checkout custom-extensions/pg-durable
```

新增扩展时，通常需要完成这些修改：

1. 在 `nix/ext/` 下添加扩展 Nix 包，例如：

```text
nix/ext/pg_durable.nix
```

2. 在 `nix/packages/postgres.nix` 中加入目标扩展集合。

当前 PG17 专用扩展使用：

```nix
pg17OnlyExtensions = [
  ../ext/pg_durable.nix
];
```

这个集合会被加入：

```text
psql_17
psql_17_slim
psql_orioledb-17
psql_orioledb-17_slim
```

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
Build Upstream PG17 Release with pg_durable
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
