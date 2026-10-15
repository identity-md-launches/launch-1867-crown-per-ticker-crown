import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useConnection } from 'wagmi';
import { createPublicClient, custom, fallback, getAddress, http, type Address, type EIP1193Provider } from 'viem';
import { contract, tickerHash, ZERO, type Runtime } from './config';
import type { King, Totals, Challenge } from './domain';

export function useCrown(runtime: Runtime, symbol: string, lookup?: bigint) {
  const connection = useConnection();
  const hook = contract(runtime, 'CrownHook');
  const provider = useQuery({ queryKey: ['provider', connection.connector?.uid],
    queryFn: async () => await connection.connector!.getProvider() as EIP1193Provider, enabled: Boolean(connection.connector), staleTime: Infinity });
  const client = useMemo(() => createPublicClient({ chain: runtime.chain, batch: { multicall: false },
    transport: fallback([...runtime.rpcUrls.map(url => http(url, { timeout: 10_000, retryCount: 0 })),
      ...(provider.data && connection.chainId === runtime.chain.id ? [custom(provider.data, { retryCount: 0 })] : [])]),
  }), [runtime, provider.data, connection.chainId]);

  const binding = useQuery({ queryKey: ['binding', hook, runtime.chain.id], enabled: Boolean(hook), staleTime: 30_000,
    queryFn: async () => {
      if (await client.getChainId() !== runtime.chain.id) throw new Error('RPC chain does not match the deployment.');
      if (!await client.getBytecode({ address: hook! })) throw new Error('CrownHook has no deployed code. Check the deployment configuration.');
      const [registry, manager, owner] = await Promise.all(['registry', 'poolManager', 'owner'].map(functionName => client.readContract({ address: hook!, abi: runtime.abis.CrownHook, functionName }))) as [Address, Address, Address];
      for (const address of [registry, manager]) {
        if (address === ZERO || !await client.getBytecode({ address })) throw new Error('A required contract has no deployed code.');
      }
      const declaredRegistry = contract(runtime, 'CrownRegistry');
      if (declaredRegistry && declaredRegistry.toLowerCase() !== registry.toLowerCase()) throw new Error('Registry does not match the deployment.');
      const networkManager = (runtime.network?.uniswapV4 as { poolManager?: string } | undefined)?.poolManager;
      if (networkManager && networkManager.toLowerCase() !== manager.toLowerCase()) throw new Error('PoolManager does not match the vetted network.');
      return { hook: hook!, registry: getAddress(registry), manager: getAddress(manager), owner: getAddress(owner) };
    },
  });
  const snapshot = useQuery({
    queryKey: ['snapshot', hook, symbol, lookup?.toString(), connection.address], enabled: Boolean(binding.data),
    refetchInterval: 5_000, refetchIntervalInBackground: false,
    queryFn: async () => {
      const bound = binding.data!;
      const block = await client.getBlock();
      const ticker = tickerHash(symbol);
      const read = (functionName: string, args: readonly unknown[] = []) => client.readContract({ address: bound.registry, abi: runtime.abis.CrownRegistry, functionName, args, blockNumber: block.number });
      const [king, challengeableAt, totals, paid, treasuryOwed, count] = await Promise.all([
        read('king', [ticker]), read('challengeableAt', [ticker]), read('tickerTotals', [ticker]),
        client.readContract({ address: bound.hook, abi: runtime.abis.CrownHook, functionName: 'crownPaid', args: [ticker, ZERO], blockNumber: block.number }),
        read('treasuryOwed'), read('challengeCount'),
      ]) as [King, bigint, Totals, bigint, bigint, bigint];
      const selectedId = lookup ?? totals[0];
      const active = totals[0] > 0n ? await read('challenges', [totals[0]]) as Challenge : undefined;
      const selected = selectedId === totals[0] ? active : selectedId > 0n ? await read('challenges', [selectedId]) as Challenge : undefined;
      let ownKing = 0n, ownChallenger = 0n, claimable = 0n, feeClaims = 0n, operator = false, balance = 0n;
      if (connection.address) {
        const who = connection.address;
        [feeClaims, operator, balance] = await Promise.all([
          client.readContract({ address: bound.manager, abi: runtime.abis.PoolManager, functionName: 'balanceOf', args: [who, 0n], blockNumber: block.number }) as Promise<bigint>,
          client.readContract({ address: bound.manager, abi: runtime.abis.PoolManager, functionName: 'isOperator', args: [who, bound.hook], blockNumber: block.number }) as Promise<boolean>,
          client.getBalance({ address: who, blockNumber: block.number }),
        ]);
        if (selected && selected[0] === ticker && Number(selected[3])) {
          [ownKing, ownChallenger, claimable] = await Promise.all([
            read('stakeOf', [selectedId, who, 0]), read('stakeOf', [selectedId, who, 1]), read('claimable', [selectedId, who]),
          ]) as [bigint, bigint, bigint];
        }
      }
      return { king, challengeableAt, totals, paid, active, selected, selectedId, treasuryOwed, count, ownKing, ownChallenger, claimable, feeClaims, operator, balance,
        block: block.number, time: Number(block.timestamp), observedAt: Date.now() };
    },
  });
  return { connection, client, binding, snapshot, configured: Boolean(hook), provider: provider.data };
}
export type CrownState = ReturnType<typeof useCrown>;
