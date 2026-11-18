// Publishes a fake release for the entrypoint's tests, signed like the real one (minisign, prehashed) by a test
// key kept in --keys (made on first use): manifest.json, its .minisig and the two files under --out.
//   node make-release.mjs --out DIR --origin URL --keys DIR --version V --protocol P --platform P --program F --driver F
import { createHash, createPrivateKey, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const options = {};
const argv = process.argv.slice(2);
for (let index = 0; index < argv.length; index += 2) options[argv[index].slice(2)] = argv[index + 1];

const secretFile = join(options.keys, 'test.key.pem');
if (!existsSync(secretFile)) {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const id = randomBytes(8);
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  writeFileSync(join(options.keys, 'test.pub'), `untrusted comment: test key\n${Buffer.concat([Buffer.from('Ed'), id, raw]).toString('base64')}\n`);
  writeFileSync(secretFile, privateKey.export({ format: 'pem', type: 'pkcs8' }));
  writeFileSync(join(options.keys, 'test.id'), id.toString('hex'));
}
const privateKey = createPrivateKey(readFileSync(secretFile));
const id = Buffer.from(readFileSync(join(options.keys, 'test.id'), 'utf8'), 'hex');

const folder = options.platform === 'linux-x64' ? 'linux' : 'linux/arm64';
const cli = join(options.out, 'hulbufactory/cli');
mkdirSync(join(cli, folder), { recursive: true });
const file = (name, source) => {
  const bytes = readFileSync(source);
  writeFileSync(join(cli, folder, name), bytes);
  return { url: `${options.origin}/hulbufactory/cli/${folder}/${name}`, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
};
const manifest = Buffer.from(
  JSON.stringify({
    version: options.version,
    protocol: options.protocol,
    channel: 'stable',
    published_at: 1,
    claude_version: '2.1.319',
    artifacts: { [options.platform]: { station: file('hulbu', options.program), sidecar: file('station-driver-claude', options.driver) } },
  }),
);
const signature = sign(null, createHash('blake2b512').update(manifest).digest(), privateKey);
const trusted = 'file:manifest.json';
const global = sign(null, Buffer.concat([signature, Buffer.from(trusted)]), privateKey);
writeFileSync(join(cli, 'manifest.json'), manifest);
writeFileSync(
  join(cli, 'manifest.json.minisig'),
  `untrusted comment: test\n${Buffer.concat([Buffer.from('ED'), id, signature]).toString('base64')}\ntrusted comment: ${trusted}\n${global.toString('base64')}\n`,
);
