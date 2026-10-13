#!/usr/bin/env bash
# check-docs.sh — find stale references in docs and agent files.
#
# Checks (exit 1 if any fails):
#   paths  every repo path a file mentions (iac/…, gitops/…, docs/…, provisioner/…, .apm/…,
#          .github/workflows/…) exists. The match stops at a placeholder (<x>, *, {x}, $X), so
#          templated paths are checked up to their last literal directory. URLs and ../relative
#          links are ignored. A line containing "check-docs:ignore" is skipped — use it for
#          history that names a removed path on purpose.
#   toc    every markdown file over 100 lines (SKILL.md excepted: it is always read whole) has a
#          "## Contents" section naming each of its "## " headings, so a partial read such as
#          `head -100` still shows the file's full scope.
#
# Usage:
#   check-docs.sh               check README.md, AGENTS.md, docs/*.md and every .md under .apm/
#   check-docs.sh FILE...       check only these files
#   check-docs.sh --toc FILE    print a "## Contents" block for FILE; paste it above the first "## "
#
# Runs from anywhere inside the repo. Needs only git, awk, grep and sed (BSD or GNU) and bash 3.2,
# the macOS default.
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

# Level-2 headings outside fenced code blocks, the Contents heading itself excluded.
headings() {
  awk '/^```/ { fenced = !fenced; next }
       !fenced && /^## / && $0 != "## Contents" { sub(/^## /, ""); print }' "$1"
}

if [ "${1:-}" = "--toc" ]; then
  [ $# -eq 2 ] || { echo "usage: $0 --toc FILE" >&2; exit 2; }
  printf '## Contents\n\n'
  headings "$2" | sed 's/^/- /'
  exit 0
fi

if [ $# -gt 0 ]; then
  files=("$@")
else
  files=(README.md AGENTS.md)
  for f in docs/*.md; do files+=("$f"); done   # top level only: specs and plans are history
  while IFS= read -r f; do files+=("$f"); done < <(find .apm -name '*.md' | sort)
fi

findings=$(mktemp)
trap 'rm -f "$findings"' EXIT

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "$f: no such file" >> "$findings"; continue; }

  # paths — a repo path starts the line or follows whitespace, a backtick, a quote, ( or [.
  grep -nE '(^|[[:space:]`"(\[])(iac|gitops|docs|provisioner|\.apm|\.github/workflows)/' "$f" |
    grep -v 'check-docs:ignore' |
    while IFS= read -r hit; do
      line=${hit%%:*}
      printf '%s\n' "${hit#*:}" |
        grep -oE '(^|[[:space:]`"(\[])(iac|gitops|docs|provisioner|\.apm|\.github/workflows)/[A-Za-z0-9._/-]*' |
        sed -E 's/^[[:space:]`"(\[]+//; s/[.,:;]+$//' |
        while IFS= read -r p; do
          [ -e "$p" ] || echo "$f:$line: missing path: $p" >> "$findings"
        done
    done

  # toc
  case "$f" in */SKILL.md|SKILL.md) continue ;; esac
  [ "$(wc -l < "$f")" -gt 100 ] || continue
  toc=$(awk '/^## Contents$/ { on = 1; next } on && /^## / { exit } on' "$f")
  if [ -z "$toc" ]; then
    echo "$f: over 100 lines with no '## Contents' section (generate one: $0 --toc $f)" >> "$findings"
    continue
  fi
  headings "$f" | while IFS= read -r h; do
    printf '%s\n' "$toc" | grep -qF -- "$h" || echo "$f: Contents does not list heading: $h" >> "$findings"
  done
done

if [ -s "$findings" ]; then
  cat "$findings"
  echo "check-docs: $(wc -l < "$findings" | tr -d ' ') finding(s)"
  exit 1
fi
echo "check-docs: clean (${#files[@]} files)"
