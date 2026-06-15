#!/usr/bin/env bash
# Refresh GitHub stats SVGs with a multi-source fallback chain.
#
# Goal: the README must NEVER show a "failed / rate limit" card.
# Strategy:
#   - For each widget, try a list of source URLs in priority order.
#   - A fetched SVG is ACCEPTED only if it (a) is valid SVG, (b) is large
#     enough to contain real data, and (c) does NOT contain any known
#     error phrase ("Something went wrong", "rate limit", etc.).
#   - The committed file is overwritten ONLY when a clean SVG is obtained.
#   - If every source fails, the existing (old) file is kept untouched, so
#     the profile keeps displaying the last-good value.
#
# Exit code is always 0 unless something catastrophic happens; a widget that
# can't be refreshed is logged but does not fail the workflow (we WANT to keep
# the stale-but-good file in that case).

set -uo pipefail

ASSETS_DIR="${ASSETS_DIR:-assets}"
USER="tungds232"
THEME="tokyonight"
UA="Mozilla/5.0 (compatible; profile-stats-refresher/1.0)"
# Minimum byte size for a "real" card. Error cards are ~700-800B; real cards
# are several KB. 1500 is a safe floor.
MIN_BYTES=1500

# Phrases that indicate an error/placeholder card rather than real stats.
ERROR_RE='Something went wrong|rate limit|rate-limit|rate limiting|Failed to retrieve|Could not (find|fetch|retrieve)|Maximum retries|No contributions|Downtime|deploy own instance|An API error|Bad credentials|Not Found'

mkdir -p "$ASSETS_DIR"

# is_clean_svg <file>  -> 0 if the file is a valid, non-error, large-enough SVG
is_clean_svg() {
  local f="$1"
  [ -s "$f" ] || { echo "    reject: empty file"; return 1; }
  local size
  size=$(wc -c < "$f")
  if [ "$size" -lt "$MIN_BYTES" ]; then
    echo "    reject: too small (${size}B < ${MIN_BYTES}B) — likely an error card"
    return 1
  fi
  if ! grep -qi '<svg' "$f"; then
    echo "    reject: not an SVG (no <svg> tag)"
    return 1
  fi
  if grep -qiE "$ERROR_RE" "$f"; then
    echo "    reject: contains an error phrase"
    return 1
  fi
  return 0
}

# refresh <output-name> <url1> [url2] [url3] ...
# Tries each URL in order; on the first clean result, atomically replaces the
# committed file and returns 0. If none are clean, keeps the old file.
refresh() {
  local name="$1"; shift
  local out="$ASSETS_DIR/$name"
  local tmp="$out.tmp"
  local url i=0

  echo "==> $name"
  for url in "$@"; do
    i=$((i+1))
    echo "  [$i] GET $url"
    if curl -sSL --max-time 45 -A "$UA" "$url" -o "$tmp" 2>/dev/null; then
      if is_clean_svg "$tmp"; then
        mv "$tmp" "$out"
        echo "    ✓ accepted ($(wc -c < "$out")B) -> $out"
        rm -f "$tmp"
        return 0
      fi
    else
      echo "    reject: curl failed"
    fi
    sleep 3   # brief backoff before next source
  done

  rm -f "$tmp"
  if [ -s "$out" ]; then
    echo "  ⚠ all sources failed; KEEPING existing file ($(wc -c < "$out")B) — profile stays intact"
  else
    echo "  ✗ all sources failed AND no existing file present for $name"
  fi
  return 1
}

# --- Source chains (priority order) -----------------------------------------
# Primary: your self-hosted instance (has private-contributions token).
# Fallback: the public community instances (large token pool, rarely limited).

SELF_STATS="https://github-readme-stats.tungds232.com"
PUB_STATS="https://github-readme-stats.vercel.app"
SELF_STREAK="https://streak-stats.tungds232.com"
PUB_STREAK="https://streak-stats.demolab.com"

STATS_Q="username=${USER}&show_icons=true&theme=${THEME}&hide_border=true&count_private=true"
LANGS_Q="username=${USER}&layout=compact&theme=${THEME}&hide_border=true&langs_count=8"
STREAK_Q="user=${USER}&theme=${THEME}&hide_border=true"

refresh "github-stats.svg" \
  "${SELF_STATS}/api?${STATS_Q}" \
  "${PUB_STATS}/api?${STATS_Q}"

refresh "top-langs.svg" \
  "${SELF_STATS}/api/top-langs/?${LANGS_Q}" \
  "${PUB_STATS}/api/top-langs/?${LANGS_Q}"

refresh "streak.svg" \
  "${SELF_STREAK}/?${STREAK_Q}" \
  "${PUB_STREAK}/?${STREAK_Q}"

echo ""
echo "=== final state ==="
for f in github-stats top-langs streak; do
  p="$ASSETS_DIR/$f.svg"
  if [ -s "$p" ]; then
    if is_clean_svg "$p" >/dev/null 2>&1; then
      echo "  $f.svg: $(wc -c < "$p")B (clean)"
    else
      echo "  $f.svg: $(wc -c < "$p")B (STALE/old — kept on purpose)"
    fi
  else
    echo "  $f.svg: MISSING"
  fi
done

exit 0
