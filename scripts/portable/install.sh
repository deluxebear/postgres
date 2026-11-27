#!/usr/bin/env bash
# Install a published Linux portable bundle on a fresh systemd instance.
# This script does not compile anything or dispatch GitHub Actions.
set -Eeuo pipefail
umask 077

repository=deluxebear/postgres
requested_version=''
port=5432
prefix=/opt/portable-postgres
state=/var/lib/postgresql/portable
config=/etc/portable-postgres
unit=/etc/systemd/system/portable-postgres.service
service=portable-postgres.service
temporary=''
service_created=false

usage() {
  cat <<'HELP'
用法：sudo bash scripts/portable/install.sh [--port 5432] [--version 17.12.0.005-cli]

默认从 deluxebear/postgres 下载最新稳定 PG17 便携版，校验后安装两个扩展及 systemd 服务。
支持 Linux x86_64 / ARM64，要求 systemd、glibc >= 2.39、Python >= 3.12。
缺少依赖时通过 apt-get 或 dnf 安装。首次安装专用，拒绝覆盖已有目录或服务。
默认仅监听 127.0.0.1；生成的密码保存到 /etc/portable-postgres/，不会打印密码。
--version 可以使用 17.12.0.005-cli 或 postgres-17.12.0.005-cli。
HELP
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
log() { printf '[portable-postgres] %s\n' "$*"; }
cleanup() {
  local status=$?
  trap - EXIT
  if [[ $status -ne 0 ]]; then
    if [[ $service_created == true ]]; then
      systemctl disable --now "$service" >/dev/null 2>&1 || true
      journalctl -u "$service" -n 60 --no-pager >&2 || true
    fi
    printf '安装未完成（退出码 %s）。已创建的数据、凭据和程序将保留，不会自动删除或重新初始化。\n' "$status" >&2
  fi
  if [[ -n "$temporary" ]]; then rm -rf -- "$temporary"; fi
  exit "$status"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) [[ $# -ge 2 ]] || die '--port 缺少值'; port=$2; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die '--version 缺少值'; requested_version=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die '端口必须为 1–65535 的整数'
if [[ -n "$requested_version" ]]; then
  requested_version=${requested_version#postgres-}
  [[ $requested_version =~ ^17\.[0-9]+\.[0-9]+\.[0-9]+-cli$ ]] || die '只接受稳定 PG17 CLI 版本号'
fi
[[ $(uname -s) == Linux ]] || die '仅支持 Linux'
[[ $EUID -eq 0 ]] || die '请使用 sudo bash install.sh 执行'
case "$(uname -m)" in
  x86_64) architecture=linux-x64 ;;
  aarch64|arm64) architecture=linux-arm64 ;;
  *) die '只支持 Linux x86_64 和 ARM64' ;;
esac
[[ -d /run/systemd/system ]] || die '当前系统没有运行 systemd'
command -v systemctl >/dev/null || die '缺少 systemctl'
command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux'
exec 9>/run/portable-postgres-install.lock
flock -n 9 || die '另一个安装进程正在运行'

# Refuse an existing or partially installed instance before changing dependencies.
for path in "$prefix/current" "$state" "$config" "$unit"; do
  [[ ! -e "$path" && ! -L "$path" ]] || die "路径已存在，拒绝覆盖：$path"
done
[[ ! -L "$prefix" ]] || die "程序根目录不能是符号链接：$prefix"
if systemctl cat "$service" >/dev/null 2>&1; then die "服务已存在：$service"; fi
missing=false
for command in python3 openssl runuser useradd groupadd getent install tar sha256sum; do
  if ! command -v "$command" >/dev/null; then missing=true; fi
done
if [[ $missing == true || ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
  log '安装运行依赖（不安装发行版 PostgreSQL）'
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 openssl ca-certificates util-linux passwd coreutils tar
  elif command -v dnf >/dev/null; then
    dnf install -y python3 openssl ca-certificates util-linux shadow-utils coreutils tar
  else
    die '请先安装 Python 3.12+、OpenSSL、CA 证书、util-linux、用户管理工具、coreutils 和 tar'
  fi
fi
certificate=/etc/ssl/certs/ca-certificates.crt
if [[ ! -s "$certificate" && -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
  certificate=/etc/pki/tls/certs/ca-bundle.crt
fi
[[ -s "$certificate" ]] || die '找不到系统 CA 证书文件'
python3 - "$port" <<'PY'
import platform, socket, sys
if sys.version_info < (3, 12):
    raise SystemExit('需要 Python >= 3.12（用于安全解包）')
libc, version = platform.libc_ver()
if libc != 'glibc' or tuple(map(int, version.split('.')[:2])) < (2, 39):
    raise SystemExit(f'需要 glibc >= 2.39，当前为 {libc} {version}；不支持原生 Alpine/musl')
with socket.socket() as probe:
    probe.bind(('127.0.0.1', int(sys.argv[1])))
PY
temporary=$(mktemp -d /tmp/portable-postgres-install.XXXXXX)
export SSL_CERT_FILE="$certificate"
log "查找稳定便携版（$architecture）并下载、校验"
python3 - "$repository" "$requested_version" "$architecture" "$temporary" <<'PY'
import hashlib, json, re, shutil, sys, tarfile, time
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen

repository, requested, architecture, directory = sys.argv[1:]
directory = Path(directory)
pattern = re.compile(r'postgres-17\.(\d+)\.(\d+)\.(\d+)-cli')

def fetch(url, path=None):
    for attempt in range(3):
        try:
            request = Request(url, headers={'User-Agent': 'portable-postgres-installer',
                                           'Accept': 'application/vnd.github+json' if path is None else 'application/octet-stream'})
            with urlopen(request, timeout=180) as response:
                if path is None:
                    return json.load(response)
                with path.open('wb') as output:
                    shutil.copyfileobj(response, output)
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)

def stable(release):
    return (pattern.fullmatch(release['tag_name']) and not release['draft'] and not release['prerelease']
            and not re.search(r'test|alpha|beta|preview|nightly|canary|\brc\d*\b|development',
                              release['tag_name'] + ' ' + (release.get('name') or ''), re.I))

api = f'https://api.github.com/repos/{repository}'
if requested:
    release = fetch(f'{api}/releases/tags/postgres-{requested}')
    if not stable(release):
        raise SystemExit('指定 release 不是稳定 PG17 便携版')
else:
    # Do not depend on the repository's global Latest: it can point to a Docker release.
    release = None
    for page in range(1, 11):
        batch = fetch(f'{api}/releases?per_page=100&page={page}')
        candidates = [item for item in batch if stable(item)]
        if candidates:
            release = max(candidates, key=lambda item: tuple(map(int, pattern.fullmatch(item['tag_name']).groups())))
            break
        if len(batch) < 100:
            break
    if release is None:
        raise SystemExit('未找到稳定 PG17 便携版')
tag = release['tag_name']
bundle = f'supabase-{tag}-{architecture}'
assets = {item['name']: item for item in release['assets']}
names = (bundle + '.tar.gz', bundle + '.tar.gz.sha256', bundle + '.extensions.json')
for name in names:
    asset = assets.get(name)
    expected_url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
    if not asset or asset['state'] != 'uploaded' or asset['browser_download_url'] != expected_url:
        raise SystemExit(f'缺少完整正式发布附件：{name}')
    fetch(expected_url, directory / name)
    with (directory / name).open('rb') as source:
        digest = 'sha256:' + hashlib.file_digest(source, 'sha256').hexdigest()
    if asset.get('digest') != digest:
        raise SystemExit(f'GitHub 附件哈希不匹配：{name}')
checksum = (directory / names[1]).read_text().split()
if (len(checksum) != 2 or checksum[1].lstrip('*') != names[0]
        or not re.fullmatch(r'[0-9a-f]{64}', checksum[0])):
    raise SystemExit('校验文件格式不正确')
with (directory / names[0]).open('rb') as source:
    if hashlib.file_digest(source, 'sha256').hexdigest() != checksum[0]:
        raise SystemExit('压缩包 SHA-256 校验失败')
with tarfile.open(directory / names[0], 'r:gz') as archive:
    for member in archive:
        name = PurePosixPath(member.name)
        if name.is_absolute() or '..' in name.parts or not name.parts or name.parts[0] != bundle:
            raise SystemExit('压缩包包含不符合预期的顶层目录')
        if not member.isfile() and not member.isdir():
            raise SystemExit('便携包只允许普通文件和目录，不接受链接或特殊设备')
    archive.extractall(directory / 'unpacked', filter='data')
root = directory / 'unpacked' / bundle
inventory = json.loads((root / 'extensions.json').read_text())
external_inventory = json.loads((directory / names[2]).read_text())
manifest = json.loads((root / 'portable-release.json').read_text())
if (inventory != external_inventory or inventory['platform'] != architecture
        or inventory['release'] != manifest or manifest['release_tag'] != tag):
    raise SystemExit('产物版本、架构或来源记录不一致')
for extension in ('pg_duckdb', 'pg_durable'):
    expected = manifest['extensions'][extension]['sql_version']
    control = (root / 'share/postgresql/extension' / f'{extension}.control').read_text()
    actual = re.search(r"^\s*default_version\s*=\s*'([^']+)'", control, re.M)
    if not actual or actual[1] != expected or inventory['extensions'].get(extension) != expected:
        raise SystemExit(f'扩展版本记录不匹配：{extension}')
for name in ('postgres', 'initdb', 'pg_ctl', 'pg_isready', 'psql'):
    if not (root / 'bin' / name).is_file():
        raise SystemExit(f'包内缺少程序：{name}')
(directory / 'bundle-name').write_text(bundle)
print(f'已校验 {tag}：pg_duckdb {inventory["extensions"]["pg_duckdb"]}，pg_durable {inventory["extensions"]["pg_durable"]}')
PY
bundle=$(cat "$temporary/bundle-name")
[[ ! -e "$prefix/$bundle" && ! -L "$prefix/$bundle" ]] || die "版本目录已存在：$prefix/$bundle"
install -d -o root -g root -m 0755 "$prefix"
mv -- "$temporary/unpacked/$bundle" "$prefix/$bundle"
chown -R root:root "$prefix/$bundle"
chmod -R go-w "$prefix/$bundle"
ln -s -- "$prefix/$bundle" "$prefix/current"
bin="$prefix/current/bin"

if ! getent group postgres >/dev/null; then groupadd --system postgres; fi
if ! id postgres >/dev/null 2>&1; then
  useradd --system --gid postgres --home-dir /var/lib/postgresql --shell /usr/sbin/nologin postgres
fi
# Existing postgres accounts may have a different primary group. The unit uses
# Group=postgres explicitly, and runuser uses -g for identical ownership/access.
install -d -o postgres -g postgres -m 0700 "$state" "$state/keys"
install -d -o root -g root -m 0700 "$config"
administrator_password=$(openssl rand -hex 32)
application_password=$(openssl rand -hex 32)
printf '%s\n' "$administrator_password" > "$state/.initdb-password"
chown postgres:postgres "$state/.initdb-password"
printf 'PGPASSWORD=%s\n' "$administrator_password" > "$config/worker.env"
printf 'PGHOST=127.0.0.1\nPGPORT=%s\nPGDATABASE=postgres\nPGUSER=portable_app\nPGPASSWORD=%s\n' \
  "$port" "$application_password" > "$config/app.env"
chmod 0600 "$config/worker.env" "$config/app.env" "$state/.initdb-password"
log '初始化 PostgreSQL（本地 peer、TCP SCRAM）'
runuser -u postgres -g postgres -- "$bin/initdb" -D "$state/data" -U postgres \
  --locale=C --encoding=UTF8 --auth-local=peer --auth-host=scram-sha-256 \
  --pwfile="$state/.initdb-password" >/dev/null
rm -- "$state/.initdb-password"
unset administrator_password
cp "$prefix/current/share/supabase-cli/config/postgresql.conf.template" "$state/data/postgresql.conf"
python3 - "$state/data/postgresql.conf" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
pattern = r"^(shared_preload_libraries\s*=\s*')([^']*)'"
def append(match):
    libraries = [value.strip() for value in match[2].split(',') if value.strip()]
    for name in ('pg_duckdb', 'pg_durable'):
        if name not in libraries:
            libraries.append(name)
    return match[1] + ', '.join(libraries) + "'"
text, count = re.subn(pattern, append, text, flags=re.M)
if count != 1:
    raise SystemExit('预加载配置布局改变，拒绝覆盖其他扩展设置')
path.write_text(text)
PY
cat >> "$state/data/postgresql.conf" <<CONF

# Managed by scripts/portable/install.sh; programs and data have separate lifecycles.
listen_addresses = '127.0.0.1'
port = $port
unix_socket_directories = '/run/portable-postgres'
unix_socket_permissions = 0770
password_encryption = 'scram-sha-256'
logging_collector = off
cron.database_name = 'postgres'
pgsodium.getkey_script = '$prefix/current/share/supabase-cli/config/pgsodium_getkey.sh'
vault.getkey_script = '$prefix/current/share/supabase-cli/config/pgsodium_getkey.sh'
pg_durable.worker_role = 'postgres'
pg_durable.database = 'postgres'
pg_durable.host = '127.0.0.1'
CONF
cat > "$state/data/pg_hba.conf" <<'HBA'
local all postgres peer
local all all scram-sha-256
host all all 127.0.0.1/32 scram-sha-256
HBA
chown postgres:postgres "$state/data/postgresql.conf" "$state/data/pg_hba.conf"

cat > "$unit" <<UNIT
[Unit]
Description=Portable PostgreSQL with pg_duckdb and pg_durable
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
Environment=HOME=$state
Environment=PATH=$bin:/usr/local/bin:/usr/bin:/bin
Environment=PGSODIUM_KEY_FILE=$state/keys/pgsodium.key
Environment=SSL_CERT_FILE=$certificate
Environment=CURL_CA_BUNDLE=$certificate
EnvironmentFile=$config/worker.env
RuntimeDirectory=portable-postgres
RuntimeDirectoryMode=0750
WorkingDirectory=$state
ExecStart=$bin/postgres -D $state/data
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGINT
KillMode=mixed
TimeoutStopSec=infinity
Restart=on-failure
RestartSec=5
UMask=0077
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$unit"
service_created=true
systemctl daemon-reload
systemctl enable --now "$service"
psql_admin() {
  runuser -u postgres -g postgres -- "$bin/psql" -X -v ON_ERROR_STOP=1 \
    -h /run/portable-postgres -p "$port" -U postgres -d postgres "$@"
}
ready=false
for _ in {1..90}; do
  if runuser -u postgres -g postgres -- "$bin/pg_isready" -h /run/portable-postgres \
    -p "$port" -U postgres -d postgres >/dev/null 2>&1; then ready=true; break; fi
  systemctl is-active --quiet "$service" || die '数据库服务未保持运行'
  sleep 1
done
[[ $ready == true ]] || die '等待数据库启动超时'
log '安装 pg_duckdb、pg_durable 并授权普通应用角色'
psql_admin -q <<SQL
CREATE EXTENSION pg_duckdb;
CREATE EXTENSION pg_durable;
CREATE ROLE portable_app LOGIN PASSWORD '$application_password';
SELECT df.grant_usage('portable_app');
SQL
schema=$(psql_admin -At -c 'SELECT df.duroxide_schema()')
case "$schema" in duroxide|_duroxide) ;; *) die "无法识别 durable provider schema：$schema" ;; esac
ready=false
for _ in {1..90}; do
  if [[ $(psql_admin -At -c "SELECT to_regclass('$schema._worker_ready') IS NOT NULL") == t ]] &&
     [[ $(psql_admin -At -c "SELECT EXISTS(SELECT 1 FROM $schema._worker_ready WHERE schema_version >= 1)") == t ]]; then
    ready=true
    break
  fi
  sleep 1
done
[[ $ready == true ]] || die '等待 durable 控制后台初始化超时'
log '检查 DuckDB 查询和普通角色 durable 工作流'
psql_admin -q <<'SQL'
CREATE TABLE public.portable_installer_probe (amount integer);
INSERT INTO public.portable_installer_probe VALUES (19), (23);
SQL
[[ $(psql_admin -Atq -c 'SET duckdb.force_execution = true; SELECT sum(amount) FROM public.portable_installer_probe') == 42 ]] || die 'DuckDB 查询检查失败'
psql_admin -q -c 'DROP TABLE public.portable_installer_probe'
# Pass the application password in the environment, never as a command argument.
PGPASSWORD="$application_password" runuser -u postgres -g postgres -- "$bin/psql" \
  -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U portable_app -d postgres <<'SQL'
SET statement_timeout = '90s';
SELECT df.start(df.sql('SELECT 42 AS answer'), 'installer-probe') AS instance_id \gset
SELECT df.await_instance(:'instance_id');
SELECT (df.result(:'instance_id')::jsonb->'rows'->0->>'answer' = '42') AS result_ok \gset
\if :result_ok
\else
  \quit 1
\endif
SQL
unset application_password
psql_admin -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_duckdb','pg_durable') ORDER BY extname"
systemctl is-active --quiet "$service" || die '服务状态异常'
log "安装完成：$bundle，监听 127.0.0.1:$port，数据库 postgres，应用角色 portable_app"
log "应用凭据：$config/app.env（仅 root 可读）；后台管理员凭据：$config/worker.env"
log "请备份 $state/keys/pgsodium.key；服务管理：systemctl status $service"
log "连接：$bin/psql -W -h 127.0.0.1 -p $port -U portable_app -d postgres"
