#!/usr/bin/env python3
"""Resolve stable releases and prepare the exact source used by CLI Release.

Only the prepared upstream checkout is changed; Docker extension pins stay intact.
Python 3.11+ and git are required. GitHub API authentication uses GH_TOKEN.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
CLI_TAG = re.compile(r"v?17\.(\d+)\.(\d+)\.(\d+)-cli")
EXT_TAG = re.compile(r"v?(\d+)\.(\d+)\.(\d+)")
CUSTOM_TAG = re.compile(r"postgres-17\.(\d+)\.(\d+)\.(\d+)-cli")
UNSTABLE = re.compile(r"test|alpha|beta|preview|nightly|canary|\brc\d*\b|development", re.I)


def api(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "custom-postgres-cli-release"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = urllib.request.Request("https://api.github.com/" + path, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def latest_stable(releases, pattern):
    candidates = []
    for release in releases:
        match = pattern.fullmatch(release["tag_name"])
        if (match and not release["draft"] and not release["prerelease"]
                and not UNSTABLE.search(release["tag_name"] + " " + (release.get("name") or ""))):
            candidates.append((tuple(map(int, match.groups())), release))
    if not candidates:
        raise ValueError("No matching stable release found")
    return max(candidates, key=lambda item: (item[0], item[1]["published_at"]))[1]


def releases(repo, pattern):
    # Inspect the newest release pages, advancing past pages containing only
    # other PG flavors or prereleases. Do not crawl the entire release history.
    result = []
    for page in range(1, 11):
        batch = api(f"repos/{repo}/releases?per_page=100&page={page}")
        result.extend(batch)
        try:
            latest_stable(batch, pattern)
            return result
        except ValueError:
            pass
        if len(batch) < 100:
            return result
    raise ValueError(f"Release pagination limit reached for {repo}; refusing an incomplete selection")


def describe(repo, release):
    tag = release["tag_name"]
    commit = api(f"repos/{repo}/commits/{urllib.parse.quote(tag, safe='')}")["sha"]
    return {"repository": repo, "tag": tag, "commit": commit,
            "url": release["html_url"], "published_at": release["published_at"]}


def discover(repo, ref=None, force=False):
    if ref:
        release = api("repos/supabase/postgres/releases/tags/" + urllib.parse.quote(ref, safe=""))
        upstream = latest_stable([release], CLI_TAG)
    else:
        upstream = latest_stable(releases("supabase/postgres", CLI_TAG), CLI_TAG)
    tag = "postgres-" + upstream["tag_name"].removeprefix("v")
    try:
        existing = api(f"repos/{repo}/releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        existing = None
    if existing and not existing["draft"] and not force:
        return {"has_work": False, "release_tag": tag}
    predecessor = None
    previous = releases(repo, CUSTOM_TAG)
    target = tuple(map(int, CLI_TAG.fullmatch(upstream["tag_name"]).groups()))
    previous = [r for r in previous if CUSTOM_TAG.fullmatch(r["tag_name"])
                and tuple(map(int, CUSTOM_TAG.fullmatch(r["tag_name"]).groups())) <= target]
    if previous:
        try:
            selected = latest_stable(previous, CUSTOM_TAG)
        except ValueError:
            selected = None
        if selected:
            predecessor = {"tag": selected["tag_name"], "url": selected["html_url"],
                           "assets": [{"name": a["name"], "url": a["browser_download_url"]}
                                      for a in selected["assets"]]}
    return {
        "has_work": True, "release_tag": tag,
        "predecessor": predecessor,
        "upstream": describe("supabase/postgres", upstream),
        "extensions": {
            name: describe(owner, latest_stable(releases(owner, EXT_TAG), EXT_TAG))
            for name, owner in (("pg_duckdb", "duckdb/pg_duckdb"),
                                ("pg_durable", "microsoft/pg_durable"))
        },
    }


def download(url, cache):
    print(f"Pinning {url}", file=sys.stderr, flush=True)
    destination = cache / hashlib.sha256(url.encode()).hexdigest()
    for attempt in range(3):
        if destination.is_file() and destination.stat().st_size:
            break
        try:
            # Public download URLs deliberately receive no GitHub API credentials.
            request = urllib.request.Request(url, headers={"User-Agent": "custom-postgres-cli-release"})
            temporary = destination.with_suffix(".partial")
            with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            temporary.replace(destination)
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    with destination.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").digest()
    return {"url": url, "hash": "sha256-" + base64.b64encode(digest).decode()}, destination


def tar_text(archive, suffix):
    with tarfile.open(archive) as source:
        members = [m for m in source.getmembers() if m.isfile() and m.name.split("/", 1)[-1] == suffix]
        if len(members) != 1:
            raise ValueError(f"Expected one {suffix} in {archive}")
        return source.extractfile(members[0]).read().decode()


def sql_version(archive, name, version):
    control = tar_text(archive, name + ".control")
    match = re.search(r"^\s*default_version\s*=\s*'([^']+)'", control, re.M)
    if not match:
        raise ValueError(f"Missing default SQL version for {name}")
    return match[1].replace("@CARGO_VERSION@", version)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Upstream packaging changed: expected exactly one {old!r}")
    return text.replace(old, new, 1)


def replace_pin(text, key, value):
    pattern = rf'(\b{key} = ")[^"]+(";)'
    if len(re.findall(pattern, text)) != 1:
        raise ValueError(f"Expected one {key} pin")
    return re.sub(pattern, lambda m: m[1] + value + m[2], text)


def replace_fetch(text, variable, source):
    pattern = rf'({variable} = fetchurl \{{\s*)url = "[^"]+";\s*hash = "[^"]+";'
    text, count = re.subn(pattern, lambda m: m[1] + f'url = "{source["url"]}";\n    hash = "{source["hash"]}";', text)
    if count != 1:
        raise ValueError(f"Expected one fetchurl for {variable}")
    return text


def extension_sources(plan, checkout, cache):
    duck = plan["extensions"]["pg_duckdb"]
    duck["version"] = duck["tag"].removeprefix("v")
    duck["source"], archive = download(
        f'https://github.com/duckdb/pg_duckdb/archive/{duck["commit"]}.tar.gz', cache)
    duck["sql_version"] = sql_version(archive, "pg_duckdb", duck["version"])
    tree = api(f'repos/duckdb/pg_duckdb/git/trees/{duck["commit"]}?recursive=1')
    if tree.get("truncated"):
        raise ValueError("Truncated pg_duckdb source tree")
    entries = {entry["path"]: entry for entry in tree["tree"]}
    submodule = entries["third_party/duckdb"]
    if submodule["type"] != "commit":
        raise ValueError("DuckDB is no longer a pinned submodule")
    cmake = tar_text(archive, "third_party/pg_duckdb_extensions.cmake")
    httpfs = re.search(r"GIT_URL https://github.com/duckdb/duckdb-httpfs\s+GIT_TAG ([0-9a-f]{40})", cmake)
    if not httpfs:
        raise ValueError("Unsupported httpfs source layout")
    duck["duckdb_commit"] = submodule["sha"]
    duck["httpfs_commit"] = httpfs[1]
    duck["duckdb_source"], _ = download(
        f'https://github.com/duckdb/duckdb/archive/{submodule["sha"]}.tar.gz', cache)
    duck["httpfs_source"], _ = download(
        f'https://github.com/duckdb/duckdb-httpfs/archive/{httpfs[1]}.tar.gz', cache)

    durable = plan["extensions"]["pg_durable"]
    durable["version"] = durable["tag"].removeprefix("v")
    url = (f'https://github.com/microsoft/pg_durable/releases/download/{durable["tag"]}/'
           f'pg_durable-{durable["version"]}.tar.gz')
    durable["source"], archive = download(url, cache)
    durable["sql_version"] = sql_version(archive, "pg_durable", durable["version"])
    cargo = tomllib.loads(tar_text(archive, "Cargo.toml"))
    if cargo["package"]["version"] != durable["version"] or "pg17" not in cargo["features"]:
        raise ValueError("pg_durable release version or PG17 support mismatch")
    durable["lock_source"], lock = download(
        f'https://raw.githubusercontent.com/microsoft/pg_durable/{durable["commit"]}/Cargo.lock', cache)
    if tar_text(archive, "Cargo.lock") != lock.read_text():
        raise ValueError("Release Cargo.lock differs from tagged source")
    pgrx = [p["version"] for p in tomllib.loads(lock.read_text())["package"] if p["name"] == "pgrx"]
    if len(pgrx) != 1:
        raise ValueError("Expected one locked pgrx version")
    durable["pgrx_version"] = pgrx[0]
    registry_path = checkout / "nix/cargo-pgrx/versions.json"
    registry = json.loads(registry_path.read_text())
    local_registry = json.loads((ROOT / "nix/cargo-pgrx/versions.json").read_text())
    # Keep upstream's newer toolchain support and fetch/build compatibility fixes.
    if pgrx[0] not in registry and pgrx[0] in local_registry:
        registry[pgrx[0]] = local_registry[pgrx[0]]
    rusts = registry.get(pgrx[0], {}).get("rust", {})
    minimum = cargo["package"].get("rust-version", "1.88.0")
    def version_key(value):
        return tuple(map(int, value.split(".")))
    candidates = [r for r in rusts if version_key(r) >= version_key(minimum)]
    if not candidates:
        raise ValueError(f"Packaging support required for pgrx {pgrx[0]}, Rust >= {minimum}; no downgrade allowed")
    durable["rust_version"] = max(candidates, key=version_key)
    registry_path.write_text(json.dumps(registry, indent=2) + "\n")


def patch_checkout(plan, checkout):
    duck = plan["extensions"]["pg_duckdb"]
    text = (ROOT / "nix/ext/pg_duckdb.nix").read_text()
    text = replace_pin(text, "version", duck["version"])
    for variable, key in (("src", "source"), ("duckdbSrc", "duckdb_source"), ("httpfsSrc", "httpfs_source")):
        text = replace_fetch(text, variable, duck[key])
    text, count = re.subn(r"GIT_TAG [0-9a-f]{40}' 'EXTENSION_VERSION [0-9a-f]+'",
                          f"GIT_TAG {duck['httpfs_commit']}' 'EXTENSION_VERSION {duck['httpfs_commit'][:10]}'", text)
    if count != 1:
        raise ValueError("Expected one httpfs build pin")
    (checkout / "nix/ext/pg_duckdb.nix").write_text(text)

    durable = plan["extensions"]["pg_durable"]
    text = (ROOT / "nix/ext/pg_durable.nix").read_text()
    for key, value in (("version", durable["version"]), ("rustVersion", durable["rust_version"]),
                       ("pgrxVersion", durable["pgrx_version"])):
        text = replace_pin(text, key, value)
    text = replace_fetch(text, "src", durable["source"])
    text = replace_fetch(text, "lockFile", durable["lock_source"])
    (checkout / "nix/ext/pg_durable.nix").write_text(text)

    packages = checkout / "nix/packages/postgres.nix"
    text = packages.read_text()
    text = replace_once(text, "cliExtensions = [", "cliExtensions = [\n        ../ext/pg_duckdb.nix\n        ../ext/pg_durable.nix")
    if "rust-bin = inputs.rust-overlay.lib.mkRustBin" not in text:
        text = replace_once(text, "inherit postgresql latestOnly;",
                            "inherit postgresql latestOnly;\n              rust-bin = inputs.rust-overlay.lib.mkRustBin { } pkgs;")
    packages.write_text(text)

    portable = checkout / "nix/packages/postgres-portable.nix"
    text = portable.read_text()
    text = replace_once(text, '"supautils"\n', '"supautils"\n        "pg_duckdb"\n        "pg_durable"\n')
    text = replace_once(text, "cp ${receipt}/receipt.json $out/cli-receipt.json",
                        "cp ${receipt}/receipt.json $out/cli-receipt.json\n"
                        "    cp ${../../portable-release.json} $out/portable-release.json")
    portable.write_text(text)
    config = checkout / "nix/packages/cli-config/postgresql.conf.template"
    text, count = re.subn(r"^(shared_preload_libraries\s*=\s*')([^']*)'",
                          lambda m: m[1] + m[2] + ", pg_duckdb, pg_durable'", config.read_text(), flags=re.M)
    if count != 1:
        raise ValueError("Expected one preload setting")
    config.write_text(text)
    # Keep validation scripts alongside the exact source snapshot.
    for filename in ("release.py", "test.sh", "inventory.py", "previous.py", "upgrade.sh", "wait-control.sh"):
        destination = checkout / "scripts/portable" / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "scripts/portable" / filename, destination)
    tests = checkout / "tests/test_portable_release.py"
    tests.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "tests/test_portable_release.py", tests)
    (checkout / "portable-release.json").write_text(json.dumps(plan, indent=2) + "\n")


def git(checkout, *args, **kwargs):
    try:
        return subprocess.check_output(["git", "-C", str(checkout), *args], text=True, **kwargs).strip()
    except subprocess.CalledProcessError as error:
        if error.output:
            print(error.output, file=sys.stderr)
        raise


def prepare(plan, checkout, output, cache=None):
    checkout, output = checkout.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    upstream_sha = plan["upstream"]["commit"]
    if git(checkout, "rev-parse", "HEAD") != upstream_sha:
        raise ValueError("Checkout does not match resolved upstream commit")
    plan["workflow_commit"] = os.environ.get("GITHUB_SHA") or git(ROOT, "rev-parse", "HEAD")
    if cache is not None:
        cache.mkdir(parents=True, exist_ok=True)
        extension_sources(plan, checkout, cache)
    else:
        with tempfile.TemporaryDirectory() as temporary:
            extension_sources(plan, checkout, Path(temporary))
    patch_checkout(plan, checkout)
    git(checkout, "add", "-A")
    git(checkout, "diff", "--cached", "--check")
    # GITHUB_TOKEN may not introduce workflow changes through a source tag.
    # Imported trusted workflows can contain historical whitespace errors;
    # validate our package patch before replacing those workflows verbatim.
    shutil.rmtree(checkout / ".github/workflows")
    shutil.copytree(ROOT / ".github/workflows", checkout / ".github/workflows")
    git(checkout, "add", "-A")
    git(checkout, "fetch", "--no-tags", "--update-shallow", str(ROOT), plan["workflow_commit"])
    tree = git(checkout, "write-tree")
    environment = dict(os.environ, GIT_AUTHOR_NAME="github-actions[bot]",
                       GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com",
                       GIT_COMMITTER_NAME="github-actions[bot]",
                       GIT_COMMITTER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com",
                       GIT_AUTHOR_DATE=plan["upstream"]["published_at"],
                       GIT_COMMITTER_DATE=plan["upstream"]["published_at"])
    source_sha = git(checkout, "commit-tree", tree, "-p", plan["workflow_commit"],
                     "-m", f'Portable custom PostgreSQL from {plan["upstream"]["tag"]}', env=environment)
    git(checkout, "update-ref", "refs/heads/portable-source", source_sha)
    git(checkout, "bundle", "create", str(output / "source.bundle"), "portable-source", "^" + plan["workflow_commit"])
    git(checkout, "archive", "--format=tar.gz", "-o", str(output / "source.tar.gz"), source_sha)
    plan["source_commit"] = source_sha
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")


def notes(plan, inventories):
    if {i["platform"] for i in inventories} != {"linux-x64", "linux-arm64", "darwin-arm64"} or len(inventories) != 3:
        raise ValueError("Expected inventories for three native platforms")
    first = inventories[0]
    for inventory in inventories:
        if inventory["extensions"] != first["extensions"] or inventory["postgresql"] != first["postgresql"]:
            raise ValueError("Extension or PostgreSQL versions differ across platforms")
        if inventory["release"] != {k: v for k, v in plan.items() if k != "source_commit"}:
            raise ValueError("Artifact provenance differs from prepared source")
    lines = [f'# PostgreSQL {first["postgresql"]} 便携版', "",
             f'上游：[{plan["upstream"]["tag"]}]({plan["upstream"]["url"]})', "",
             f'- 上游源码：`{plan["upstream"]["commit"]}`',
             f'- 实际构建源码：`{plan["source_commit"]}`',
             f'- 工作流源码：`{plan["workflow_commit"]}`', "",
             "## 自定义扩展", "", "| 扩展 | 稳定版本 | 上游 Release |", "| --- | --- | --- |"]
    for name, extension in sorted(plan["extensions"].items()):
        lines.append(f'| {name} | {extension["version"]} | [{extension["tag"]}]({extension["url"]}) |')
    lines += ["", "## 全部随包 SQL 扩展", "", "版本来自各平台实际构建产物的 `.control` 文件，已核对三平台一致。", "",
              "| 扩展 | 默认 SQL 版本 |", "| --- | --- |"]
    lines += [f"| {name} | {version} |" for name, version in sorted(first["extensions"].items())]
    lines += ["", "## 安装与验证", "",
              "- 提供 Linux x64、Linux ARM64、macOS ARM64 压缩包及 SHA-256 校验文件。",
              "- 解压后使用 `bin/initdb`、`bin/pg_ctl` 和 `bin/psql`；运行时无需 Docker 或 Nix。",
              "- Linux 包依赖宿主 glibc；验证环境为 Ubuntu 24.04，不适用于原生 Alpine/musl。",
              "- 配置模板已追加 `pg_duckdb`、`pg_durable` 预加载项；安装 SQL 扩展仍需执行 `CREATE EXTENSION`。",
              "- 三平台均通过无 Nix 环境中的初始化、扩展安装、查询、durable 工作流执行与重启后结果保留、pg_duckdb dump/restore 和 SQL 升级路径检查。",
              "- 未验证 pg_durable 控制数据库的逻辑备份恢复；不能将控制数据库直接 pg_restore 为卫星数据库。",
              (f'- 已验证从 [{plan["predecessor"]["tag"]}]({plan["predecessor"]["url"]}) 的真实便携二进制升级，包含旧数据和已完成 durable 工作流结果。'
               if plan.get("predecessor") else "- 首次发布，没有此前包含这两个扩展的定制便携包，未执行跨包二进制升级验证。"),
              "- 不保证升级时仍在运行的 durable 工作流能够跨版本回放。",
              "- `portable-release.json` 记录源码、子模块与哈希；`extensions.json` 列出全部 SQL 扩展版本。", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    discover_args = commands.add_parser("discover")
    discover_args.add_argument("--repository", required=True)
    discover_args.add_argument("--upstream-ref")
    discover_args.add_argument("--force", action="store_true")
    discover_args.add_argument("--output", type=Path, required=True)
    prepare_args = commands.add_parser("prepare")
    prepare_args.add_argument("--plan", type=Path, required=True)
    prepare_args.add_argument("--checkout", type=Path, required=True)
    prepare_args.add_argument("--output", type=Path, required=True)
    prepare_args.add_argument("--download-cache", type=Path)
    notes_args = commands.add_parser("notes")
    notes_args.add_argument("--plan", type=Path, required=True)
    notes_args.add_argument("--artifacts", type=Path, required=True)
    notes_args.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "discover":
        plan = discover(args.repository, args.upstream_ref, args.force)
        args.output.write_text(json.dumps(plan, indent=2) + "\n")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f'has_work={str(plan["has_work"]).lower()}\n')
    elif args.command == "prepare":
        prepare(json.loads(args.plan.read_text()), args.checkout, args.output, args.download_cache)
    else:
        inventories = [json.loads(p.read_text()) for p in sorted(args.artifacts.glob("*.extensions.json"))]
        args.output.write_text(notes(json.loads(args.plan.read_text()), inventories))


if __name__ == "__main__":
    main()
