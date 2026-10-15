import { useState } from 'react';
import { RULES, tickerHash, ZERO, type Runtime } from './config';
import { addressInput } from './domain';
import { Transaction } from './Transaction';
import type { CrownState } from './useCrown';

export function OwnerPanel({ crown, runtime, symbol }: { crown: CrownState; runtime: Runtime; symbol: string }) {
  const [token, setToken] = useState('');
  const [bps, setBps] = useState('100');
  const binding = crown.binding.data;
  if (!binding || crown.connection.address?.toLowerCase() !== binding.owner.toLowerCase()) return null;
  return <details className="deployment-details owner-panel">
    <summary>Owner: configure a new pool</summary>
    <p className="muted">Set the ticker and crown cut before a native ETH pool is initialized. Live pools cannot be changed.</p>
    <div className="owner-fields"><div><label htmlFor="pool-token">Token paired with native ETH</label><input id="pool-token" value={token} onChange={e => setToken(e.target.value)} placeholder="0x…" spellCheck={false}/></div><div><label htmlFor="pool-bps">Crown cut in basis points (0–500)</label><input id="pool-bps" value={bps} onChange={e => setBps(e.target.value)} inputMode="numeric"/></div></div>
    <p className="field-help">Ticker: {symbol}. LP fee: 1.25%. Tick spacing: 60. This configures the hook; it does not create or fund the pool.</p>
    <Transaction crown={crown} runtime={runtime} id="configure-pool" fieldId="pool-bps" label="Review pool configuration"
      description={<p>Associate a future native ETH pool with {symbol}, a {bps} basis point crown cut and token <span className="full-address">{token}</span>. LP fee is 1.25% and tick spacing is 60. The owner can edit this setting only until initialization.</p>}
      prepare={async () => {
        if (!/^\d{1,3}$/.test(bps) || Number(bps) > 500) throw new Error('Enter a whole number from 0 to 500 basis points.');
        const currency1 = addressInput(token);
        if (!await crown.client.getBytecode({ address: currency1 })) throw new Error('The token has no deployed code. Check its address.');
        return { address: binding.hook, abi: runtime.abis.CrownHook, functionName: 'configurePool', args: [{ currency0: ZERO, currency1, fee: RULES.poolFee, tickSpacing: RULES.tickSpacing, hooks: binding.hook }, tickerHash(symbol), Number(bps)] };
      }}/>
  </details>;
}
