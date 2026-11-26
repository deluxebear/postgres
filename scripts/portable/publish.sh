#!/usr/bin/env bash
# Publish exact source and assets downloaded from a successful full CI run.
set -euo pipefail
: "${GH_TOKEN:?Required}" "${GH_REPO:?Required}" "${EXPECTED_WORKFLOW_SHA:?Required}"
test "$(jq -r .workflow_commit prepared/plan.json)" = "$EXPECTED_WORKFLOW_SHA"
tag=$(jq -r .release_tag prepared/plan.json)
source_sha=$(jq -r .source_commit prepared/plan.json)
git fetch origin "$EXPECTED_WORKFLOW_SHA"
git fetch prepared/source.bundle refs/heads/portable-source
test "$(git rev-parse FETCH_HEAD)" = "$source_sha"
git diff --exit-code "$EXPECTED_WORKFLOW_SHA" "$source_sha" -- .github/workflows
python3 scripts/portable/release.py notes --plan prepared/plan.json \
  --artifacts artifacts --output release-notes.md
(cd artifacts && sha256sum -c ./*.tar.gz.sha256)
if gh api "repos/$GH_REPO/git/ref/tags/$tag" > existing-tag.json 2> tag-error.log; then
  test "$(jq -r .object.sha existing-tag.json)" = "$source_sha"
elif grep -q 'HTTP 404' tag-error.log; then
  gh auth setup-git --hostname github.com
  git push "https://github.com/$GH_REPO.git" "$source_sha:refs/tags/$tag"
else
  cat tag-error.log >&2; exit 1
fi
if gh release view "$tag" --json isDraft --jq .isDraft > draft.txt 2> release-error.log; then
  test "$(cat draft.txt)" = true
  gh release edit "$tag" --notes-file release-notes.md
elif grep -qi 'release not found' release-error.log; then
  gh release create "$tag" --verify-tag --draft --latest=false \
    --title "PostgreSQL ${tag#postgres-} portable" --notes-file release-notes.md
else
  cat release-error.log >&2; exit 1
fi
gh release upload "$tag" artifacts/*.tar.gz artifacts/*.sha256 artifacts/*.extensions.json --clobber
gh release edit "$tag" --draft=false --latest=false
# Check the published asset bytes via GitHub's SHA-256 metadata. All runtime
# and checksum validation stays on Actions; never execute release files locally.
gh api "repos/$GH_REPO/releases/tags/$tag" > published-release.json
python3 - <<'PY'
import hashlib, json
from pathlib import Path
release = json.loads(Path('published-release.json').read_text())
assert not release['draft'] and not release['prerelease']
assert release['body'] == Path('release-notes.md').read_text()
expected = {p.name: p for p in Path('artifacts').iterdir() if p.is_file()}
assets = {a['name']: a for a in release['assets']}
assert len(expected) == 9 and set(assets) == set(expected), (list(expected), list(assets))
for name, path in expected.items():
    with path.open('rb') as source:
        digest = 'sha256:' + hashlib.file_digest(source, 'sha256').hexdigest()
    assert assets[name]['state'] == 'uploaded'
    assert assets[name]['size'] == path.stat().st_size
    assert assets[name]['digest'] == digest, name
print('All nine published assets and release notes match verified build outputs.')
PY
gh release view "$tag" --json url --jq .url >> "$GITHUB_STEP_SUMMARY"
