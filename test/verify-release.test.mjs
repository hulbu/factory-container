// Tests of the release check: `node --test test/`. A test key signs fake release lists the way the release does
// (minisign, prehashed); one real signed list, published on releases.hulbu.com, is checked against the pinned key.

import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  EXIT,
  Refusal,
  acceptManifest,
  agentVersions,
  downloadInto,
  fetchLimited,
  folderMatches,
  isReleaseUrl,
  loadKeys,
  parsePublicKey,
  sha256,
  verifySignature,
} from '../entrypoint/verify-release.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

/** A minisign key pair for tests: the `.pub` text and a signer. */
function testKey() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const id = randomBytes(8);
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const pub = `untrusted comment: test key\n${Buffer.concat([Buffer.from('Ed'), id, raw]).toString('base64')}\n`;
  const signText = (bytes, { algorithm = 'ED', trusted = 'file:manifest.json', forgeTrusted = null } = {}) => {
    const message = algorithm === 'ED' ? createHash('blake2b512').update(bytes).digest() : bytes;
    const signature = sign(null, message, privateKey);
    const global = sign(null, Buffer.concat([signature, Buffer.from(trusted)]), privateKey);
    const line = Buffer.concat([Buffer.from(algorithm), id, signature]).toString('base64');
    return `untrusted comment: signature\n${line}\ntrusted comment: ${forgeTrusted ?? trusted}\n${global.toString('base64')}\n`;
  };
  return { pub, key: parsePublicKey(pub), signText };
}

const signer = testKey();
const keys = [signer.key];

const program = Buffer.from('#!/bin/sh\necho hulbu\n');
const driver = Buffer.from('#!/bin/sh\necho driver\n');

function manifest(overrides = {}, platform = {}) {
  return {
    version: '0.2.0',
    protocol: '1.1',
    channel: 'stable',
    published_at: 1,
    claude_version: '2.1.319',
    tested_programs: { codex: '0.170.0' },
    artifacts: {
      'linux-arm64': {
        station: { url: 'https://releases.hulbu.com/hulbufactory/cli/linux/arm64/hulbu', size: program.length, sha256: sha256(program) },
        sidecar: {
          url: 'https://releases.hulbu.com/hulbufactory/cli/linux/arm64/station-driver-claude',
          size: driver.length,
          sha256: sha256(driver),
        },
        ...platform,
      },
    },
    ...overrides,
  };
}

const signed = (value) => {
  const bytes = Buffer.from(JSON.stringify(value));
  return { bytes, signature: signer.signText(bytes) };
};

function refusedWith(code, run) {
  assert.throws(run, (error) => error instanceof Refusal && error.code === code);
}

test('a correctly signed release list for this platform is accepted', () => {
  const { bytes, signature } = signed(manifest());
  const release = acceptManifest(bytes, signature, keys, 'linux-arm64', null);
  assert.equal(release.version, '0.2.0');
  assert.equal(release.protocol, '1.1');
  assert.equal(release.program.sha256, sha256(program));
  assert.equal(release.claude_version, '2.1.319');
});

test('one changed byte in the release list is refused', () => {
  const { bytes, signature } = signed(manifest());
  bytes[bytes.length - 2] ^= 1;
  refusedWith(EXIT.mismatch, () => acceptManifest(bytes, signature, keys, 'linux-arm64', null));
});

test('a legacy (not prehashed) signature is refused', () => {
  const bytes = Buffer.from(JSON.stringify(manifest()));
  refusedWith(EXIT.mismatch, () => verifySignature(bytes, signer.signText(bytes, { algorithm: 'Ed' }), keys));
});

test('a signature by a key that is not pinned is refused', () => {
  const other = testKey();
  const bytes = Buffer.from(JSON.stringify(manifest()));
  refusedWith(EXIT.mismatch, () => verifySignature(bytes, other.signText(bytes), keys));
});

test('a changed trusted comment is refused', () => {
  const bytes = Buffer.from(JSON.stringify(manifest()));
  refusedWith(EXIT.mismatch, () => verifySignature(bytes, signer.signText(bytes, { forgeTrusted: 'file:other.json' }), keys));
});

test('no pinned key trusts nothing', () => {
  const { bytes, signature } = signed(manifest());
  refusedWith(EXIT.mismatch, () => verifySignature(bytes, signature, []));
});

for (const [name, overrides] of [
  ['another channel', { channel: 'test' }],
  ['a pre-release', { version: '0.2.0-preview' }],
  ['build metadata', { version: '0.2.0+abc1234' }],
  ['no version', { version: 7 }],
  ['no protocol', { protocol: undefined }],
]) {
  test(`a release list with ${name} is refused`, () => {
    const { bytes, signature } = signed(manifest(overrides));
    refusedWith(EXIT.mismatch, () => acceptManifest(bytes, signature, keys, 'linux-arm64', null));
  });
}

test('a version older than one this machine already had is refused; the same one is not', () => {
  const { bytes, signature } = signed(manifest());
  refusedWith(EXIT.mismatch, () => acceptManifest(bytes, signature, keys, 'linux-arm64', '0.10.0'));
  assert.equal(acceptManifest(bytes, signature, keys, 'linux-arm64', '0.2.0').version, '0.2.0');
});

test('a release list with nothing for this platform says so', () => {
  const { bytes, signature } = signed(manifest());
  refusedWith(EXIT.noPlatform, () => acceptManifest(bytes, signature, keys, 'linux-x64', null));
});

for (const [name, changed] of [
  ['another host', { url: 'https://releases.hulbu.com.example.org/hulbu' }],
  ['plain HTTP', { url: 'http://releases.hulbu.com/hulbu' }],
  ['a user part', { url: 'https://releases.hulbu.com/@evil/hulbu' }],
  ['a parent folder', { url: 'https://releases.hulbu.com/a/../hulbu' }],
  ['size 0', { size: 0 }],
  ['over 1 GiB', { size: 1024 * 1024 * 1024 + 1 }],
  ['no SHA-256', { sha256: 'abc' }],
  ['an upper-case SHA-256', { sha256: sha256(program).toUpperCase() }],
]) {
  test(`a file with ${name} is refused`, () => {
    const base = manifest().artifacts['linux-arm64'].station;
    const { bytes, signature } = signed(manifest({}, { station: { ...base, ...changed } }));
    refusedWith(EXIT.mismatch, () => acceptManifest(bytes, signature, keys, 'linux-arm64', null));
  });
}

test('only addresses on https://releases.hulbu.com pass', () => {
  assert.ok(isReleaseUrl('https://releases.hulbu.com/hulbufactory/cli/manifest.json'));
  assert.ok(!isReleaseUrl('https://releases.hulbu.com'));
  assert.ok(!isReleaseUrl('https://releases.hulbu.com:444/x'));
  assert.ok(!isReleaseUrl('https://releases.hulbu.com/x?y'));
});

test('the pinned release keys are the two of the monorepo', () => {
  const ids = loadKeys(join(root, 'keys')).map((key) => Buffer.from(key.id).reverse().toString('hex').toUpperCase());
  assert.deepEqual(ids.sort(), ['8F9BF929B7E0A5F5', 'D475C9BD9742B5CF']);
});

test('a release list really published on releases.hulbu.com passes with the pinned key, and fails changed', () => {
  const bytes = readFileSync(join(here, 'fixtures/published-manifest.json'));
  const signature = readFileSync(join(here, 'fixtures/published-manifest.json.minisig'), 'utf8');
  const pinned = loadKeys(join(root, 'keys'));
  verifySignature(bytes, signature, pinned);
  const changed = Buffer.from(bytes);
  changed[10] ^= 1;
  refusedWith(EXIT.mismatch, () => verifySignature(changed, signature, pinned));
});

// ── Fetching and downloading, with a fake network ──────────────────────────────────────────────────────────────

const respond = (body, init = {}) => async () => new Response(body, init);

test('a redirect is refused', async () => {
  const fetchImplementation = respond(null, { status: 302, headers: { location: 'https://elsewhere.example/' } });
  await assert.rejects(fetchLimited('https://releases.hulbu.com/x', 10, { fetchImplementation }), (error) => error.code === EXIT.mismatch);
});

test('a body larger than its limit is refused, with or without a length header', async () => {
  await assert.rejects(fetchLimited('https://releases.hulbu.com/x', 3, { fetchImplementation: respond('12345') }), (error) => error.code === EXIT.mismatch);
  const stream = () => new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('12345')); controller.close(); } });
  await assert.rejects(
    fetchLimited('https://releases.hulbu.com/x', 3, { fetchImplementation: async () => new Response(stream()) }),
    (error) => error.code === EXIT.mismatch,
  );
});

test('no network is its own case; a missing file is null', async () => {
  const offline = async () => {
    throw new TypeError('fetch failed', { cause: { code: 'ENOTFOUND' } });
  };
  await assert.rejects(fetchLimited('https://releases.hulbu.com/x', 10, { fetchImplementation: offline }), (error) => error.code === EXIT.network);
  assert.equal(await fetchLimited('https://releases.hulbu.com/x', 10, { fetchImplementation: respond('', { status: 404 }) }), null);
});

function fakeNetwork(files) {
  return async (url) => (url in files ? new Response(files[url]) : new Response('', { status: 404 }));
}

test('the download writes both files, executable, and the folder then matches the release', async () => {
  const { bytes, signature } = signed(manifest());
  const release = acceptManifest(bytes, signature, keys, 'linux-arm64', null);
  const folder = join(mkdtempSync(join(tmpdir(), 'factory-')), '0.2.0.partial');
  const fetchImplementation = fakeNetwork({ [release.program.url]: program, [release.driver.url]: driver });
  await downloadInto(release, folder, { fetchImplementation });
  assert.ok(folderMatches(release, folder));
  assert.equal(readFileSync(join(folder, 'hulbu')).toString(), program.toString());
});

test('a downloaded file that differs from the signed list is refused', async () => {
  const { bytes, signature } = signed(manifest());
  const release = acceptManifest(bytes, signature, keys, 'linux-arm64', null);
  const folder = join(mkdtempSync(join(tmpdir(), 'factory-')), 'partial');
  const changed = Buffer.from(program);
  changed[0] ^= 1;
  const fetchImplementation = fakeNetwork({ [release.program.url]: changed, [release.driver.url]: driver });
  await assert.rejects(downloadInto(release, folder, { fetchImplementation }), (error) => error.code === EXIT.mismatch);
});

test('an installed folder with a changed file or a link does not match', () => {
  const { bytes, signature } = signed(manifest());
  const release = acceptManifest(bytes, signature, keys, 'linux-arm64', null);
  const folder = mkdtempSync(join(tmpdir(), 'factory-'));
  writeFileSync(join(folder, 'hulbu'), program);
  writeFileSync(join(folder, 'station-driver-claude'), driver);
  assert.ok(folderMatches(release, folder));
  writeFileSync(join(folder, 'hulbu'), Buffer.concat([program, Buffer.from(' ')]));
  assert.ok(!folderMatches(release, folder));
  const linked = mkdtempSync(join(tmpdir(), 'factory-'));
  symlinkSync(join(folder, 'station-driver-claude'), join(linked, 'station-driver-claude'));
  writeFileSync(join(linked, 'hulbu'), program);
  assert.ok(!folderMatches(release, linked));
});

// ── The coding agents ──────────────────────────────────────────────────────────────────────────────────────────

const defaults = JSON.parse(readFileSync(join(root, 'entrypoint/agents.json'), 'utf8'));

test('normally each agent is installed at its latest release and keeps its own update path', () => {
  assert.deepEqual(agentVersions(null, defaults, false), [
    'claude @anthropic-ai/claude-code@latest',
    'codex @openai/codex@latest',
    'pi @mariozechner/pi-coding-agent@latest',
  ]);
});

test('pinned: Claude Code follows the release, Codex its tested version, pi the image default', () => {
  const { bytes, signature } = signed(manifest());
  const release = acceptManifest(bytes, signature, keys, 'linux-arm64', null);
  assert.deepEqual(agentVersions(release, defaults, true), [
    'claude @anthropic-ai/claude-code@2.1.319',
    'codex @openai/codex@0.170.0',
    `pi @mariozechner/pi-coding-agent@${defaults.agents[2].version}`,
  ]);
});

test('pinned without a release (practice): the image defaults, exact', () => {
  const lines = agentVersions(null, defaults, true);
  assert.equal(lines.length, 3);
  for (const line of lines) assert.match(line, /@\d+\.\d+\.\d+$/);
});

test('pinned never installs a range', () => {
  assert.throws(() => agentVersions(null, { agents: [{ program: 'pi', package: 'p', version: '^1.0.0' }] }, true), Refusal);
});
