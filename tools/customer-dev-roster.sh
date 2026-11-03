#!/usr/bin/env bash
# Refresh docs/customer-dev/roster.md from the production database.
# Only roster.md is regenerated; users/*.md are hand-maintained and never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/customer-dev/roster.md"
CSV="$(mktemp)"
scp -q "$ROOT/tools/customer-dev-roster.sql" root@77.42.73.250:/tmp/roster.sql
ssh root@77.42.73.250 'sudo -u postgres psql -q -d pulsar -f /tmp/roster.sql' > "$CSV"
python3 "$ROOT/tools/customer_dev_roster.py" "$CSV" > "$OUT"
rm -f "$CSV"
echo "wrote $OUT"
