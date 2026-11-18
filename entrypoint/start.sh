#!/usr/bin/env bash
# The HulbuFactory container's entrypoint. At every start it:
#   1. installs the HulbuFactory program (`hulbu` and its Claude driver) into the volume: the newest signed release
#      from releases.hulbu.com, checked by verify-release.mjs, or, for practice, two files you mount at /practice/
#      and whose SHA-256 values you pass;
#   2. installs the coding agents (Claude Code, Codex, pi) at exact versions into the volume;
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
      --highest "$STATE/highest-version" --out "$release")" || code=$?
    if [[ "$code" -eq 0 ]]; then
      if check matches --release "$release" --folder "$VERSIONS/current"; then
        say "HulbuFactory $version is installed and matches the signed release."
        break
      fi
      say "Downloading HulbuFactory $version for $platform."
      protocol="$(json_field protocol "$(<"$release")")"
      partial="$VERSIONS/$version.partial"
      check download --release "$release" --into "$partial" || code=$?
      if [[ "$code" -eq 0 ]]; then
        if install_folder "$partial" "$platform" release "$version" "$protocol"; then
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
        say "Cannot check the HulbuFactory program without releases.hulbu.com." \
          "Check this machine's internet connection; trying again in a minute."
        sleep 60
        ;;
      12)
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

install_agents() {
  local release="$1" listed line
  local -a wanted
  if ! listed="$(check agent-versions --release "$release" --defaults "$SHARE/agents.json")"; then
    say "The coding agents' versions cannot be read; starting without them."
    return 0
  fi
  wanted=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && wanted+=("$line")
  done <<<"$listed"
  if [[ -f "$AGENTS/.installed" && "$(<"$AGENTS/.installed")" == "$listed" ]]; then
    return 0
  fi
  say "Installing the coding agents: ${wanted[*]}."
  rm -rf "$AGENTS"
  mkdir -p "$AGENTS"
  # npm reads no configuration from the volume: the public registry, and the image's empty user configuration.
  local -a npm_options=(--prefix "$AGENTS" --registry=https://registry.npmjs.org/ --userconfig="$SHARE/npmrc"
    --no-update-notifier)
  if npm install "${npm_options[@]}" --no-fund --no-audit --omit=dev --save-exact "${wanted[@]}" \
    && npm audit signatures "${npm_options[@]}"; then
    printf '%s\n' "$listed" >"$AGENTS/.installed"
    say "The coding agents are installed."
  else
    rm -rf "$AGENTS"
    say "The coding agents could not be installed or checked (see npm's lines above)." \
      "HulbuFactory starts without them and tries again at the next start."
  fi
}

main() {
  local platform release accepted=""
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
  install_agents "$release"
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
