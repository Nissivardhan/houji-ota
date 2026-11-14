#!/bin/bash
# Release a finished PixelOS houji build as an OTA, from the Mac, in one go.
#
#   bash ~/custom-rom/push/ota/release.sh <notes.md> [serverhive-link]
#
# [serverhive-link] is the Download link from ServerHive Bot's "Build Completed"
# message for this build (https://artifacts.serverhive.in/?id=...). It goes on the
# Telegram post's Download button. You can also set SERVERHIVE_URL instead.
# Without it the post uses the SourceForge link.
#
# Run it after `mka bacon` finished on the server. <notes.md> is the changelog for
# this build (no need to repeat the version: start with "## PixelOS 17.0 · <date>").
#
# What it does:
#   1. copies the release keys to the server (deleted again when the script ends, even on errors)
#   2. reads the build's version and checks it is signed with our release key
#   3. on the server: names the full zip, makes the small update from the previous
#      build's target files, zips this build's target files, checksums everything
#   4. uploads full zip, small update and target files to SourceForge, checks the links
#   5. moves the current changelog to houji-history.md, puts <notes.md> in its place,
#      writes the feed entry, and asks before pushing it to GitHub
#   6. writes the Channel Help button layout for the Telegram post (Download =
#      ServerHive link if given, else SourceForge) to push/ota/posts/<build>-buttons.txt
#
# The OTA feed itself always points at SourceForge: the Updater needs a direct file
# link, and ServerHive's artifact page is a web page, not the zip.
#
# Passwords come from ~/custom-rom/.env and are never printed.
set -euo pipefail

NOTES="${1:-}"
[ -f "$NOTES" ] || { echo "usage: release.sh <notes.md> [serverhive-link]  (changelog for this build)"; exit 1; }
SH_URL="${2:-${SERVERHIVE_URL:-}}"
if [ -n "$SH_URL" ]; then
  [[ "$SH_URL" =~ ^https://artifacts\.serverhive\.in/\?id=[A-Za-z0-9._-]+$ ]] || { echo "ServerHive link should look like https://artifacts.serverhive.in/?id=pixel-os-aosp-houji-..."; exit 1; }
  [ "$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$SH_URL")" = 200 ] || { echo "ServerHive link doesn't open: $SH_URL"; exit 1; }
fi
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

ROM="$HOME/custom-rom"
OTA="$ROM/push/ota"
FEED="$OTA/feed"
SF_BASE="https://sourceforge.net/projects/houji-builds/files"
GH_OWNER="Nissivardhan"
WORK="$(mktemp -d)"
cd "$ROM"
set -a; . ./.env; set +a
for v in SERVER_HOST SERVER_PORT SERVER_USER SERVER_PASS SF_USER SF_PASS; do
  [ -n "${!v:-}" ] || { echo "Missing $v in .env"; exit 1; }
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
# run a command on the server, drop login noise
srv()  { "$ROM/server.sh" "$1" 2>&1 | tr -d '\r' | grep -v -iE "password|^spawn|^Warning|Connection to"; }
# copy a local file to the server home directory
put()  { F="$1" DST="$2" expect -c 'set timeout 300; log_user 0
  spawn scp -o PubkeyAuthentication=no -o PreferredAuthentications=password -P $env(SERVER_PORT) $env(F) $env(SERVER_USER)@$env(SERVER_HOST):$env(DST)
  expect -re "(?i)password:" { send -- "$env(SERVER_PASS)\r" }; expect eof'; }

cleanup() {
  rm -rf "$WORK"
  echo; echo "Removing keys from the server..."
  srv 'rm -rf ~/android/pixelos/vendor/lineage-priv; [ -d ~/android/pixelos/vendor/lineage-priv ] && echo "KEYS STILL ON SERVER" || echo "keys removed"'
}
trap cleanup EXIT

# The previous release is whatever the live feed points at now
PREV_ZIP="$(python3 -c "import json;print(json.load(open('$FEED/API/updater/houji.json'))[0]['files'][0]['filename'])")"
PREV_TAG="$(echo "$PREV_ZIP" | sed -E 's/^PixelOS_houji-[0-9.]+-([0-9]{8}(-[0-9]{4})?)\.zip$/\1/')"

say "1/6 keys to server"
COPYFILE_DISABLE=1 tar czf "$WORK/k.tgz" -C "$ROM/keys" .
put "$WORK/k.tgz" k.tgz
srv 'K=~/android/pixelos/vendor/lineage-priv/keys; mkdir -p $K; chmod 700 ~/android/pixelos/vendor/lineage-priv $K; tar xzf ~/k.tgz -C $K 2>/dev/null; rm -f ~/k.tgz; chmod 600 $K/*; echo "keys: $(ls $K | wc -l)"'

say "2/6 check the build"
INFO="$(srv 'cd ~/android/pixelos; O=out/target/product/houji
  echo "VER=$(grep -h "^ro.custom.version=" $O/product/etc/build.prop $O/system/build.prop $O/system_ext/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2)"
  echo "ZIPCERT=$(unzip -p $O/lineage-.zip META-INF/com/android/otacert | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)"
  echo "KEYCERT=$(openssl x509 -noout -fingerprint -sha256 -in vendor/lineage-priv/keys/releasekey.x509.pem | cut -d= -f2)"
  echo "ZIPTIME=$(stat -c %y $O/lineage-.zip | cut -c1-16)"')"
VER="$(echo "$INFO" | sed -n 's/^VER=//p')"
ZIPCERT="$(echo "$INFO" | sed -n 's/^ZIPCERT=//p')"
KEYCERT="$(echo "$INFO" | sed -n 's/^KEYCERT=//p')"
ZIPTIME="$(echo "$INFO" | sed -n 's/^ZIPTIME=//p')"
[ -n "$VER" ] || { echo "Could not read the build version on the server"; exit 1; }
[ -n "$KEYCERT" ] && [ "$ZIPCERT" = "$KEYCERT" ] || { echo "The zip is NOT signed with our release key - stopping"; exit 1; }
TAG="$(echo "$VER" | sed -E 's/^PixelOS_houji-[0-9.]+-//')"
NAME="$VER.zip"
INCR="incremental_houji_${PREV_TAG}_to_${TAG}.zip"
echo "build:    $VER (zip made $ZIPTIME), signed with our release key"
echo "previous: $PREV_TAG (from the live feed)"
[ "$NAME" != "$PREV_ZIP" ] || { echo "This build is already the live release"; exit 1; }

say "3/6 small update, target files, checksums (on the server, a few minutes)"
cat > "$WORK/post.sh" <<EOF
#!/bin/bash
cd ~/android/pixelos || exit 1
TF=out/target/product/houji/obj/PACKAGING/target_files_intermediates/custom_houji-target_files
log(){ echo "\$*" >> ~/release.log; }
: > ~/release.log
cp -f out/target/product/houji/lineage-.zip ~/$NAME || { log "FAIL copy"; exit 1; }
if [ -f ~/houji-target_files-$PREV_TAG.zip ]; then
  PATH=\$PWD/out/host/linux-x86/bin:\$PATH ota_from_target_files -k vendor/lineage-priv/keys/releasekey \\
    -i ~/houji-target_files-$PREV_TAG.zip \$TF ~/$INCR > ~/release-incr.log 2>&1 || { log "FAIL incremental"; exit 1; }
  log "INCR ok"
else
  log "INCR none (no target files for $PREV_TAG on the server)"
fi
(cd \$TF && rm -f ~/houji-target_files-$TAG.zip && zip -qry ~/houji-target_files-$TAG.zip .) || { log "FAIL target files zip"; exit 1; }
cd ~
python3 pixelos_feed.py generate-ota $NAME --url $SF_BASE/PixelOS/$NAME/download --version 17.0 --output ~/release-full.json || { log "FAIL feed full"; exit 1; }
if [ -f ~/$INCR ]; then
  python3 pixelos_feed.py generate-ota $INCR --url $SF_BASE/PixelOS/incremental/$INCR/download --version 17.0 --output ~/release-incr.json || { log "FAIL feed incremental"; exit 1; }
fi
log "DONE"
EOF
put "$WORK/post.sh" release-post.sh
put "$OTA/pixelos_feed.py" pixelos_feed.py
# a detached tmux window outlives the ssh session (setsid/nohup kept the session open and hung)
srv 'rm -f ~/release.log ~/release-full.json ~/release-incr.json; tmux new-session -d -s release "bash ~/release-post.sh" && echo started' || true
# the server is often overloaded, so poll a status file instead of holding a session open
for i in $(seq 1 120); do
  sleep 30
  ST="$(srv 'cat ~/release.log 2>/dev/null')"
  echo "$ST" | grep -q -E "^(DONE|FAIL)" && break
done
echo "$ST"
echo "$ST" | grep -q "^DONE" || { echo "Server step did not finish - see ~/release.log and ~/release-incr.log on the server"; exit 1; }
HAVE_INCR=0; echo "$ST" | grep -q "^INCR ok" && HAVE_INCR=1

say "4/6 upload to SourceForge"
bash "$OTA/upload-sf-file.sh" "$NAME" PixelOS > "$WORK/up1.log" 2>&1 && grep -q "^SF_UPLOAD_OK" <(tr -d '\r' < "$WORK/up1.log") || { echo "full zip upload failed"; tail -5 "$WORK/up1.log"; exit 1; }
echo "full zip: uploaded"
if [ $HAVE_INCR = 1 ]; then
  bash "$OTA/upload-sf-file.sh" "$INCR" PixelOS/incremental > "$WORK/up2.log" 2>&1 && grep -q "^SF_UPLOAD_OK" <(tr -d '\r' < "$WORK/up2.log") || { echo "small update upload failed"; exit 1; }
  echo "small update: uploaded"
fi
if bash "$OTA/upload-sf-file.sh" "houji-target_files-$TAG.zip" target_files > "$WORK/up3.log" 2>&1 && grep -q "^SF_UPLOAD_OK" <(tr -d '\r' < "$WORK/up3.log"); then
  echo "target files: uploaded"
else
  echo "target files upload FAILED - the release can still go out, but upload them before the server ends"
fi
for u in "PixelOS/$NAME" $( [ $HAVE_INCR = 1 ] && echo "PixelOS/incremental/$INCR" ); do
  code="$(curl -sL -o /dev/null -r 0-1023 -m 60 -w '%{http_code}' "$SF_BASE/$u/download")"
  echo "link check $code  $u"
  [ "$code" = 206 ] || [ "$code" = 200 ] || { echo "SourceForge doesn't serve it yet - wait a few minutes and re-run step 5 by hand"; exit 1; }
done

say "5/6 feed and changelog"
srv 'echo ==F; cat ~/release-full.json; echo; echo ==I; cat ~/release-incr.json 2>/dev/null; echo; echo ==END' > "$WORK/feeds.txt"
python3 - "$WORK/feeds.txt" "$FEED" "$NOTES" <<'EOF'
import json, sys
txt, feed, notes = sys.argv[1:]
t = open(txt).read()
full = t.split('==F\n')[1].split('==I')[0].strip()
incr = t.split('==I\n')[1].split('==END')[0].strip()
F = json.loads(full); F = F[0] if isinstance(F, list) else F
if incr:
    I = json.loads(incr); I = I[0] if isinstance(I, list) else I
    F['incremental'] = [I['files'][0]]
json.dump([F], open(f'{feed}/API/updater/houji.json', 'w'), indent=2)
open(f'{feed}/API/updater/houji.json', 'a').write('\n')
# changelog: current notes go to the top of the history, new notes become the live changelog
cl = f'{feed}/API/updater/changelogs'
cur = open(f'{cl}/houji.md').read().strip() + '\n'
hist = open(f'{cl}/houji-history.md').read()
marker = 'are kept here.\n\n'
i = hist.index(marker) + len(marker)
open(f'{cl}/houji-history.md', 'w').write(hist[:i] + cur + '\n' + hist[i:])
open(f'{cl}/houji.md', 'w').write(open(notes).read().strip() + '\n')
print('feed:', F['files'][0]['filename'], F['files'][0]['size'], 'bytes')
if incr: print('small update:', F['incremental'][0]['filename'], F['incremental'][0]['size'], 'bytes')
EOF
cd "$FEED"
git --no-pager diff --stat
echo
read -r -p "Publish $VER to the OTA feed now? [y/N] " ok
if [ "$ok" != "y" ] && [ "$ok" != "Y" ]; then
  git checkout -q -- API/updater
  echo "Not published. Feed and changelog left as they were."
  exit 0
fi
git add -A
git commit -qm "houji: $VER$( [ $HAVE_INCR = 1 ] && echo " with incremental from $PREV_TAG")"
T="$(gh auth token --user "$GH_OWNER")"
B="$(printf 'x-access-token:%s' "$T" | base64)"; unset T
git -c http.extraheader="Authorization: Basic $B" push -q origin main 2>&1 | sed 's/gh[pousr]_[A-Za-z0-9]*/***/g'
unset B
DT="$(python3 -c "import json;print(json.load(open('API/updater/houji.json'))[0]['datetime'])")"
for i in $(seq 1 30); do
  live="$(curl -s "https://raw.githubusercontent.com/$GH_OWNER/houji-ota/main/API/updater/houji.json" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['datetime'])" 2>/dev/null || true)"
  [ "$live" = "$DT" ] && break
  sleep 10
done
[ "$live" = "$DT" ] && echo "LIVE: phones will now be offered $VER" || echo "Pushed, but GitHub isn't serving it yet - check again in a few minutes"

say "6/6 Telegram post buttons"
DL="${SH_URL:-$SF_BASE/PixelOS/$NAME/download}"
mkdir -p "$OTA/posts"
BTN="$OTA/posts/$TAG-buttons.txt"
cat > "$BTN" <<BUTTONS
📥 Download - $DL
📝 Changelog - https://github.com/$GH_OWNER/houji-ota/blob/main/CHANGELOG.md && ❤️ Donate - https://t.me/Build_Test_Lab/109
BUTTONS
echo "Download button: $([ -n "$SH_URL" ] && echo ServerHive || echo "SourceForge (no ServerHive link given)")"
echo "Paste this into Channel Help when it asks for buttons (saved in $BTN):"
echo; cat "$BTN"
