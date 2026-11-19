#!/usr/bin/env bash
# Writes profiles/seccomp.json: Docker's default seccomp profile (the one Docker Engine 29.8 uses, moby/profiles
# seccomp v0.2.3, pinned by commit and SHA-256 below) plus ONE added rule, so that bubblewrap can make the agents'
# sandbox inside the container without any capability:
#
#   clone, unshare   with namespace flags (Docker allows them only with CAP_SYS_ADMIN, which this container never has)
#   mount, umount2, pivot_root   (likewise; without capabilities they work only inside the user namespace bubblewrap
#                                 makes, never on the container's own mounts)
#
# Run it when Docker's default profile changes; CI checks that the committed file is what it writes.
# Needs curl, jq and sha256sum (not in the image; run it where you edit this repository).
set -euo pipefail

readonly COMMIT=836ae4d37ef2ec995c77c99fc55f5b5f3af3a897
readonly SHA256=536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74
readonly URL="https://raw.githubusercontent.com/moby/profiles/$COMMIT/seccomp/default.json"

here="$(cd "$(dirname "$0")" && pwd)"
upstream="$(mktemp)"
trap 'rm -f "$upstream"' EXIT
curl -fsS --proto '=https' -o "$upstream" "$URL"
found="$(sha256sum "$upstream")"
if [[ "${found%% *}" != "$SHA256" ]]; then
  echo "Docker's default profile at $COMMIT is not the file this script was written for." >&2
  exit 1
fi
jq --indent 2 '.syscalls += [{
  "comment": "HulbuFactory: an unprivileged user namespace for the agents'"'"' sandbox (bubblewrap); no capability is added",
  "names": ["clone", "unshare", "mount", "umount2", "pivot_root"],
  "action": "SCMP_ACT_ALLOW"
}]' "$upstream" >"$here/seccomp.json"
