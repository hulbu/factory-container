// The release check of the HulbuFactory container. It does what `hulbu update` does before it trusts a release:
//
//   1. fetch manifest.json and manifest.json.minisig from https://releases.hulbu.com (HTTPS only, no redirects,
//      size limits);
//   2. check the minisign signature over the exact bytes BEFORE reading them: prehashed (ED) signatures only, made
//      by one of the release keys pinned in this image, the global signature over the trusted comment too;
//   3. check the manifest: channel "stable", a plain version (no pre-release, no build metadata) not lower than the
//      highest one this volume has accepted (hulbu never goes back either), a protocol, an entry for this machine's
//      platform, both files on https://releases.hulbu.com with a size and a SHA-256;
//   4. download each file with its size as the limit and check its size and SHA-256.
//
// Only Node's own modules are used (Node is in the image to run the coding agents), so the image needs no curl,
// jq or minisign. Messages go to stderr as one sentence a person can act on; results go to files or stdout.
//
// Commands (exit 0 on success):
//   check-manifest --keys DIR --platform P --highest FILE --out FILE
//   matches        --release FILE | --release-json TEXT --folder DIR   (exit 1: not exactly these files)
//   download       --release FILE --into DIR
//   agent-versions --release FILE|none --defaults FILE
//
// Exit codes: 10 the network or the host did not answer; 11 something does not match (refuse, try again later);
// 12 the release has nothing for this platform; 2 wrong use.

import { createHash, createPublicKey, verify } from 'node:crypto';
import {
  chmodSync,
  closeSync,
  constants,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
  writeSync,
} from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const RELEASES_ORIGIN = 'https://releases.hulbu.com';
export const MANIFEST_URL = `${RELEASES_ORIGIN}/hulbufactory/cli/manifest.json`;
export const MAXIMUM_MANIFEST_BYTES = 1024 * 1024;
export const MAXIMUM_SIGNATURE_BYTES = 4096;
export const MAXIMUM_FILE_BYTES = 1024 * 1024 * 1024;
export const PROGRAM_FILE = 'hulbu';
export const DRIVER_FILE = 'station-driver-claude';
export const PLATFORMS = ['linux-x64', 'linux-arm64'];

export const EXIT = { network: 10, mismatch: 11, noPlatform: 12, usage: 2 };

/** A failure with the exit code it maps to and a sentence for the person. */
export class Refusal extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const mismatch = (message) => new Refusal(EXIT.mismatch, message);

// ── Keys and signatures, as HulbuFactory's own update checks them ──────────────────────────────────────────

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

/** A minisign public key from a `.pub` file's text: `{ id, key }`, or null when the file holds no key. */
export function parsePublicKey(text) {
  const line = text
    .split('\n')
    .map((part) => part.trim())
    .find((part) => part !== '' && !part.startsWith('#') && !part.startsWith('untrusted comment:'));
  if (line === undefined) return null;
  const bytes = Buffer.from(line, 'base64');
  if (bytes.length !== 42 || bytes.subarray(0, 2).toString('latin1') !== 'Ed') return null;
  return {
    id: bytes.subarray(2, 10),
    key: createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, bytes.subarray(10)]), format: 'der', type: 'spki' }),
  };
}

/** The pinned keys: every `*.pub` file in `folder` that holds a key. */
export function loadKeys(folder) {
  return readdirSync(folder)
    .filter((name) => name.endsWith('.pub'))
    .sort()
    .map((name) => parsePublicKey(readFileSync(join(folder, name), 'utf8')))
    .filter((key) => key !== null);
}

/** Checks a `.minisig` text over exactly `bytes` with one of `keys`; throws a Refusal otherwise. */
export function verifySignature(bytes, signatureText, keys) {
  if (keys.length === 0) throw mismatch('No release key is pinned in this image.');
  const lines = signatureText.split('\n').map((line) => line.replace(/\r$/, ''));
  if (lines.length < 4 || !lines[0].startsWith('untrusted comment:') || !lines[2].startsWith('trusted comment: ')) {
    throw mismatch('The signature of the release list cannot be read.');
  }
  const signature = Buffer.from(lines[1], 'base64');
  const global = Buffer.from(lines[3], 'base64');
  if (signature.length !== 74 || global.length !== 64) {
    throw mismatch('The signature of the release list cannot be read.');
  }
  const algorithm = signature.subarray(0, 2).toString('latin1');
  if (algorithm === 'Ed') throw mismatch('The release list has a legacy (not prehashed) signature, which is refused.');
  if (algorithm !== 'ED') throw mismatch('The signature of the release list cannot be read.');
  const key = keys.find((candidate) => candidate.id.equals(signature.subarray(2, 10)));
  if (key === undefined) throw mismatch('The release list was signed with a key this image does not know.');
  const digest = createHash('blake2b512').update(bytes).digest();
  if (!verify(null, digest, key.key, signature.subarray(10))) {
    throw mismatch('The signature of the release list does not match its content.');
  }
  const trusted = Buffer.from(lines[2].slice('trusted comment: '.length), 'utf8');
  if (!verify(null, Buffer.concat([signature.subarray(10), trusted]), key.key, global)) {
    throw mismatch('The trusted comment of the release list does not match its signature.');
  }
}

// ── The release list (manifest.json), as HulbuFactory's own update reads it ────────────────────────────────────────

const PLAIN_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/;

/** -1, 0 or 1 for two plain versions (`major.minor.patch`). */
export function compareVersions(left, right) {
  const a = left.split('.').map(BigInt);
  const b = right.split('.').map(BigInt);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  }
  return 0;
}

/** `https://releases.hulbu.com/…` exactly: no other host, port, user part or scheme; no `@ \ # ?` or `..`. */
export function isReleaseUrl(url) {
  if (typeof url !== 'string' || !url.startsWith(`${RELEASES_ORIGIN}/`)) return false;
  const path = url.slice(RELEASES_ORIGIN.length + 1);
  return path !== '' && !/[@\\#?]/.test(path) && !path.includes('..');
}

function checkFile(name, file) {
  if (file === null || typeof file !== 'object') throw mismatch(`The release list has no ${name} file.`);
  if (!isReleaseUrl(file.url)) throw mismatch(`The release list names ${name} at an address that is not on ${RELEASES_ORIGIN}.`);
  if (!Number.isSafeInteger(file.size) || file.size <= 0 || file.size > MAXIMUM_FILE_BYTES) {
    throw mismatch(`The release list gives ${name} an impossible size.`);
  }
  if (typeof file.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(file.sha256)) {
    throw mismatch(`The release list has no SHA-256 for ${name}.`);
  }
  return { url: file.url, size: file.size, sha256: file.sha256 };
}

/**
 * Verifies, then reads and checks, one manifest. `highest`: the highest version this volume accepted before (or
 * null). Returns what the rest of the start needs.
 */
export function acceptManifest(bytes, signatureText, keys, platform, highest) {
  verifySignature(bytes, signatureText, keys);
  let manifest;
  try {
    manifest = JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch {
    throw mismatch('The signed release list cannot be read.');
  }
  if (manifest === null || typeof manifest !== 'object') throw mismatch('The signed release list cannot be read.');
  if (manifest.channel !== 'stable') throw mismatch(`The release list is for the channel "${manifest.channel}", not "stable".`);
  const version = manifest.version;
  if (typeof version !== 'string' || !SEMVER.test(version)) throw mismatch('The release list has no readable version.');
  if (version.includes('+')) throw mismatch(`The release list's version ${version} carries build metadata.`);
  if (!PLAIN_VERSION.test(version)) throw mismatch(`The release list offers a pre-release (${version}) on the stable channel.`);
  if (highest !== null && compareVersions(version, highest) < 0) {
    throw mismatch(`The release list offers ${version}, older than ${highest}, which this machine already had.`);
  }
  if (typeof manifest.protocol !== 'string' || manifest.protocol === '') throw mismatch('The release list names no protocol.');
  const artifacts = manifest.artifacts?.[platform];
  if (artifacts === undefined || artifacts === null) {
    throw new Refusal(EXIT.noPlatform, `releases.hulbu.com has no HulbuFactory build for ${platform} yet.`);
  }
  const tested = manifest.tested_programs !== null && typeof manifest.tested_programs === 'object' ? manifest.tested_programs : {};
  return {
    version,
    protocol: manifest.protocol,
    platform,
    claude_version: typeof manifest.claude_version === 'string' ? manifest.claude_version : null,
    tested_programs: Object.fromEntries(Object.entries(tested).filter(([, value]) => typeof value === 'string')),
    // The release list's own names for the two files: `station` is the program, `sidecar` the Claude driver.
    program: checkFile(PROGRAM_FILE, artifacts.station),
    driver: checkFile(DRIVER_FILE, artifacts.sidecar),
  };
}

// ── Fetching, as HulbuFactory's own update fetches ──────────────────────────────────────────────────────────────

/** GET `url` (on the releases origin only, no redirects), refusing a body longer than `limit`. */
export async function fetchLimited(url, limit, { fetchImplementation = fetch, timeoutMilliseconds = 60_000 } = {}) {
  if (!isReleaseUrl(url)) throw mismatch(`${url} is not on ${RELEASES_ORIGIN}.`);
  let response;
  try {
    response = await fetchImplementation(url, { redirect: 'manual', signal: AbortSignal.timeout(timeoutMilliseconds) });
  } catch (error) {
    throw new Refusal(EXIT.network, `Cannot reach releases.hulbu.com (${error.cause?.code ?? error.name}).`);
  }
  if (response.status === 404) return null;
  if (response.status >= 300 && response.status < 400) throw mismatch(`releases.hulbu.com answered ${url} with a redirect.`);
  if (!response.ok) throw new Refusal(EXIT.network, `releases.hulbu.com answered HTTP ${response.status}.`);
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > limit) throw mismatch(`${url} is larger than ${limit} bytes.`);
  const parts = [];
  let length = 0;
  try {
    for await (const chunk of response.body) {
      length += chunk.length;
      if (length > limit) throw mismatch(`${url} is larger than ${limit} bytes.`);
      parts.push(chunk);
    }
  } catch (error) {
    if (error instanceof Refusal) throw error;
    throw new Refusal(EXIT.network, `The download from releases.hulbu.com broke off (${error.cause?.code ?? error.name}).`);
  }
  return Buffer.concat(parts);
}

export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

/** The SHA-256 of a regular file that is not a link, or null. */
function fileSha256(path) {
  let status;
  try {
    status = lstatSync(path);
  } catch {
    return null;
  }
  if (!status.isFile()) return null;
  const hash = createHash('sha256');
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const chunk = Buffer.alloc(1024 * 1024);
    for (let read = readSync(descriptor, chunk); read > 0; read = readSync(descriptor, chunk)) {
      hash.update(chunk.subarray(0, read));
    }
  } finally {
    closeSync(descriptor);
  }
  return { size: status.size, sha256: hash.digest('hex') };
}

/** True when `folder` holds both files with exactly the release's sizes and SHA-256 values. */
export function folderMatches(release, folder) {
  return [
    [PROGRAM_FILE, release.program],
    [DRIVER_FILE, release.driver],
  ].every(([name, file]) => {
    const found = fileSha256(join(folder, name));
    return found !== null && found.size === file.size && found.sha256 === file.sha256;
  });
}

function writeProgram(path, bytes) {
  const descriptor = openSync(path, 'wx', 0o600);
  try {
    writeSync(descriptor, bytes);
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  chmodSync(path, 0o755);
}

/** Downloads both files into `folder` (made fresh), each checked before it is written. */
export async function downloadInto(release, folder, options = {}) {
  rmSync(folder, { recursive: true, force: true });
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  for (const [name, file] of [
    [PROGRAM_FILE, release.program],
    [DRIVER_FILE, release.driver],
  ]) {
    const bytes = await fetchLimited(file.url, file.size, { timeoutMilliseconds: 30 * 60_000, ...options });
    if (bytes === null) throw mismatch(`${name} is listed in the release list but is not on releases.hulbu.com.`);
    if (bytes.length !== file.size) throw mismatch(`${name} has ${bytes.length} bytes; the signed list says ${file.size}.`);
    if (sha256(bytes) !== file.sha256) throw mismatch(`${name}'s SHA-256 does not match the signed list.`);
    writeProgram(join(folder, name), bytes);
  }
}

// ── The coding agents' versions ─────────────────────────────────────────────────────────────────────────────────

const NPM_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

/**
 * `package@version` lines for npm. Claude Code follows the release's `claude_version` (the claude the driver
 * embeds); the others follow its `tested_programs`; the image's defaults fill the rest. Only exact versions.
 */
export function agentVersions(release, defaults) {
  const lines = [];
  for (const agent of defaults.agents) {
    let version = agent.version;
    if (release !== null) {
      const fromRelease = agent.program === 'claude' ? release.claude_version : release.tested_programs[agent.program];
      if (typeof fromRelease === 'string' && NPM_VERSION.test(fromRelease)) version = fromRelease;
    }
    if (!NPM_VERSION.test(version)) throw new Refusal(EXIT.usage, `The version ${version} of ${agent.package} is not exact.`);
    lines.push(`${agent.package}@${version}`);
  }
  return lines;
}

// ── Command line ────────────────────────────────────────────────────────────────────────────────────────────────

function options(argv) {
  const found = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!name?.startsWith('--') || argv[index + 1] === undefined) throw new Refusal(EXIT.usage, `Wrong use near ${name ?? 'the end'}.`);
    found[name.slice(2)] = argv[index + 1];
  }
  return found;
}

function required(found, name) {
  if (found[name] === undefined) throw new Refusal(EXIT.usage, `--${name} is missing.`);
  return found[name];
}

function readHighest(path) {
  try {
    const text = readFileSync(path, 'utf8').trim();
    return PLAIN_VERSION.test(text) ? text : null;
  } catch {
    return null;
  }
}

async function main(argv) {
  const [command, ...rest] = argv;
  const found = options(rest);
  switch (command) {
    case 'check-manifest': {
      const platform = required(found, 'platform');
      if (!PLATFORMS.includes(platform)) throw new Refusal(EXIT.usage, `${platform} is not a platform HulbuFactory builds for.`);
      const keys = loadKeys(required(found, 'keys'));
      const bytes = await fetchLimited(MANIFEST_URL, MAXIMUM_MANIFEST_BYTES);
      const signature = await fetchLimited(`${MANIFEST_URL}.minisig`, MAXIMUM_SIGNATURE_BYTES);
      if (bytes === null || signature === null) {
        throw new Refusal(EXIT.noPlatform, `releases.hulbu.com has no HulbuFactory build for ${platform} yet.`);
      }
      const release = acceptManifest(bytes, signature.toString('utf8'), keys, platform, readHighest(required(found, 'highest')));
      writeFileSync(required(found, 'out'), `${JSON.stringify(release)}\n`, { mode: 0o600 });
      process.stdout.write(`${release.version}\n`);
      return 0;
    }
    case 'matches': {
      // --release-json: the accepted release itself, kept by the caller, so no file in the volume is trusted here.
      const text = found['release-json'] ?? readFileSync(required(found, 'release'), 'utf8');
      const release = JSON.parse(text);
      return folderMatches(release, required(found, 'folder')) ? 0 : 1;
    }
    case 'download': {
      const release = JSON.parse(readFileSync(required(found, 'release'), 'utf8'));
      await downloadInto(release, required(found, 'into'));
      return 0;
    }
    case 'agent-versions': {
      const source = required(found, 'release');
      const release = source === 'none' ? null : JSON.parse(readFileSync(source, 'utf8'));
      const defaults = JSON.parse(readFileSync(required(found, 'defaults'), 'utf8'));
      process.stdout.write(`${agentVersions(release, defaults).join('\n')}\n`);
      return 0;
    }
    default:
      throw new Refusal(EXIT.usage, `Unknown command ${command ?? '(none)'}.`);
  }
}

/** True when this file is the program Node was started with (paths compared after links are followed). */
function isMain() {
  try {
    return realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      process.stderr.write(`${error instanceof Refusal ? error.message : `Unexpected error: ${error.message}`}\n`);
      process.exit(error instanceof Refusal ? error.code : EXIT.mismatch);
    },
  );
}
