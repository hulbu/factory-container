#!/usr/bin/env bash
# Tests of the entrypoint without Docker: `bash test/start.test.sh`. The entrypoint's fixed paths are pointed at a
# temporary folder, and `hulbu`, `npm` and `sleep` are small fakes. One case reads releases.hulbu.com (read only) and
# is skipped without a network. Needs GNU `mv` (as `gmv` on macOS) and Node.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
failures=0

fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

contains() {
  local file="$1" text="$2" name="$3"
  if ! grep -F -- "$text" "$file" >/dev/null; then
    fail "$name: the output does not say: $text"
    sed 's/^/    | /' "$file"
  fi
}

# A fresh world: $world/{lib,share,practice,home,shims}; prints its path.
new_world() {
  local world
  world="$(mktemp -d)"
  mkdir -p "$world/lib" "$world/share/keys" "$world/practice" "$world/home" "$world/shims"
  cp "$root/entrypoint/verify-release.mjs" "$world/lib/"
  cp "$root/keys/"*.pub "$world/share/keys/"
  cp "$root/entrypoint/agents.json" "$root/entrypoint/npmrc" "$world/share/"
  sed -e "s#^readonly LIBRARY=.*#readonly LIBRARY=$world/lib#" \
    -e "s#^readonly SHARE=.*#readonly SHARE=$world/share#" \
    -e "s#^readonly PRACTICE=.*#readonly PRACTICE=$world/practice#" \
    "$root/entrypoint/start.sh" >"$world/start.sh"
  if command -v gmv >/dev/null; then ln -s "$(command -v gmv)" "$world/shims/mv"; fi
  cat >"$world/shims/sleep" <<'SHIM'
#!/usr/bin/env bash
printf 'slept %s\n' "$1" >>"$WORLD/sleeps"
exit 99
SHIM
  cat >"$world/shims/npm" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WORLD/npm-calls"
if [[ -n "${FAKE_NPM_TAMPER:-}" && "$1" == install ]]; then
  # An install script that changes the checked program and the saved release file so that they agree.
  program="$HOME/.hulbu/versions/current/hulbu"
  printf 'planted\n' >>"$program"
  node -e 'const fs = require("fs"); const [file, program] = process.argv.slice(1);
    const release = JSON.parse(fs.readFileSync(file, "utf8")); const bytes = fs.readFileSync(program);
    release.program = { ...release.program, size: bytes.length,
      sha256: require("crypto").createHash("sha256").update(bytes).digest("hex") };
    fs.writeFileSync(file, JSON.stringify(release));' "$HOME/.local/state/hulbu-factory/release.json" "$program"
fi
[[ -z "${FAKE_NPM_FAIL:-}" ]] || exit 1
if [[ "$1" == install ]]; then
  # The real npm puts the program in <prefix>/node_modules/.bin/; the prefix is the agent's own folder.
  prefix="" spec="${*: -1}"
  previous=""
  for argument in "$@"; do [[ "$previous" == --prefix ]] && prefix="$argument"; previous="$argument"; done
  [[ -n "${FAKE_NPM_FAIL_PACKAGE:-}" && "$spec" == "$FAKE_NPM_FAIL_PACKAGE"@* ]] && exit 1
  mkdir -p "$prefix/node_modules/.bin"
  printf '#!/bin/sh\necho %s\n' "$spec" >"$prefix/node_modules/.bin/$(basename "$prefix")"
  chmod 755 "$prefix/node_modules/.bin/$(basename "$prefix")"
fi
SHIM
  chmod 755 "$world/shims/sleep" "$world/shims/npm"
  printf '%s\n' "$world"
}

# A fake hulbu that reports platform $2 (and version $3, protocol $4).
fake_program() {
  local path="$1" platform="$2" version="${3:-0.1.144}" protocol="${4:-1.1}"
  cat >"$path" <<PROGRAM
#!/usr/bin/env bash
if [[ "\$1" == version ]]; then
  printf '{"version":"$version","protocol":"$protocol","platform":"$platform","rollback":true,"install":"production","build":"abc1234"}\n'
else
  printf 'RUNNING %s\n' "\$*"
fi
PROGRAM
  chmod 755 "$path"
}

run_start() {
  local world="$1"
  shift
  env "$@" WORLD="$world" HOME="$world/home" PATH="$world/shims:$PATH" bash "$world/start.sh" >"$world/out" 2>&1
}

sha() {
  local value
  value="$(sha256sum "$1")"
  printf '%s\n' "${value%% *}"
}

case "$(uname -m)" in x86_64) platform=linux-x64 ;; *) platform=linux-arm64 ;; esac

# 1. Practice: the right checksums install the files, then the agents, then run `hulbu run`.
world="$(new_world)"
fake_program "$world/practice/hulbu" "$platform"
printf 'driver\n' >"$world/practice/station-driver-claude"
code=0
run_start "$world" HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || code=$?
[[ "$code" -eq 0 ]] || fail "practice: exit $code"
contains "$world/out" "Practice build, not signed" practice
contains "$world/out" "HulbuFactory 0.1.144+abc1234 is installed." practice
contains "$world/out" "RUNNING run" practice
[[ "$(readlink "$world/home/.hulbu/versions/current")" == "0.1.144+abc1234" ]] || fail "practice: current is not 0.1.144+abc1234"
contains "$world/npm-calls" "@anthropic-ai/claude-code@latest" "practice agents"
[[ -x "$world/home/.local/share/hulbu-factory/agents/bin/codex" ]] || fail "practice agents: codex is not linked"
contains "$world/npm-calls" "audit signatures" "practice agents"

# 1b. The next start with the same agents does not run npm again.
rm -f "$world/npm-calls"
run_start "$world" HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || fail "second start failed"
[[ ! -e "$world/npm-calls" ]] || fail "second start: npm ran again"

# 1c. Pinned (the optional setting): exact versions, from the image's list in practice.
world="$(new_world)"
fake_program "$world/practice/hulbu" "$platform"
printf 'driver\n' >"$world/practice/station-driver-claude"
run_start "$world" HULBU_FACTORY_AGENTS=pinned HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || fail "pinned: the start failed"
contains "$world/npm-calls" "@anthropic-ai/claude-code@2.1.327" pinned
contains "$world/npm-calls" "@mariozechner/pi-coding-agent@0.73.1" pinned

# 1d. A setting it does not know is refused, not ignored.
code=0
run_start "$world" HULBU_FACTORY_AGENTS=exact || code=$?
[[ "$code" -eq 1 ]] || fail "unknown agents setting: exit $code, not 1"
contains "$world/out" "the only value it takes is 'pinned'" "unknown agents setting"

# 2. Practice with a wrong checksum: refused, nothing installed.
world="$(new_world)"
fake_program "$world/practice/hulbu" "$platform"
printf 'driver\n' >"$world/practice/station-driver-claude"
code=0
run_start "$world" HULBU_PRACTICE_SHA256="$(printf '0%.0s' {1..64})" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || code=$?
[[ "$code" -eq 1 ]] || fail "wrong checksum: exit $code, not 1"
contains "$world/out" "does not match the SHA-256 you gave" "wrong checksum"
[[ ! -e "$world/home/.hulbu/versions/current" ]] || fail "wrong checksum: something was installed"

# 3. The practice compose file without the files: refused, not silently online.
world="$(new_world)"
code=0
run_start "$world" HULBU_PRACTICE_SHA256=x || code=$?
[[ "$code" -eq 1 ]] || fail "no practice files: exit $code, not 1"
contains "$world/out" "is missing or is not a plain file" "no practice files"

# 4. A build for another platform: refused after its trial run.
world="$(new_world)"
fake_program "$world/practice/hulbu" linux-other
printf 'driver\n' >"$world/practice/station-driver-claude"
code=0
run_start "$world" HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || code=$?
[[ "$code" -eq 1 ]] || fail "other platform: exit $code, not 1"
contains "$world/out" "is built for 'linux-other'" "other platform"

# 5a. One agent cannot be installed: it is reported, the others are installed, the device starts.
world="$(new_world)"
fake_program "$world/practice/hulbu" "$platform"
printf 'driver\n' >"$world/practice/station-driver-claude"
run_start "$world" FAKE_NPM_FAIL_PACKAGE=@openai/codex HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || fail "one agent failing stopped the start"
contains "$world/out" "codex could not be installed or checked" "one agent failing"
[[ -x "$world/home/.local/share/hulbu-factory/agents/bin/claude" ]] || fail "one agent failing: claude is missing"
[[ -x "$world/home/.local/share/hulbu-factory/agents/bin/pi" ]] || fail "one agent failing: pi is missing"
[[ ! -e "$world/home/.local/share/hulbu-factory/agents/bin/codex" ]] || fail "one agent failing: codex is linked"
contains "$world/out" "RUNNING run" "one agent failing"

# 5. No agent can be installed: the device still starts, without them.
world="$(new_world)"
fake_program "$world/practice/hulbu" "$platform"
printf 'driver\n' >"$world/practice/station-driver-claude"
run_start "$world" FAKE_NPM_FAIL=1 HULBU_PRACTICE_SHA256="$(sha "$world/practice/hulbu")" \
  HULBU_PRACTICE_DRIVER_SHA256="$(sha "$world/practice/station-driver-claude")" || fail "npm failure stopped the start"
contains "$world/out" "claude could not be installed or checked" "npm failure"
contains "$world/out" "RUNNING run" "npm failure"
[[ ! -e "$world/home/.local/share/hulbu-factory/agents/claude" ]] || fail "npm failure: the claude folder was kept"

# ── Online, against a local server serving a release signed by a test key ─────────────────────────────────────

releases="$(mktemp -d)"
port_file="$releases.port"
node "$here/fixtures/release-server.mjs" "$releases" "$port_file" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$port_file" ]] && break; /bin/sleep 0.2; done
origin="http://127.0.0.1:$(<"$port_file")"
test_keys="$(mktemp -d)"

# Publishes version $1 (protocol $2) of a fake program that reports version $3 (default $1) and protocol $4.
publish() {
  local version="$1" protocol="$2" reported="${3:-$1}" reported_protocol="${4:-$2}" files
  files="$(mktemp -d)"
  fake_program "$files/hulbu" "$platform" "$reported" "$reported_protocol"
  printf 'driver %s\n' "$version" >"$files/station-driver-claude"
  node "$here/fixtures/make-release.mjs" --out "$releases" --origin "$origin" --keys "$test_keys" --version "$version" \
    --protocol "$protocol" --platform "$platform" --program "$files/hulbu" --driver "$files/station-driver-claude"
}

# A world whose release check trusts only the test key and reads releases from the local server.
online_world() {
  local world
  world="$(new_world)"
  rm -f "$world/share/keys/"*.pub
  cp "$test_keys/test.pub" "$world/share/keys/"
  sed -i.original "s#https://releases.hulbu.com#$origin#g" "$world/lib/verify-release.mjs"
  printf '%s\n' "$world"
}

publish 0.2.0 1.1

# Every fetch of the world's release check fails as with no network.
go_offline() {
  sed -i.online 's#response = await fetchImplementation(url#throw new TypeError("offline"); response = await fetchImplementation(url#' \
    "$1/lib/verify-release.mjs"
}

# 7. A fresh install: downloaded, checked, run once, installed as versions/0.2.0/, then started.
world="$(online_world)"
run_start "$world" || fail "fresh install: exit $?"
contains "$world/out" "Downloading HulbuFactory 0.2.0" "fresh install"
contains "$world/out" "HulbuFactory 0.2.0 is installed." "fresh install"
contains "$world/out" "RUNNING run" "fresh install"
[[ "$(readlink "$world/home/.hulbu/versions/current")" == "0.2.0" ]] || fail "fresh install: current is not 0.2.0"
[[ "$(<"$world/home/.local/state/hulbu-factory/highest-version")" == "0.2.0" ]] || fail "fresh install: highest version"

# 8. The next start downloads nothing.
run_start "$world" || fail "second start: exit $?"
contains "$world/out" "is installed and matches the signed release" "second start"
if grep -F "Downloading" "$world/out" >/dev/null; then fail "second start: it downloaded again"; fi

# 9. A changed installed program is replaced by the signed one at the next start.
printf 'changed\n' >>"$world/home/.hulbu/versions/0.2.0/hulbu"
run_start "$world" || fail "changed program: exit $?"
contains "$world/out" "Downloading HulbuFactory 0.2.0" "changed program"
contains "$world/out" "RUNNING run" "changed program"

# 10. A served file that differs from the signed list: nothing starts, it waits 5 minutes, the refusal is counted.
world="$(online_world)"
printf 'tampered\n' >>"$releases/hulbufactory/cli/$( [[ "$platform" == linux-x64 ]] && echo linux || echo linux/arm64 )/hulbu"
code=0
run_start "$world" || code=$?
[[ "$code" -ne 0 ]] || fail "tampered file: it started"
contains "$world/out" "does not match its signed list" "tampered file"
contains "$world/sleeps" "slept 300" "tampered file"
[[ "$(<"$world/home/.local/state/hulbu-factory/mismatches")" == 1 ]] || fail "tampered file: the refusal was not counted"
if grep -F "RUNNING" "$world/out" >/dev/null; then fail "tampered file: the program ran"; fi

# 11. After 12 refusals in a row it asks for a report and waits an hour.
printf '12\n' >"$world/home/.local/state/hulbu-factory/mismatches"
rm -f "$world/sleeps"
run_start "$world" || true
contains "$world/out" "report it to Hulbu" "repeated refusal"
contains "$world/sleeps" "slept 3600" "repeated refusal"

# 12. An older release than this machine already had is refused.
publish 0.2.0 1.1
world="$(online_world)"
mkdir -p "$world/home/.local/state/hulbu-factory"
printf '0.10.0\n' >"$world/home/.local/state/hulbu-factory/highest-version"
run_start "$world" || true
contains "$world/out" "older than 0.10.0" "older release"
[[ ! -e "$world/home/.hulbu/versions/current" ]] || fail "older release: it was installed"

# 13. A program whose trial run reports another version, or another protocol, is refused.
for case in "0.3.0 1.1 version" "0.2.0 9.9 protocol"; do
  read -r reported reported_protocol what <<<"$case"
  publish 0.2.0 1.1 "$reported" "$reported_protocol"
  world="$(online_world)"
  run_start "$world" || true
  contains "$world/out" "does not start here" "other $what"
  contains "$world/sleeps" "slept 3600" "other $what"
  [[ ! -e "$world/home/.hulbu/versions/current" ]] || fail "other $what: it was installed"
done

# 15. No network on a later start: the program checked earlier is checked again against the kept signed list, and
#     starts; the log says the update check was skipped.
publish 0.2.0 1.1
world="$(online_world)"
run_start "$world" || fail "before going offline: exit $?"
go_offline "$world"
run_start "$world" || fail "offline start: exit $?"
contains "$world/out" "the update check was skipped" "offline start"
contains "$world/out" "RUNNING run" "offline start"

# 16. No network, and the installed program was changed: it is not started.
printf 'changed\n' >>"$world/home/.hulbu/versions/0.2.0/hulbu"
rm -f "$world/sleeps"
run_start "$world" || true
contains "$world/out" "does not match the signed release list kept" "offline, changed program"
contains "$world/sleeps" "slept 60" "offline, changed program"
if grep -F "RUNNING" "$world/out" >/dev/null; then fail "offline, changed program: it ran"; fi

# 17. No network at the very first start: nothing to start; it tries again every minute.
world="$(online_world)"
go_offline "$world"
run_start "$world" || true
contains "$world/out" "no program checked earlier to start" "offline first start"
contains "$world/sleeps" "slept 60" "offline first start"

# 18. A later release with no build for this machine: the program checked earlier starts again, after its check
#     against the kept signed list; the log says why there was no update.
publish 0.2.0 1.1
world="$(online_world)"
run_start "$world" || fail "before the release without this machine: exit $?"
other=linux-x64
[[ "$platform" == linux-x64 ]] && other=linux-arm64
files="$(mktemp -d)"
fake_program "$files/hulbu" "$other" 0.3.0 1.1
printf 'driver\n' >"$files/station-driver-claude"
node "$here/fixtures/make-release.mjs" --out "$releases" --origin "$origin" --keys "$test_keys" --version 0.3.0 \
  --protocol 1.1 --platform "$other" --program "$files/hulbu" --driver "$files/station-driver-claude"
run_start "$world" || fail "release without this machine: exit $?"
contains "$world/out" "has no build for $platform" "release without this machine"
contains "$world/out" "RUNNING run" "release without this machine"
publish 0.2.0 1.1

# 19. A newer release is accepted, but its download breaks off: the program checked earlier still starts, because the
#     kept signed list is replaced only after an install succeeded.
publish 0.2.0 1.1
world="$(online_world)"
run_start "$world" || fail "before the broken download: exit $?"
publish 0.3.0 1.1
# Only the program files fail, as when the network goes away right after the release list was read.
sed -i.files 's#response = await fetchImplementation(url#if (!url.includes("manifest.json")) throw new TypeError("offline"); response = await fetchImplementation(url#' \
  "$world/lib/verify-release.mjs"
run_start "$world" || fail "broken download: exit $?"
contains "$world/out" "HulbuFactory 0.2.0, installed and checked earlier" "broken download"
contains "$world/out" "RUNNING run" "broken download"
publish 0.2.0 1.1

# 14. An agent's install script changes the program and the saved release file together: the last check, made
#     against the release as it was accepted, still refuses to start it.
publish 0.2.0 1.1
world="$(online_world)"
run_start "$world" FAKE_NPM_TAMPER=1 || true
contains "$world/out" "changed while the coding agents were installed" "tampering install script"
if grep -F "RUNNING" "$world/out" >/dev/null; then fail "tampering install script: the program ran"; fi

# 6. Online, the real releases.hulbu.com (read only): today it has no Linux build, so the container says so and waits
#    an hour (the fake sleep ends the run).
world="$(new_world)"
code=0
run_start "$world" || code=$?
if grep -F "Cannot check the HulbuFactory program" "$world/out" >/dev/null; then
  printf 'skipped: no network to releases.hulbu.com\n'
elif grep -F "has no HulbuFactory build for $platform yet" "$world/out" >/dev/null; then
  contains "$world/out" "Practice with a local build" "no Linux build"
  contains "$world/sleeps" "slept 3600" "no Linux build"
  [[ ! -e "$world/home/.hulbu/versions/current" ]] || fail "no Linux build: something was installed"
else
  printf 'note: releases.hulbu.com now answers differently; read this output:\n'
  sed 's/^/    | /' "$world/out"
fi

if [[ "$failures" -gt 0 ]]; then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
printf 'all entrypoint cases passed\n'
