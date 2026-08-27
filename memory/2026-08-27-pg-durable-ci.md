# pg_durable 0.2.6 GitHub Actions 构建排障

状态：用户要求的远端编译验证已完成，四个目标全部成功。

## 症状与根因

[初始运行 33068559493](https://github.com/deluxebear/postgres/actions/runs/33068559493) 的标准 PG17、OrioleDB17 × amd64、arm64 四个任务均失败于 `Build Nix package`。

- `importCargoLock` 从 `https://crates.io/api/v1/crates/<crate>/<version>/download` 下载依赖失败，日志包含证书错误和 HTTP 403，最终无法获取 `azure_core 0.35.0` 等 crate。
- 失败发生于 Cargo 依赖准备阶段，不能据此判定 PostgreSQL API/ABI 不兼容。
- 对比上游 `v0.2.5` 与 `v0.2.6` 的 `Cargo.lock`，唯一变化是 `pg_durable` 自身版本号；不是本次升级引入了新的依赖版本。
- 下载诊断中，API 地址返回 403，官方静态下载地址返回 200。`https://index.crates.io/config.json` 也将 `dl` 指向 `https://static.crates.io/crates`。

## 修复

修改范围为 `nix/ext/pg_durable.nix`，README 同步说明下载策略。

1. 第一版 `c265864` 使用 `extraRegistries`，解决了下载失败，但引入 Cargo 源重复定义。
2. [第一轮仅编译运行 33069768205](https://github.com/deluxebear/postgres/actions/runs/33069768205) 确认静态下载成功；随后 `cargo metadata` 报告 `crates-io` 已被定义。
3. `1754369` 改为覆盖 `rustPlatform.importCargoLock` 的 `fetchurl` 参数，只把 API 下载前缀替换为官方静态下载前缀；沿用默认 Cargo 源配置。

保留上游依赖版本、Cargo.lock、SHA-256、TLS 校验、PG17/OrioleDB17 接入范围。不修改全局 Nixpkgs 下载行为。

## 验证

- 四个曾下载失败的 crate（`azure_core 0.35.0`、`azure_core_macros 0.8.0`、`azure_identity 0.35.0`、`cron 0.13.0`）从静态源下载后的 SHA-256 均与上游 Cargo.lock 一致。
- 临时隔离目录 `/tmp/pg-durable-registry-check.Bf6CEq` 中的离线 `cargo metadata` 回归检查：重复源配置重现 CI 错误，默认单一源配置成功。此检查不编译代码、不下载依赖。
- `git diff --check`、`actionlint` 和 workflow YAML 解析通过。
- [第二轮仅编译运行 33070095109](https://github.com/deluxebear/postgres/actions/runs/33070095109)，测试源码提交为 `1754369`。

| 目标 | 状态 | Job 耗时 |
| --- | --- | --- |
| 标准 PG17 / amd64 | 编译成功 | 26m19s |
| 标准 PG17 / arm64 | 编译成功 | 19m40s |
| OrioleDB17 / amd64 | 编译成功 | 6m36s |
| OrioleDB17 / arm64 | 编译成功 | 5m34s |

OrioleDB17 / arm64 日志确认编译 `pg_durable v0.2.6`、生成安装 SQL，并复制 `pg_durable--0.2.5--0.2.6.sql` 到产物。

标准 PG17 / amd64 日志也确认 `pg_durable v0.2.6` 在 12:14:51 UTC 完成安装，随后 `pg_duckdb` 在 12:29:46 UTC 进入安装阶段，完整 Nix 构建在 12:29:48 UTC 成功。

## 验证边界

按用户要求不在本地构建。使用现有 `workflow_dispatch` 的 `build_docker=false` 运行完整 Nix 包构建，跳过镜像及 Release 发布。自动 push 运行 33069716959 在发布前被取消，避免现有工作流强制移动已有 Release tag。

构建通过不等同于安装、数据升级或 dump/restore 回归测试通过；本次没有运行这些数据库生命周期测试。
