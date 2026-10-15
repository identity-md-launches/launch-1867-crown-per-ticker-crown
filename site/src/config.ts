import { createConfig, http, fallback } from 'wagmi';
import { coinbaseWallet, injected } from 'wagmi/connectors';
import { defineChain, getAddress, isAddress, keccak256, toBytes, type Abi, type Address, type Chain } from 'viem';

export type ContractEntry = { name: string; address: Address; abiPath?: string; abiHash?: string };
export type Runtime = {
  chain: Chain; rpcUrls: string[]; explorer: string; contracts: ContractEntry[];
  abis: Record<string, Abi>; walletAddChain: Record<string, unknown>; handoff: boolean;
  poolKey?: { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
  network?: Record<string, unknown>;
};

export const ZERO = '0x0000000000000000000000000000000000000000' as Address;
export const DEFAULT_TICKER = 'CRWN';
export const RULES = { bond: 10n ** 16n, quorum: 5n * 10n ** 16n, minReign: 7 * 86400, window: 72 * 3600, timelock: 86400, poolFee: 12500, tickSpacing: 60 };
export const tickerHash = (symbol: string) => keccak256(toBytes(symbol.trim().toUpperCase()));
export const contract = (runtime: Runtime, name: string) => runtime.contracts.find(c => c.name === name)?.address;
export const canonical = (value: unknown): unknown => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)])) : value;

function localPath(path: unknown): string {
  if (typeof path !== 'string' || !/^[a-zA-Z0-9_./-]+$/.test(path) || path.startsWith('/') || path.split('/').includes('..')) throw new Error('Invalid local configuration path.');
  return path;
}
async function readJson(path: string) {
  const response = await fetch(new URL(localPath(path), document.baseURI), { cache: 'no-cache' });
  if (!response.ok) throw new Error('Deployment configuration could not be loaded. Reload to retry.');
  return response.json();
}
function publicUrl(input: unknown): string {
  if (typeof input !== 'string') throw new Error('Missing public network URL.');
  const url = new URL(input);
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Network URLs must use public HTTPS.');
  return url.href.replace(/\/$/, '');
}

export async function loadRuntime(): Promise<Runtime> {
  const bootstrap = await readJson('crown-config.json');
  const handoff = Boolean(bootstrap.deploymentPath);
  const config = handoff ? await readJson(bootstrap.deploymentPath) : bootstrap;
  const network = config.network;
  const chainId = Number(config.chainId);
  if (!Number.isSafeInteger(chainId) || chainId <= 0) throw new Error('Invalid deployment chain.');
  const rpcUrls = (network?.rpcUrls ?? bootstrap.rpcUrls).map(publicUrl) as string[];
  if (!rpcUrls.length) throw new Error('No public RPC is configured.');
  const explorer = publicUrl(network?.explorerUrl ?? network?.explorer ?? bootstrap.explorerUrl);
  const nativeCurrency = network?.nativeCurrency ?? bootstrap.nativeCurrency;
  const chain = defineChain({ id: chainId, name: network?.name ?? bootstrap.chainName, nativeCurrency,
    rpcUrls: { default: { http: rpcUrls } }, blockExplorers: { default: { name: 'Explorer', url: explorer } }, testnet: Boolean(network?.testnet) });
  const contracts: ContractEntry[] = config.contracts ?? [];
  const names = new Set<string>();
  for (const entry of contracts) {
    if (names.has(entry.name) || !isAddress(entry.address) || entry.address.toLowerCase() === ZERO) throw new Error('Invalid or duplicate deployment contract.');
    entry.address = getAddress(entry.address); names.add(entry.name);
  }
  if (contracts.length && !contracts.some(c => c.name === 'CrownHook')) throw new Error('The deployment does not contain CrownHook.');
  const paths: Record<string, string> = { ...bootstrap.abis };
  for (const entry of contracts) if (entry.abiPath) paths[entry.name] = entry.abiPath;
  const abis: Record<string, Abi> = {};
  await Promise.all(Object.entries(paths).map(async ([name, path]) => {
    const abi = await readJson(path);
    if (!Array.isArray(abi)) throw new Error(`Invalid ${name} ABI.`);
    const entry = contracts.find(c => c.name === name);
    if (entry?.abiHash && keccak256(toBytes(JSON.stringify(canonical(abi)))).slice(2) !== entry.abiHash) throw new Error(`${name} ABI verification failed.`);
    abis[name] = abi;
  }));
  const walletAddChain = config.walletAddChain ?? { chainId: `0x${chainId.toString(16)}`, chainName: chain.name,
    nativeCurrency, rpcUrls, blockExplorerUrls: [explorer] };
  if (Number(walletAddChain.chainId) !== chainId) throw new Error('Wallet network does not match the deployment.');
  return { chain, rpcUrls, explorer, contracts, abis, walletAddChain, handoff, network, poolKey: config.poolKey };
}

export function walletConfig(runtime: Runtime) {
  return createConfig({ chains: [runtime.chain], multiInjectedProviderDiscovery: true,
    connectors: [injected(), coinbaseWallet({ appName: 'Crown', appLogoUrl: new URL('favicon.svg', document.baseURI).href })],
    transports: { [runtime.chain.id]: fallback(runtime.rpcUrls.map(url => http(url, { timeout: 10_000, retryCount: 1 }))) },
  });
}
