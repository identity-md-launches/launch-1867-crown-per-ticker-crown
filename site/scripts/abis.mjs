import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = resolve(root, 'site/public/abi');
await mkdir(output, { recursive: true });
for (const name of ['CrownHook', 'CrownRegistry', 'CrownToken', 'CrownChallengerToken', 'PoolManager']) {
  const artifact = JSON.parse(await readFile(resolve(root, `out/${name}.sol/${name}.json`), 'utf8'));
  if (!Array.isArray(artifact.abi)) throw new Error(`Missing ${name} ABI; run forge build first.`);
  await writeFile(resolve(output, `${name}.json`), JSON.stringify(artifact.abi) + '\n');
}
console.log('Exported five implementation-derived ABI arrays.');
