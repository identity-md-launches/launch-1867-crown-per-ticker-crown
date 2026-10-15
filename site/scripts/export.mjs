import { createHash } from 'node:crypto';
import { readFile, writeFile, readdir, stat, copyFile, mkdir } from 'node:fs/promises';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak256, toBytes, isAddress } from 'viem';

const root = process.argv[2] ? resolve(process.argv[2]) : resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(root, 'dist');
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)])) : value;
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const exists = async path => stat(path).then(() => true, () => false);
const safe = path => typeof path === 'string' && /^[a-zA-Z0-9_./-]+$/.test(path) && !path.startsWith('/') && !path.split('/').includes('..');
const inventory = async dir => {
  const entries = await readdir(dir, { withFileTypes: true });
  return (await Promise.all(entries.map(async entry => entry.isDirectory() ? inventory(resolve(dir, entry.name)) : resolve(dir, entry.name)))).flat();
};
const handoffPath = resolve(root, '.imd/reads/deployment.json');
const networkPath = resolve(root, '.imd/reads/network.json');
const config = await json(resolve(dist, 'crown-config.json'));
if (await exists(handoffPath)) {
  const handoff = await json(handoffPath);
  for (const key of ['launchId', 'chainId', 'sourceCommit', 'attestationHash', 'contracts']) if (handoff[key] === undefined) throw new Error(`Handoff is missing ${key}`);
  if (!Array.isArray(handoff.contracts) || !handoff.contracts.length) throw new Error('Handoff contract set is empty');
  const contracts = [];
  for (const item of handoff.contracts) {
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(item.name) || !isAddress(item.address) || /^0x0{40}$/i.test(item.address)) throw new Error('Invalid handoff contract');
    if (!/^[0-9a-f]{64}$/.test(item.abiHash)) throw new Error(`Invalid ${item.name} ABI hash`);
    const abiPath = `abi/${item.name}.json`;
    const pinned = item.abiPath && safe(item.abiPath) ? resolve(root, '.imd/reads', item.abiPath) : undefined;
    if (pinned && await exists(pinned)) await copyFile(pinned, resolve(dist, abiPath));
    const abi = await json(resolve(dist, abiPath));
    if (!Array.isArray(abi) || keccak256(toBytes(JSON.stringify(canonical(abi)))).slice(2) !== item.abiHash) throw new Error(`ABI hash does not match ${item.name}`);
    contracts.push({ name: item.name, address: item.address, abiHash: item.abiHash, abiPath });
  }
  const manifest = { version: 1, launchId: handoff.launchId, chainId: handoff.chainId, sourceCommit: handoff.sourceCommit,
    attestationHash: handoff.attestationHash, contracts, assets: [] };
  if (handoff.poolKey) manifest.poolKey = handoff.poolKey;
  if (await exists(networkPath)) {
    const networkFile = await json(networkPath);
    manifest.network = networkFile.network;
    if (networkFile.walletAddChain) manifest.walletAddChain = networkFile.walletAddChain;
  }
  // This file only selects the handoff and supplies implementation-derived ABIs for contracts
  // created by the hook. Addresses, chain and public networking come from the handoff at runtime.
  config.deploymentPath = 'imd-deployment.json';
  config.contracts = [];
  await writeFile(resolve(dist, 'crown-config.json'), JSON.stringify(config, null, 2) + '\n');
  const files = (await inventory(dist)).filter(path => !path.endsWith('/imd-deployment.json')).sort();
  if (files.length > 128) throw new Error('Too many exported assets');
  manifest.assets = await Promise.all(files.map(async path => ({ path: relative(dist, path), sha256: createHash('sha256').update(await readFile(path)).digest('hex') })));
  await writeFile(resolve(dist, 'imd-deployment.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Exported handoff with ${contracts.length} contracts and ${files.length} hashed assets.`);
} else {
  console.log('No deployment handoff supplied. Export keeps contract addresses unset.');
}
const files = await inventory(dist);
const size = (await Promise.all(files.map(async file => (await stat(file)).size))).reduce((a, b) => a + b, 0);
if (size > 4 * 1024 * 1024) throw new Error(`Export is too large: ${size} bytes; reserve space for the source bundle.`);
console.log(`Static export: ${files.length} files, ${size} bytes.`);
