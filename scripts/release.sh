#!/bin/bash
# Release a finished PixelOS houji build as an OTA, from the Mac, in one go.
#
#   bash ~/custom-rom/push/ota/release.sh [--beta] <notes.md> [serverhive-link]
#
# --beta publishes only to enrolled beta phones: every API/updater/beta/<tester-id>.json
# gets the build and <notes.md> becomes changelogs/beta/houji.md; the stable feed
# (houji.json) and its changelog stay untouched, and the
# small update is made from the build in the beta feed. A tester's ID is shown in
# Updater > Preferences > Beta program; enroll a phone by copying houji.json to
# API/updater/beta/<id>.json. A stable release also updates beta files that are older.
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
# KEEP_KEYS=1 leaves the release keys on the server afterwards (another build is coming);
# by default they are removed when the script ends, even on errors.
#
# Passwords come from ~/custom-rom/.env and are never printed.
set -euo pipefail

BETA=0; [ "${1:-}" = "--beta" ] && { BETA=1; shift; }
NOTES="${1:-}"
[ -f "$NOTES" ] || { echo "usage: release.sh [--beta] <notes.md> [serverhive-link]  (changelog for this build)"; exit 1; }
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
  if [ "${KEEP_KEYS:-0}" = 1 ]; then
    echo; echo "KEEP_KEYS=1: release keys left on the server for the next build - remove them when done"
    return
  fi
  echo; echo "Removing keys from the server..."
  srv 'rm -rf ~/android/pixelos/vendor/lineage-priv; [ -d ~/android/pixelos/vendor/lineage-priv ] && echo "KEYS STILL ON SERVER" || echo "keys removed"'
}
trap cleanup EXIT

# The previous release is whatever the live feed points at now
# the small update starts from the build the target phones run: stable feed, or the beta feed
PREV_FEED="$FEED/API/updater/houji.json"
if [ $BETA = 1 ]; then
  PREV_FEED="$(ls "$FEED"/API/updater/beta/*.json 2>/dev/null | head -1)"
  [ -n "$PREV_FEED" ] || { echo "No enrolled beta phones (API/updater/beta/*.json)"; exit 1; }
fi
PREV_ZIP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[0]['files'][0]['filename'])" "$PREV_FEED")"
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

# small updates are also made from up to EXTRA_INCR older builds whose target files are on the server
EXTRA_INCR="${EXTRA_INCR:-2}"
EXTRA_TAGS="$(srv 'ls -1t ~/houji-target_files-*.zip 2>/dev/null' | sed -nE 's#.*houji-target_files-([0-9]{8}-[0-9]{4})\.zip$#\1#p' \
  | grep -v -x -e "$PREV_TAG" -e "$TAG" | head -n "$EXTRA_INCR" | tr '\n' ' ')"
echo "older builds: ${EXTRA_TAGS:-none}"

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
# ro.build.date.utc of a build, from its target files: the Updater picks the small update
# made from the build it runs by this value (source_datetime)
utc(){ unzip -p "\$1" SYSTEM/build.prop | sed -n 's/^ro.build.date.utc=//p' | head -1; }
tag_src(){ python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));e=d[0] if isinstance(d,list) else d;e["files"][0]["source_datetime"]=int(sys.argv[2]);json.dump(d,open(f,"w"))' "\$1" "\$2"; }
if [ -f ~/$INCR ]; then
  python3 pixelos_feed.py generate-ota $INCR --url $SF_BASE/PixelOS/incremental/$INCR/download --version 17.0 --output ~/release-incr.json || { log "FAIL feed incremental"; exit 1; }
  tag_src ~/release-incr.json "\$(utc ~/houji-target_files-$PREV_TAG.zip)"
fi
# small updates from older builds too (newest first), for phones that skipped a release
cd ~/android/pixelos
rm -f ~/release-extra-*.json
for OLD in $EXTRA_TAGS; do
  X=incremental_houji_\${OLD}_to_$TAG.zip
  PATH=\$PWD/out/host/linux-x86/bin:\$PATH ota_from_target_files -k vendor/lineage-priv/keys/releasekey \\
    -i ~/houji-target_files-\$OLD.zip \$TF ~/\$X > ~/release-extra-\$OLD.log 2>&1 || { log "EXTRA \$OLD failed"; continue; }
  (cd ~ && python3 pixelos_feed.py generate-ota \$X --url $SF_BASE/PixelOS/incremental/\$X/download --version 17.0 --output ~/release-extra-\$OLD.json) || { log "EXTRA \$OLD feed failed"; continue; }
  tag_src ~/release-extra-\$OLD.json "\$(utc ~/houji-target_files-\$OLD.zip)"
  log "EXTRA \$OLD ok"
done
log "DONE"
EOF
put "$WORK/post.sh" release-post.sh
put "$OTA/pixelos_feed.py" pixelos_feed.py
# a detached tmux window outlives the ssh session (setsid/nohup kept the session open and hung)
srv 'rm -f ~/release.log ~/release-full.json ~/release-incr.json; tmux new-session -d -s release "bash ~/release-post.sh" && echo started' || true
# the server is often overloaded, so poll a status file instead of holding a session open
for i in $(seq 1 120); do
  sleep 30
  # an empty log (step still running) must not trip set -e/pipefail
  ST="$(srv 'cat ~/release.log 2>/dev/null' || true)"
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
EXTRA_OK=""
for OLD in $(echo "$ST" | sed -n 's/^EXTRA \(.*\) ok$/\1/p'); do
  X="incremental_houji_${OLD}_to_${TAG}.zip"
  if bash "$OTA/upload-sf-file.sh" "$X" PixelOS/incremental > "$WORK/up-$OLD.log" 2>&1 && grep -q "^SF_UPLOAD_OK" <(tr -d '\r' < "$WORK/up-$OLD.log"); then
    echo "small update from $OLD: uploaded"; EXTRA_OK="$EXTRA_OK $OLD"
  else
    echo "small update from $OLD: upload failed, left out"
  fi
done
if bash "$OTA/upload-sf-file.sh" "houji-target_files-$TAG.zip" target_files > "$WORK/up3.log" 2>&1 && grep -q "^SF_UPLOAD_OK" <(tr -d '\r' < "$WORK/up3.log"); then
  echo "target files: uploaded"
else
  echo "target files upload FAILED - the release can still go out, but upload them before the server ends"
fi
# new files on SourceForge are listed at once but 404 for a while (seen up to ~15 min):
# wait for them, so the feed never offers a link that doesn't download yet
for u in "PixelOS/$NAME" $( [ $HAVE_INCR = 1 ] && echo "PixelOS/incremental/$INCR" ) $(for o in $EXTRA_OK; do echo "PixelOS/incremental/incremental_houji_${o}_to_${TAG}.zip"; done); do
  for try in $(seq 1 40); do
    code="$(curl -sL -o /dev/null -r 0-1023 -m 60 -w '%{http_code}' "$SF_BASE/$u/download" || true)"
    [ "$code" = 206 ] || [ "$code" = 200 ] && break
    [ $try = 1 ] && echo "waiting for SourceForge to serve $u (got $code)..."
    sleep 30
  done
  echo "link check $code  $u"
  [ "$code" = 206 ] || [ "$code" = 200 ] || { echo "SourceForge still doesn't serve it after 20 min - re-run step 5 by hand later"; exit 1; }
done

say "5/6 feed and changelog"
srv "echo ==F; cat ~/release-full.json; echo; echo ==I; cat ~/release-incr.json 2>/dev/null; echo; echo ==END; for o in $EXTRA_OK; do echo ==X; cat ~/release-extra-\$o.json; echo; done; echo ==XEND" > "$WORK/feeds.txt"
python3 - "$WORK/feeds.txt" "$FEED" "$NOTES" "$BETA" <<'EOF'
import glob, json, sys
txt, feed, notes, beta = sys.argv[1:]
beta = beta == '1'
t = open(txt).read()
full = t.split('==F\n')[1].split('==I')[0].strip()
incr = t.split('==I\n')[1].split('==END')[0].strip()
F = json.loads(full); F = F[0] if isinstance(F, list) else F
if incr:
    I = json.loads(incr); I = I[0] if isinstance(I, list) else I
    F['incremental'] = [I['files'][0]]
# every small update, each tagged with the build it applies to (source_datetime); older
# Updaters only read "incremental" (exactly one file, from the previous build)
extras = [json.loads(x.strip()) for x in t.split('==END')[1].split('==XEND')[0].split('==X\n')[1:] if x.strip()]
extras = [(e[0] if isinstance(e, list) else e)['files'][0] for e in extras]
allinc = ([F['incremental'][0]] if incr else []) + extras
if allinc:
    F['incrementals'] = allinc
    if not incr: F['incremental'] = [extras[0]]
def write(path):
    with open(path, 'w') as f:
        json.dump([F], f, indent=2); f.write('\n')
beta_files = sorted(glob.glob(f'{feed}/API/updater/beta/*.json'))
if beta:
    for b in beta_files: write(b)
    print('beta feed:', len(beta_files), 'enrolled phone(s)')
else:
    write(f'{feed}/API/updater/houji.json')
    # beta phones also get a stable build that is newer than their beta build
    for b in beta_files:
        if json.load(open(b))[0]['datetime'] < F['datetime']: write(b)
cl = f'{feed}/API/updater/changelogs'
if beta:
    # beta builds have their own changelog, read by enrolled phones (latest build only)
    import os
    os.makedirs(f'{cl}/beta', exist_ok=True)
    open(f'{cl}/beta/houji.md', 'w').write(open(notes).read().strip() + '\n')
    print('feed:', F['files'][0]['filename'], F['files'][0]['size'], 'bytes')
    for i in F.get('incrementals', F.get('incremental', [])): print('small update:', i['filename'], i['size'], 'bytes')
    sys.exit(0)
# changelog: current notes go to the top of the history, new notes become the live changelog
cur = open(f'{cl}/houji.md').read().strip() + '\n'
hist = open(f'{cl}/houji-history.md').read()
marker = 'are kept here.\n\n'
i = hist.index(marker) + len(marker)
open(f'{cl}/houji-history.md', 'w').write(hist[:i] + cur + '\n' + hist[i:])
open(f'{cl}/houji.md', 'w').write(open(notes).read().strip() + '\n')
print('feed:', F['files'][0]['filename'], F['files'][0]['size'], 'bytes')
for i in F.get('incrementals', F.get('incremental', [])): print('small update:', i['filename'], i['size'], 'bytes')
EOF
cd "$FEED"
git --no-pager diff --stat
echo
CHAN="$([ $BETA = 1 ] && echo "BETA phones only" || echo "the stable OTA feed")"
read -r -p "Publish $VER to $CHAN now? [y/N] " ok
if [ "$ok" != "y" ] && [ "$ok" != "Y" ]; then
  git checkout -q -- API/updater
  echo "Not published. Feed and changelog left as they were."
  exit 0
fi
git add -A
git commit -qm "houji: $([ $BETA = 1 ] && echo "beta: ")$VER$( [ $HAVE_INCR = 1 ] && echo " with incremental from $PREV_TAG")"
T="$(gh auth token --user "$GH_OWNER")"
B="$(printf 'x-access-token:%s' "$T" | base64)"; unset T
git -c http.extraheader="Authorization: Basic $B" push -q origin main 2>&1 | sed 's/gh[pousr]_[A-Za-z0-9]*/***/g'
unset B
CHECK="API/updater/houji.json"; [ $BETA = 1 ] && CHECK="${PREV_FEED#$FEED/}"
DT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[0]['datetime'])" "$CHECK")"
for i in $(seq 1 30); do
  live="$(curl -s "https://raw.githubusercontent.com/$GH_OWNER/houji-ota/main/$CHECK" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['datetime'])" 2>/dev/null || true)"
  [ "$live" = "$DT" ] && break
  sleep 10
done
[ "$live" = "$DT" ] && echo "LIVE: $([ $BETA = 1 ] && echo "beta ")phones will now be offered $VER" || echo "Pushed, but GitHub isn't serving it yet - check again in a few minutes"

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
