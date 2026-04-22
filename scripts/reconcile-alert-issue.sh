#!/usr/bin/env bash
# scripts/reconcile-alert-issue.sh
#
# Keeps a single rolling GitHub issue in sync with the latest health snapshot.
#
#   all green → close the open alert (if any) with a ✅ resolution comment.
#   non-green + no open alert   → create one; @mentions fire the first email.
#   non-green + same hash       → silently edit the body (no comment, no email).
#   non-green + new hash        → edit the body AND post a comment (email).
#   non-green + snoozed label   → edit the body, skip the comment/email.
#
# Usage:
#   ./scripts/reconcile-alert-issue.sh <grade.json> <alert.md>
#
# Requires: gh CLI authenticated (in CI: GH_TOKEN=${{ secrets.GITHUB_TOKEN }}).
#
# Env vars:
#   ALERT_MENTIONS  mentions repeated in every email-triggering comment
#                   (default: "@azlangaida @gda-gusde")

set -euo pipefail

GRADE_JSON_PATH="$1"
ALERT_MD="$2"

LABEL_ALERT="health-alert"
LABEL_SNOOZED="health-alert-snoozed"
MENTIONS="${ALERT_MENTIONS:-@azlangaida @gda-gusde}"

command -v gh >/dev/null 2>&1 || { echo "reconcile: gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "reconcile: jq not found" >&2; exit 1; }

HASH=$(jq -r .hash    < "$GRADE_JSON_PATH")
COUNT=$(jq -r .alert_count < "$GRADE_JSON_PATH")
SUBJECT=$(jq -r .subject < "$GRADE_JSON_PATH")
TITLE=$(jq -r .title   < "$GRADE_JSON_PATH")

# Ensure both labels exist (idempotent — errors ignored when label already exists).
gh label create "$LABEL_ALERT"   --color "E11D48" --description "Infrastructure health alert (auto-managed)" 2>/dev/null || true
gh label create "$LABEL_SNOOZED" --color "6B7280" --description "Silence comment notifications on the rolling health alert" 2>/dev/null || true

# Find the single open alert issue (newest wins if multiple — shouldn't happen).
EXISTING=$(gh issue list --label "$LABEL_ALERT" --state open --json number,body,labels --limit 1)
ISSUE_NUM=$(echo "$EXISTING" | jq -r '.[0].number // empty')
PREV_BODY=$(echo "$EXISTING" | jq -r '.[0].body // ""')
IS_SNOOZED=$(echo "$EXISTING" | jq -r '
  (.[0].labels // []) | map(.name) | any(. == "'"$LABEL_SNOOZED"'")')
PREV_HASH=$(printf '%s' "$PREV_BODY" | awk '
  /<!-- hash:/ { gsub(/.*hash:|[[:space:]]*-->.*/, ""); print; exit }')

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# -----------------------------------------------------------------------------
# Case 1: all green.
# -----------------------------------------------------------------------------
if [ "$COUNT" -eq 0 ]; then
  if [ -z "$ISSUE_NUM" ]; then
    echo "no-op: all green, no open alert"
    exit 0
  fi
  gh issue comment "$ISSUE_NUM" --body "✅ All hosts green as of \`$NOW\` — closing this alert.

cc $MENTIONS"
  gh issue close "$ISSUE_NUM"
  echo "closed #$ISSUE_NUM (all green)"
  exit 0
fi

# -----------------------------------------------------------------------------
# Case 2: non-green, no open alert → create one.
# -----------------------------------------------------------------------------
if [ -z "$ISSUE_NUM" ]; then
  URL=$(gh issue create \
    --title  "$TITLE" \
    --body-file "$ALERT_MD" \
    --label "$LABEL_ALERT")
  echo "opened $URL ($SUBJECT)"
  exit 0
fi

# -----------------------------------------------------------------------------
# Case 3+4: non-green, existing issue → body-only update OR body + comment.
# -----------------------------------------------------------------------------
gh issue edit "$ISSUE_NUM" --body-file "$ALERT_MD"

if [ "$HASH" = "$PREV_HASH" ]; then
  echo "refreshed #$ISSUE_NUM body (hash unchanged, no comment)"
  exit 0
fi

if [ "$IS_SNOOZED" = "true" ]; then
  echo "refreshed #$ISSUE_NUM body (state changed but issue is snoozed — no comment)"
  exit 0
fi

gh issue comment "$ISSUE_NUM" --body "⚠️ Alert state changed at \`$NOW\` — now: **$SUBJECT**

Full details in the issue body above.

cc $MENTIONS"
echo "updated #$ISSUE_NUM + posted state-change comment"
