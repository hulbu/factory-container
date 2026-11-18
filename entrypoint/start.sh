#!/usr/bin/env bash
# The HulbuFactory container's entrypoint. At every start it:
#   1. installs the HulbuFactory program (`hulbu` and its Claude driver) into the volume: the newest signed release
#      from releases.hulbu.com, checked by verify-release.mjs, or, for practice, two files you mount at /practice/
#      and whose SHA-256 values you pass;
#   2. installs the coding agents (Claude Code, Codex, pi) into the volume, each on its own; they then update
#      themselves as they normally do, unless you pin them (HULBU_FACTORY_AGENTS=pinned, see the README);
#   3. runs `hulbu run` as the container's main process.
# Nothing it downloads runs before it is checked. It never prints a secret: it reads none.
set -euo pipefail

readonly LIBRARY=/usr/local/lib/hulbu-factory
readonly SHARE=/usr/local/share/hulbu-factory
readonly PRACTICE=/practice
readonly DRIVER_FILE=station-driver-claude

: "${HOME:?HOME is not set}"
readonly VERSIONS="$HOME/.hulbu/versions"
readonly STATE="$HOME/.local/state/hulbu-factory"
readonly AGENTS="$HOME/.local/share/hulbu-factory/agents"
readonly SIGNED="$STATE/signed"

say() {
  printf 'hulbu-factory: %s\n' "$*" >&2
}

# The release check runs with a fixed home and no Node options from outside, so nothing in the volume can feed it code.
check() {
  env -u NODE_OPTIONS -u NODE_PATH HOME=/nonexistent node "$LIBRARY/verify-release.mjs" "$@"
}

machine_platform() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64) printf 'linux-x64\n' ;;
    aarch64 | arm64) printf 'linux-arm64\n' ;;
    *)
      say "This machine is $machine; HulbuFactory runs on x86_64 (amd64) and aarch64 (arm64) only."
      exit 1
      ;;
  esac
}

# A field of the JSON in $2, read with Node (no jq in the image).
json_field() {
  node -e 'const value = JSON.parse(process.argv[1])[process.argv[2]]; process.stdout.write(typeof value === "string" ? value : "")' "$2" "$1"
}

# Waits, then ends the container with an error; the restart policy starts it again later.
stop_after() {
  local seconds="$1"
  say "Trying again in $((seconds / 60)) minutes."
  sleep "$seconds"
  exit 1
}

# Runs the program in folder $1 once (`hulbu version --json`) and checks what it says: its platform ($2), and for a
# release ($3 = release) the version ($4) and protocol ($5) of the signed list. Then it becomes the installed version,
# in the folder `hulbu` itself would use (a release: versions/<version>/, as `hulbu update` installs it; a build of
# your own: versions/<version>+<build>/, as `hulbu update local` does), and `current` points at it.
install_folder() {
  local source="$1" platform="$2" kind="$3" expected_version="${4:-}" expected_protocol="${5:-}"
  local report version protocol found_platform build folder target replaced link
  if ! report="$("$source/hulbu" version --json)"; then
    say "The HulbuFactory program does not run on this machine (its 'version --json' failed, see above)."
    if [[ "$kind" == local ]]; then
      say "A build of your own must be made for $platform and for glibc 2.36 or older (Debian 12)."
    fi
    return 1
  fi
  version="$(json_field version "$report")"
  protocol="$(json_field protocol "$report")"
  found_platform="$(json_field platform "$report")"
  build="$(json_field build "$report")"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    say "The HulbuFactory program reports no readable version."
    return 1
  fi
  if [[ "$kind" == release && "$version" != "$expected_version" ]]; then
    say "The downloaded program says it is $version, but the signed list says $expected_version."
    return 1
  fi
  if [[ "$kind" == release && "$protocol" != "$expected_protocol" ]]; then
    say "The downloaded program speaks protocol '$protocol', but the signed list says '$expected_protocol'."
    return 1
  fi
  if [[ "$found_platform" != "$platform" ]]; then
    say "The HulbuFactory program is built for '$found_platform', and this machine is $platform."
    return 1
  fi
  if [[ "$kind" == release ]]; then
    folder="$version"
  elif [[ -z "$build" || "$build" == "dev" || "$version" == *+* ]]; then
    folder="$version"
  elif [[ "$build" =~ ^[0-9A-Za-z.-]+$ ]]; then
    folder="$version+$build"
  else
    say "The HulbuFactory program reports a build name that cannot be a folder name."
    return 1
  fi
  # Called as a condition, so `set -e` does not apply in here: every step says itself when it fails.
  target="$VERSIONS/$folder"
  if [[ -e "$target" ]]; then
    replaced="$VERSIONS/.replaced.$$"
    rm -rf "$replaced" && mv -T "$target" "$replaced" && rm -rf "$replaced" || return 1
  fi
  mv -T "$source" "$target" || return 1
  link="$VERSIONS/.current.$$"
  rm -f "$link" && ln -s "$folder" "$link" && mv -T "$link" "$VERSIONS/current" || return 1
  say "HulbuFactory $folder is installed."
}

# ── Practice: two files you built yourself, mounted read only at /practice/ ─────────────────────────────────────

practice_file_matches() {
  local path="$1" wanted="$2" name="$3" found
  if [[ ! -f "$path" || -L "$path" ]]; then
    say "$path is missing or is not a plain file. Mount a folder holding both hulbu and $DRIVER_FILE at $PRACTICE."
    return 1
  fi
  if [[ ! "$wanted" =~ ^[0-9a-f]{64}$ ]]; then
    say "Give the SHA-256 of $name as 64 lower-case hex characters (see 'Practice with a local build' in the README)."
    return 1
  fi
  found="$(sha256sum "$path")"
  found="${found%% *}"
  if [[ "$found" != "$wanted" ]]; then
    say "The practice program at $path does not match the SHA-256 you gave ($found is not $wanted)." \
      "Nothing was started. Check that you copied the right file and its value."
    return 1
  fi
}

install_practice() {
  local platform="$1" partial="$VERSIONS/practice.partial"
  say "Practice build, not signed: using the files at $PRACTICE, checked only against the SHA-256 values you gave."
  practice_file_matches "$PRACTICE/hulbu" "${HULBU_PRACTICE_SHA256:-}" hulbu || exit 1
  practice_file_matches "$PRACTICE/$DRIVER_FILE" "${HULBU_PRACTICE_DRIVER_SHA256:-}" "$DRIVER_FILE" || exit 1
  rm -rf "$partial"
  mkdir -m 700 "$partial"
  install -m 755 "$PRACTICE/hulbu" "$partial/hulbu"
  install -m 755 "$PRACTICE/$DRIVER_FILE" "$partial/$DRIVER_FILE"
  # The copies are what runs: check them again, in case a file changed while it was copied.
  practice_file_matches "$partial/hulbu" "$HULBU_PRACTICE_SHA256" hulbu || exit 1
  practice_file_matches "$partial/$DRIVER_FILE" "$HULBU_PRACTICE_DRIVER_SHA256" "$DRIVER_FILE" || exit 1
  install_folder "$partial" "$platform" local || exit 1
}

# ── Online: the newest signed release from releases.hulbu.com ──────────────────────────────────────────────────

# The release list just accepted becomes the kept one, for later starts without network, only once the program it
# lists is installed and checked; until then the kept one stays the list of the program installed before.
keep_signed() {
  rm -rf "$SIGNED.previous"
  if [[ -e "$SIGNED" ]]; then mv -T "$SIGNED" "$SIGNED.previous"; fi
  mv -T "$SIGNED.pending" "$SIGNED"
  rm -rf "$SIGNED.previous"
}

# No network, or a newest release without a build for this machine: start the program installed earlier, but only
# after checking it again against the signed release list kept from that start (its signature with the pinned keys,
# then both files). Never an unchecked program. $3 says why there is no update.
start_installed() {
  local platform="$1" release="$2" why="$3" version
  [[ -e "$VERSIONS/current" ]] || return 1
  if ! version="$(check check-stored --keys "$SHARE/keys" --platform "$platform" \
    --highest "$STATE/highest-version" --save "$SIGNED" --out "$release")"; then
    say "The signed release list kept from an earlier start does not pass its checks."
    return 1
  fi
  if ! check matches --release "$release" --folder "$VERSIONS/current"; then
    say "The installed HulbuFactory program does not match the signed release list kept from an earlier start."
    return 1
  fi
  say "$why" "HulbuFactory $version, installed and checked earlier, matches its signed release list and starts."
  return 0
}

# Repeated mismatches: the first hour (12 tries, 5 minutes apart) can be a release being published; after that it
# is worth a person's look, and the container tries only once an hour.
refuse_mismatch() {
  local count=0
  if [[ -f "$STATE/mismatches" ]]; then
    count="$(<"$STATE/mismatches")"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$STATE/mismatches"
  if ((count <= 12)); then
    say "Nothing was started. This happens for a minute or two while a new release is being published."
    stop_after 300
  fi
  say "Nothing was started, and this has happened $count times in a row." \
    "Do not use this machine's download: report it to Hulbu (see the README)."
  stop_after 3600
}

install_release() {
  local platform="$1" release="$2" version protocol code partial
  while true; do
    code=0
    version="$(check check-manifest --keys "$SHARE/keys" --platform "$platform" \
      --highest "$STATE/highest-version" --save "$SIGNED.pending" --out "$release")" || code=$?
    if [[ "$code" -eq 0 ]]; then
      if check matches --release "$release" --folder "$VERSIONS/current"; then
        say "HulbuFactory $version is installed and matches the signed release."
        keep_signed
        break
      fi
      say "Downloading HulbuFactory $version for $platform."
      protocol="$(json_field protocol "$(<"$release")")"
      partial="$VERSIONS/$version.partial"
      check download --release "$release" --into "$partial" || code=$?
      if [[ "$code" -eq 0 ]]; then
        if install_folder "$partial" "$platform" release "$version" "$protocol"; then
          keep_signed
          break
        fi
        rm -rf "$partial"
        say "HulbuFactory $version from releases.hulbu.com does not start here. Nothing was started."
        stop_after 3600
      fi
      rm -rf "$partial"
    fi
    case "$code" in
      10)
        if start_installed "$platform" "$release" "releases.hulbu.com cannot be reached: the update check was skipped."; then
          return 0
        fi
        say "Cannot check the HulbuFactory program without releases.hulbu.com, and there is no program checked earlier to start." \
          "Check this machine's internet connection; trying again in a minute."
        sleep 60
        ;;
      12)
        if start_installed "$platform" "$release" "The newest release has no build for $platform, so there is no update."; then
          return 0
        fi
        say "Until it has, use a build of your own: see 'Practice with a local build' in the README."
        stop_after 3600
        ;;
      *)
        say "The HulbuFactory program from releases.hulbu.com does not match its signed list (see the line above)."
        refuse_mismatch
        ;;
    esac
  done
  rm -f "$STATE/mismatches"
  printf '%s\n' "$version" >"$STATE/highest-version"
}

# ── The coding agents ───────────────────────────────────────────────────────────────────────────────────────────

# One agent into its own folder ($AGENTS/<program>/), linked into $AGENTS/bin/. A failure is reported and leaves the
# other agents as they are.
install_agent() {
  local program="$1" spec="$2" folder="$AGENTS/$1"
  # Normally an agent installed once keeps its own update path; pinned, it is installed again when the pin changes.
  if [[ -f "$folder/.installed" && "$(<"$folder/.installed")" == "$spec" && -x "$AGENTS/bin/$program" ]]; then
    return 0
  fi
  say "Installing $spec."
  rm -rf "$folder"
  mkdir -p "$folder" "$AGENTS/bin"
  # npm reads no configuration from the volume: the public registry, and the image's empty user configuration.
  local -a npm_options=(--prefix "$folder" --registry=https://registry.npmjs.org/ --userconfig="$SHARE/npmrc"
    --no-update-notifier)
  if npm install "${npm_options[@]}" --no-fund --no-audit --omit=dev "$spec" \
    && npm audit signatures "${npm_options[@]}" \
    && [[ -x "$folder/node_modules/.bin/$program" ]]; then
    ln -sfn "../$program/node_modules/.bin/$program" "$AGENTS/bin/$program"
    printf '%s\n' "$spec" >"$folder/.installed"
    say "$program is installed."
  else
    rm -rf "$folder"
    rm -f "$AGENTS/bin/$program"
    say "$program could not be installed or checked (see npm's lines above); the other agents are not affected." \
      "This container tries again at the next start."
  fi
}

install_agents() {
  local release="$1" pinned="$2" listed program spec
  if ! listed="$(check agent-versions --release "$release" --defaults "$SHARE/agents.json" --pinned "$pinned")"; then
    say "The coding agents' versions cannot be read; starting without installing any."
    return 0
  fi
  while read -r program spec; do
    [[ -n "$program" ]] && install_agent "$program" "$spec"
  done <<<"$listed"
  return 0
}

main() {
  local platform release accepted=""
  # Optional: HULBU_FACTORY_AGENTS=pinned installs the agents at exact versions and turns Claude Code's updater off.
  local pinned=no
  case "${HULBU_FACTORY_AGENTS:-}" in
    "") ;;
    pinned)
      pinned=yes
      export DISABLE_AUTOUPDATER=1
      ;;
    *)
      say "HULBU_FACTORY_AGENTS is '${HULBU_FACTORY_AGENTS}'; the only value it takes is 'pinned'."
      exit 1
      ;;
  esac
  platform="$(machine_platform)"
  mkdir -p "$VERSIONS" "$STATE"
  # Practice when the practice compose file is used (it sets the checksums) or practice files are mounted.
  if [[ -n "${HULBU_PRACTICE_SHA256:-}${HULBU_PRACTICE_DRIVER_SHA256:-}" || -e "$PRACTICE/hulbu" || -e "$PRACTICE/$DRIVER_FILE" ]]; then
    install_practice "$platform"
    release=none
  else
    release="$STATE/release.json"
    install_release "$platform" "$release"
    # The release as it was accepted, kept here: the last check must not trust a file in the volume.
    accepted="$(<"$release")"
  fi
  install_agents "$release" "$pinned"
  # The agents' install scripts ran after the program was checked: check it once more, last, then start it.
  if [[ "$release" == none ]]; then
    practice_file_matches "$VERSIONS/current/hulbu" "$HULBU_PRACTICE_SHA256" hulbu || exit 1
    practice_file_matches "$VERSIONS/current/$DRIVER_FILE" "$HULBU_PRACTICE_DRIVER_SHA256" "$DRIVER_FILE" || exit 1
  elif ! check matches --release-json "$accepted" --folder "$VERSIONS/current"; then
    say "The installed HulbuFactory program changed while the coding agents were installed. Nothing was started."
    stop_after 300
  fi
  exec "$VERSIONS/current/hulbu" run
}

main "$@"
