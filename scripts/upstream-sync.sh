#!/bin/bash
# Opens a tracking issue for every upstream Joplin desktop release this repository has not mirrored yet.
#   GH_TOKEN=... scripts/upstream-sync.sh   (runs daily in .github/workflows/upstream-sync.yml)
#   DRY_RUN=1 scripts/upstream-sync.sh      print what would be opened, change nothing
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=laurent22/joplin
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
LABEL=upstream-sync

# Desktop releases use plain vX.Y.Z tags; android-*, ios-*, server-* belong to other Joplin apps.
releases=$(gh api "repos/$UPSTREAM/releases?per_page=50" --jq '
  .[] | select(.draft | not) | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
  | [.tag_name, (.prerelease | tostring), .html_url] | @tsv' | sort -t$'\t' -k1,1V)
[ -n "$releases" ] || { echo "No upstream releases found"; exit 0; }

newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

ours=$(git tag --list 'v*.*.*' --sort=-v:refname | head -1)
if [ -z "$ours" ]; then
  # Nothing mirrored yet: start from the newest upstream release only.
  candidates=$(tail -1 <<<"$releases")
else
  candidates=$(while IFS=$'\t' read -r tag pre url; do
    newer "$tag" "$ours" && printf '%s\t%s\t%s\n' "$tag" "$pre" "$url"
  done <<<"$releases")
fi
[ -n "$candidates" ] || { echo "Up to date with upstream (latest mirrored: ${ours:-none})"; exit 0; }

if [ -z "${DRY_RUN:-}" ]; then
  gh label create "$LABEL" --repo "$REPO" --color 0E8A16 \
    --description "Port changes from an upstream Joplin release" 2>/dev/null || true
fi

while IFS=$'\t' read -r tag pre url; do
  title="Upstream release $tag"
  if gh issue list --repo "$REPO" --label "$LABEL" --state all --search "\"$title\" in:title" --json title -q '.[].title' \
      | grep -qxF "$title"; then
    echo "Issue exists: $title"
    continue
  fi
  previous=$(cut -f1 <<<"$releases" | grep -B1 -xF "$tag" | head -1)
  body=$(
    echo "Upstream Joplin published [**$tag**]($url)$([ "$pre" = true ] && echo ' (pre-release)')."
    echo
    [ "$previous" != "$tag" ] && echo "Upstream changes: https://github.com/$UPSTREAM/compare/$previous...$tag" && echo
    echo "To mirror it:"
    echo "- [ ] Review the upstream changelog and port what applies to the native client (data format, sync, features)"
    echo "- [ ] Merge the ports into \`main\` through pull requests"
    echo "- [ ] Tag \`main\` as \`$tag\`; the Release workflow builds and publishes it$([ "$pre" = true ] && echo ' as a pre-release')"
  )
  if [ -n "${DRY_RUN:-}" ]; then
    printf '[dry run] would open "%s":\n%s\n\n' "$title" "$body"
  else
    gh issue create --repo "$REPO" --title "$title" --label "$LABEL" --body "$body"
  fi
done <<<"$candidates"
