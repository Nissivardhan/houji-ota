#!/bin/bash
# Copy a file that already sits on the build server to a folder of the houji-builds SourceForge project.
# Passwords come from ~/custom-rom/.env and are typed by expect, never printed.
# Usage: upload-sf-file.sh <path on server, relative to ~> <SourceForge folder, e.g. target_files>
set -euo pipefail
FILE="$1"; FOLDER="$2"

cd "$HOME/custom-rom"
set -a; . ./.env; set +a
for v in SERVER_HOST SERVER_PORT SERVER_USER SERVER_PASS SF_USER SF_PASS; do
  [ -n "${!v:-}" ] || { echo "Missing $v in .env"; exit 1; }
done
export FILE FOLDER

expect -c '
  set timeout -1
  log_user 1
  spawn ssh -t -o PubkeyAuthentication=no -o PreferredAuthentications=password -p $env(SERVER_PORT) $env(SERVER_USER)@$env(SERVER_HOST) "scp -o StrictHostKeyChecking=accept-new ~/$env(FILE) $env(SF_USER)@frs.sourceforge.net:/home/frs/project/houji-builds/$env(FOLDER)/ && echo SF_UPLOAD_OK; stat -c %s ~/$env(FILE)"
  expect -re "(?i)@$env(SERVER_HOST).*password:" { send -- "$env(SERVER_PASS)\r" }
  log_user 0
  # SourceForge asks with a bare "Password: " (keyboard-interactive)
  expect -exact "Password: " { send -- "$env(SF_PASS)\r" }
  log_user 1
  expect {
    -exact "Password: " { puts "\nSourceForge rejected the password in .env"; exit 1 }
    eof
  }
'
