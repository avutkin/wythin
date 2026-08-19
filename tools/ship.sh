#!/bin/bash
# ship.sh — the ONLY sanctioned path from code to Alex's devices.
#
# Exists because parallel Claude sessions kept regressing each other:
# installs built from stale feature branches erased shipped features from the
# phone; TestFlight uploads missed work that was only merged locally; build
# numbers collided because ASC's high-water mark lives outside the repo.
# Every rule in here is a fossil of a real incident (see CLAUDE.md).
#
# Usage:
#   tools/ship.sh status       # where is every system right now?
#   tools/ship.sh phone        # origin/main -> tests -> iPhone install
#   tools/ship.sh testflight   # origin/main -> tests -> ASC upload + compliance
#
# Flags: --skip-tests (emergencies only; says so out loud)

set -euo pipefail

REPO=/Users/alexutkin/Code/Wythin
RELEASE_WT=$REPO/.claude/worktrees/release
UDID=${WYTHIN_UDID:-261974DA-1CFB-5977-AD58-3A45BB95214B}
BUNDLE=com.alexutkin.wythin
ASC_APP=6794412132
ASC_KEY=K2R557DK2R
ASC_ISSUER=8990b462-980a-4dc2-b18d-dd5af9e4e5a9
ASC_P8=$HOME/.appstoreconnect/private_keys/AuthKey_K2R557DK2R.p8
SHIP_LOG=$HOME/.wythin-ship.log
DERIVED=$HOME/Library/Developer/Xcode/DerivedData

say()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$SHIP_LOG"; }

jwt() {
  xcrun altool --generate-jwt --apiKey "$ASC_KEY" --apiIssuer "$ASC_ISSUER" \
    --p8-file-path "$ASC_P8" 2>&1 | grep -oE 'eyJ[A-Za-z0-9._-]+' | tail -1
}

asc_latest_builds() {  # prints "version state" lines, newest first
  curl -s -H "Authorization: Bearer $(jwt)" \
    "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$ASC_APP&sort=-uploadedDate&limit=${1:-3}" \
    | /usr/bin/python3 -c 'import json,sys
for b in json.load(sys.stdin).get("data",[]):
    a=b["attributes"]; print(b["id"], a["version"], a["processingState"])'
}

phone_state() {  # "connected", "available", or "unreachable"
  local line
  line=$(xcrun devicectl list devices 2>/dev/null | grep "$UDID" || true)
  case "$line" in
    *connected*)           echo connected ;;
    *'available (paired)'*) echo available ;;
    *)                     echo unreachable ;;
  esac
}

sim_id() {
  xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]*\(([0-9A-F-]+)\)' \
    | grep -oE '[0-9A-F-]{36}' || die "no available iPhone simulator for tests"
}

# ── The invariant every command shares: build ONLY from origin/main ─────────
sync_release_worktree() {
  say "syncing release worktree to origin/main"
  git -C "$REPO" fetch origin --quiet
  if [ ! -d "$RELEASE_WT" ]; then
    git -C "$REPO" worktree add --detach "$RELEASE_WT" origin/main --quiet
  fi
  # Detached + hard reset: this tree is a build artifact, never an editing
  # surface. Anything a session left here is an error and gets discarded.
  local dirt
  dirt=$(git -C "$RELEASE_WT" status --porcelain | head -3)
  [ -n "$dirt" ] && warn "release worktree had stray changes (discarding):"$'\n'"$dirt"
  git -C "$RELEASE_WT" checkout --detach --quiet origin/main
  git -C "$RELEASE_WT" reset --hard --quiet origin/main
  git -C "$RELEASE_WT" clean -fdq ios
  ok "release worktree at $(git -C "$RELEASE_WT" rev-parse --short HEAD) = origin/main"
}

run_suite() {
  if [ "${SKIP_TESTS:-0}" = 1 ]; then
    warn "TESTS SKIPPED by flag — you own the consequences"
    return
  fi
  say "running full test suite (simulator)"
  local out=/tmp/wythin-ship-tests.log
  xcodebuild test -project "$RELEASE_WT/ios/Wythin.xcodeproj" -scheme Wythin \
    -destination "platform=iOS Simulator,id=$(sim_id)" > "$out" 2>&1 \
    || { tail -20 "$out"; die "test suite FAILED — nothing ships from a red tree"; }
  grep -q 'TEST SUCCEEDED' "$out" || die "no TEST SUCCEEDED marker — inspect $out"
  ok "full suite green"
}

find_app() {
  ls -td "$DERIVED"/Wythin-*/Build/Products/Debug-iphoneos/Wythin.app 2>/dev/null | head -1
}

# ── status ───────────────────────────────────────────────────────────────
cmd_status() {
  git -C "$REPO" fetch origin --quiet
  say "git"
  local lm om ahead behind
  lm=$(git -C "$REPO" rev-parse --short main)
  om=$(git -C "$REPO" rev-parse --short origin/main)
  read -r ahead behind < <(git -C "$REPO" rev-list --left-right --count main...origin/main)
  echo "  local main  $lm   origin/main $om   (local +$ahead / -$behind)"
  [ "$ahead"  != 0 ] && warn "local main has $ahead unpushed commit(s) — push or they WILL regress a device install"
  [ "$behind" != 0 ] && warn "local main is $behind behind origin — another session pushed; pull before merging"

  say "worktrees with uncommitted work"
  git -C "$REPO" worktree list --porcelain | grep '^worktree ' | cut -d' ' -f2 | while read -r wt; do
    local n
    n=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" != 0 ] && echo "  $wt — $n dirty file(s) [$(git -C "$wt" branch --show-current 2>/dev/null || echo detached)]"
  done || true

  say "TestFlight (App Store Connect)"
  asc_latest_builds 3 | while read -r _ ver state; do echo "  build $ver  $state"; done \
    || warn "ASC unreachable"

  say "iPhone"
  local st; st=$(phone_state)
  echo "  device: $st"
  if [ "$st" != unreachable ]; then
    xcrun devicectl device info apps --device "$UDID" 2>/dev/null \
      | grep -i wythin | head -1 | sed 's/^/  installed: /' || true
  fi
  say "last ships (this Mac)"
  tail -3 "$SHIP_LOG" 2>/dev/null | sed 's/^/  /' || echo "  none recorded"
}

# ── phone ────────────────────────────────────────────────────────────────
cmd_phone() {
  sync_release_worktree
  run_suite
  say "building for device"
  xcodebuild -project "$RELEASE_WT/ios/Wythin.xcodeproj" -scheme Wythin \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates build \
    > /tmp/wythin-ship-build.log 2>&1 || { tail -15 /tmp/wythin-ship-build.log; die "build failed"; }
  local app; app=$(find_app); [ -n "$app" ] || die "built app not found under DerivedData"

  local st; st=$(phone_state)
  [ "$st" = unreachable ] && die "iPhone unreachable — plug it in or join the Mac's Wi-Fi, then re-run"
  say "installing to iPhone ($st)"
  xcrun devicectl device install app --device "$UDID" "$app" >/dev/null 2>&1 \
    || { sleep 15; xcrun devicectl device install app --device "$UDID" "$app" >/dev/null; }
  xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null 2>&1 \
    || warn "installed, but launch refused (phone locked?) — open the app manually"
  log "phone-install $(git -C "$RELEASE_WT" rev-parse --short HEAD)"
  ok "iPhone now runs origin/main @ $(git -C "$RELEASE_WT" rev-parse --short HEAD)"
}

# ── testflight ───────────────────────────────────────────────────────────
cmd_testflight() {
  [ -f "$ASC_P8" ] || die "ASC API key missing at $ASC_P8"
  sync_release_worktree
  run_suite

  say "querying ASC build high-water mark"
  local top next
  top=$(asc_latest_builds 1 | awk '{print $2}')
  [ -n "$top" ] || die "could not read latest ASC build number"
  next=$((top + 1))
  ok "ASC is at $top → uploading as $next"

  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $next;/g" \
    "$RELEASE_WT/ios/Wythin.xcodeproj/project.pbxproj"
  git -C "$RELEASE_WT" commit -aqm "chore: build $next

Co-Authored-By: ship.sh <noreply@anthropic.com>"
  # Record the number on origin/main so parallel sessions see it. A racing
  # push loses gracefully: the upload still carries the right number.
  git -C "$RELEASE_WT" push origin HEAD:main --quiet 2>/dev/null \
    && ok "build number $next recorded on origin/main" \
    || warn "could not push build-number bump (race?) — number $next is still correct in the IPA"

  say "archiving Release"
  local arch=/tmp/wythin-ship-$next.xcarchive plist=/tmp/wythin-ship-upload.plist
  rm -rf "$arch"
  cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>FHUVQ8JNXD</string>
	<key>signingStyle</key><string>automatic</string>
	<key>destination</key><string>upload</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST
  xcodebuild -project "$RELEASE_WT/ios/Wythin.xcodeproj" -scheme Wythin \
    -configuration Release -destination 'generic/platform=iOS' \
    archive -archivePath "$arch" -allowProvisioningUpdates \
    > /tmp/wythin-ship-archive.log 2>&1 || { tail -15 /tmp/wythin-ship-archive.log; die "archive failed"; }

  say "uploading to App Store Connect"
  xcodebuild -exportArchive -archivePath "$arch" -exportOptionsPlist "$plist" \
    -exportPath /tmp/wythin-ship-export -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_P8" -authenticationKeyID "$ASC_KEY" \
    -authenticationKeyIssuerID "$ASC_ISSUER" \
    > /tmp/wythin-ship-upload.log 2>&1 || { tail -15 /tmp/wythin-ship-upload.log; die "upload failed"; }
  ok "upload accepted — waiting for processing"

  local i bid ver state
  for i in $(seq 1 20); do
    read -r bid ver state < <(asc_latest_builds 1)
    if [ "$ver" = "$next" ] && [ "$state" = VALID ]; then
      curl -s -o /dev/null -w '' -X PATCH -H "Authorization: Bearer $(jwt)" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"id\":\"$bid\",\"type\":\"builds\",\"attributes\":{\"usesNonExemptEncryption\":false}}}" \
        "https://api.appstoreconnect.apple.com/v1/builds/$bid"
      log "testflight-upload $next $(git -C "$RELEASE_WT" rev-parse --short HEAD)"
      ok "build $next VALID, compliance set — live for internal testers"
      return
    fi
    sleep 60
  done
  warn "build $next uploaded but not VALID after 20 min — check ASC; compliance not yet set"
}

case "${1:-}" in
  status)     cmd_status ;;
  phone)      shift; [ "${1:-}" = --skip-tests ] && SKIP_TESTS=1; cmd_phone ;;
  testflight) shift; [ "${1:-}" = --skip-tests ] && SKIP_TESTS=1; cmd_testflight ;;
  *) grep '^#' "$0" | head -14 | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
