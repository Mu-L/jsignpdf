#!/bin/sh
# Copies the AsciiDoc guide and its images from website/docs/ into the
# Hugo content tree as a leaf bundle. The destination paths are gitignored,
# so website/docs/JSignPdf.adoc remains the single source of truth (also
# consumed by the Maven asciidoctor-pdf build in distribution/).
#
# Run before `hugo serve` or `hugo build`. The CI workflow runs it too.
# POSIX sh — runs in busybox/alpine containers without bash.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_ADOC="${HERE}/docs/JSignPdf.adoc"
SRC_GUIDE_IMG="${HERE}/docs/img"
SRC_NOTES="${HERE}/../distribution/doc/release-notes"
DEST_GUIDE="${HERE}/content/docs"
DEST_RELEASES="${HERE}/content/releases"
REPO_EDIT="https://github.com/intoolswetrust/jsignpdf/edit/master"
REPO_ISSUES="https://github.com/intoolswetrust/jsignpdf/issues"

if [ ! -f "${SRC_ADOC}" ]; then
  echo "ERROR: ${SRC_ADOC} not found" >&2
  exit 1
fi

if [ ! -d "${SRC_NOTES}" ]; then
  echo "ERROR: ${SRC_NOTES} not found" >&2
  exit 1
fi

# Resolve the JSignPdf version to show in the guide.
#   1. $JSIGNPDF_VERSION — explicit override (offline dev, tight edit loops)
#   2. GitHub Releases API — tag_name of the latest published release
# The Releases API is authoritative: do-release.yml uploads the built
# binaries to that release, so "latest release" is exactly what users can
# download. Reading pom.xml would leak the in-progress -SNAPSHOT instead.
# If $GITHUB_TOKEN is set (CI), it bumps the rate limit from 60/hr to
# 1000/hr — not required for correctness.
if [ -n "${JSIGNPDF_VERSION:-}" ]; then
  VERSION="${JSIGNPDF_VERSION}"
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — set JSIGNPDF_VERSION to bypass the GitHub API lookup" >&2
    exit 1
  fi
  if ! VERSION=$(python3 - <<'PY'
import json, os, sys, urllib.request
url = "https://api.github.com/repos/intoolswetrust/jsignpdf/releases/latest"
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "jsignpdf-prepare",
}
token = os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = "Bearer " + token
try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        tag = json.load(resp)["tag_name"]
except Exception as e:
    sys.exit("failed to fetch latest release: %s" % e)
# Release tags look like "JSignPdf_2_3_3" — normalize to "2.3.3".
if tag.startswith("JSignPdf_"):
    tag = tag[len("JSignPdf_"):]
print(tag.replace("_", "."))
PY
  ); then
    echo "ERROR: could not resolve version from GitHub — set JSIGNPDF_VERSION to override" >&2
    exit 1
  fi
fi

if [ -z "${VERSION}" ]; then
  echo "ERROR: could not determine JSignPdf version" >&2
  exit 1
fi

# Guide section (branch bundle): _index.adoc + img/ resources at the /docs/
# URL. Using _index.adoc (not index.adoc) makes this a section page so
# Hextra's docs list layout applies cleanly. Prepend a Hugo YAML
# front-matter block to set type: docs, redirect the old /docs/guide/
# URL, and opt out of the FlexSearch index.
mkdir -p "${DEST_GUIDE}"
{
  printf -- '---\n'
  printf -- 'title: "JSignPdf User Guide"\n'
  printf -- 'linkTitle: "Docs"\n'
  printf -- 'type: docs\n'
  printf -- 'aliases:\n'
  printf -- '  - /docs/guide/\n'
  printf -- 'excludeSearch: true\n'
  printf -- 'editURL: "%s/website/docs/JSignPdf.adoc"\n' "${REPO_EDIT}"
  printf -- 'sidebar:\n'
  printf -- '  hide: true\n'
  printf -- '---\n'
  sed "s|{jsignpdf-version}|${VERSION}|g" "${SRC_ADOC}"
} > "${DEST_GUIDE}/_index.adoc"
rm -rf "${DEST_GUIDE}/img"
cp -r  "${SRC_GUIDE_IMG}" "${DEST_GUIDE}/img"

echo "Prepared ${DEST_GUIDE} (jsignpdf-version=${VERSION})"

# Release notes section (branch bundle): one page per release at /releases/,
# generated from distribution/doc/release-notes/, which stays the single
# source of truth (it also feeds the GitHub release body and the AppStream
# metainfo). The format is fixed by that directory's README: an H1 title, an
# intro paragraph, then one flat bullet list.
#
# Two website-only transforms are applied on the way in:
#   * the H1 becomes the Hugo title, so the page does not show it twice;
#   * "issue 223" becomes a link — the source file cannot carry one because
#     AppStream descriptions forbid links.

# Version-sort the release files newest-first without relying on `sort -V`,
# which busybox does not have: emit a zero-padded key, sort on it, drop it.
release_versions() {
  for f in "${SRC_NOTES}"/*.md; do
    v="$(basename "${f}" .md)"
    [ "${v}" = "README" ] && continue
    printf '%s %s\n' \
      "$(printf '%s' "${v}" | awk -F. '{printf "%05d.%05d.%05d", $1, $2+0, $3+0}')" \
      "${v}"
  done | sort -r | cut -d' ' -f2
}

rm -rf "${DEST_RELEASES}"
mkdir -p "${DEST_RELEASES}"

RELEASE_WEIGHT=0
RELEASE_INDEX_LIST=""
for v in $(release_versions); do
  RELEASE_WEIGHT=$((RELEASE_WEIGHT + 1))
  src="${SRC_NOTES}/${v}.md"
  title="$(sed -n '1s/^# *//p' "${src}")"
  [ -n "${title}" ] || title="Version ${v}"
  {
    printf -- '---\n'
    printf -- 'title: "%s"\n' "${title}"
    printf -- 'linkTitle: "%s"\n' "${v}"
    printf -- 'weight: %d\n' "${RELEASE_WEIGHT}"
    printf -- 'editURL: "%s/distribution/doc/release-notes/%s.md"\n' "${REPO_EDIT}" "${v}"
    printf -- '---\n'
    sed -e '1{/^# /d;}' \
        -e "s|issue \([0-9][0-9]*\)|issue [\1](${REPO_ISSUES}/\1)|g" \
        "${src}"
  } > "${DEST_RELEASES}/${v}.md"
  RELEASE_INDEX_LIST="${RELEASE_INDEX_LIST}- [Version ${v}](${v}/)
"
done

if [ "${RELEASE_WEIGHT}" -eq 0 ]; then
  echo "ERROR: no release notes found in ${SRC_NOTES}" >&2
  exit 1
fi

{
  printf -- '---\n'
  printf -- 'title: "Release notes"\n'
  printf -- 'linkTitle: "Releases"\n'
  printf -- 'type: docs\n'
  printf -- 'cascade:\n'
  printf -- '  type: docs\n'
  printf -- 'editURL: "%s/distribution/doc/release-notes/"\n' "${REPO_EDIT}"
  printf -- '---\n'
  printf -- '\n'
  printf -- 'What changed in every published JSignPdf version, newest first.\n'
  printf -- 'Downloads and checksums live on the\n'
  printf -- '[GitHub releases page](https://github.com/intoolswetrust/jsignpdf/releases).\n'
  printf -- '\n'
  printf -- '%s' "${RELEASE_INDEX_LIST}"
} > "${DEST_RELEASES}/_index.md"

echo "Prepared ${DEST_RELEASES} (${RELEASE_WEIGHT} releases)"
