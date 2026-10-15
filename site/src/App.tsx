import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { formatEther, type Address } from 'viem';
import { contract, DEFAULT_TICKER, RULES, tickerHash, ZERO, type Runtime } from './config';
import { addressInput, amount, challengeId, date, eth, explain, opensAt, phase, remaining, short } from './domain';
import { useCrown } from './useCrown';
import { Wallet } from './Wallet';
import { Transaction } from './Transaction';
import { OwnerPanel } from './OwnerPanel';

function Crown({ className = '' }: { className?: string }) { return <svg className={className} viewBox="0 0 64 64" fill="none" aria-hidden="true"><path d="m8 20 14 10 10-19 10 19 14-10-6 28H14Z" fill="currentColor"/><path d="M17 55h30" stroke="currentColor" strokeWidth="3"/></svg>; }
function Arrow() { return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M5 12h14m-6-6 6 6-6 6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>; }
function AddressView({ value, runtime, label }: { value?: Address; runtime: Runtime; label: string }) {
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState(false);
  if (!value || value === ZERO) return <span className="muted">Not available</span>;
  return <span className="address-view"><a title={value} aria-label={`${label}: ${value}. Open explorer`} href={`${runtime.explorer}/address/${value}`} target="_blank" rel="noreferrer">{short(value)} ↗</a><button className="copy" aria-label={`Copy ${label}`} title={value} onClick={() => { void navigator.clipboard.writeText(value).then(() => { setCopied(true); setCopyError(false); setTimeout(() => setCopied(false), 2000); }).catch(() => setCopyError(true)); }}>{copied ? 'Copied' : 'Copy'}</button>{copyError && <span className="full-address" role="status">{value}</span>}</span>;
}
function Fact({ label, children }: { label: string; children: ReactNode }) { return <div><dt>{label}</dt><dd>{children}</dd></div>; }

export function App({ runtime }: { runtime: Runtime }) {
  const initial = new URLSearchParams(location.hash.slice(1)).get('ticker')?.toUpperCase();
  const [symbol, setSymbol] = useState(initial && /^[A-Z0-9._-]{1,32}$/.test(initial) ? initial : DEFAULT_TICKER);
  const [tickerInput, setTickerInput] = useState(symbol);
  const [tickerError, setTickerError] = useState('');
  const [lookup, setLookup] = useState<bigint>();
  const [lookupInput, setLookupInput] = useState('');
  const [lookupError, setLookupError] = useState('');
  const [candidate, setCandidate] = useState(contract(runtime, 'CrownChallengerToken') ?? '');
  const [registerToken, setRegisterToken] = useState('');
  const [registerBeneficiary, setRegisterBeneficiary] = useState('');
  const [stakeAmount, setStakeAmount] = useState('0.01');
  const [side, setSide] = useState<0 | 1>(1);
  const [redeemAmount, setRedeemAmount] = useState('');
  const [tick, setTick] = useState(Date.now());
  const crown = useCrown(runtime, symbol, lookup);
  const { connection, binding, snapshot } = crown;
  const data = snapshot.data;
  const bound = binding.data;
  useEffect(() => { const timer = setInterval(() => setTick(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const now = data ? data.time + Math.max(0, tick - data.observedAt) / 1000 : 0;
  const stale = data && tick - data.observedAt > 30_000;
  const activePhase = phase(data?.active, now);
  const selectedPhase = phase(data?.selected, now);
  const kingExists = data && data.king[0] !== ZERO;
  const eligible = Boolean(data && kingExists && data.totals[0] === 0n && now >= opensAt(data.challengeableAt, data.totals));
  const active = data?.active;
  const totalStake = active ? active[8] + active[9] : 0n;
  const quorum = totalStake >= RULES.quorum;
  const challengerAhead = active && active[9] > active[8];
  const readiness = !crown.configured ? 'Contract addresses will appear after launch.' : binding.isError ? explain(binding.error) : snapshot.isError ? 'Live reads failed. Transactions are paused until a successful refresh.' : stale ? 'These reads are stale. Refresh before transacting.' : !data ? 'Reading the registry…' : !connection.isConnected ? 'Connect your wallet to take part.' : connection.chainId !== runtime.chain.id ? `Switch to ${runtime.chain.name} to continue.` : '';
  const tx = { crown, runtime };
  const regCall = (functionName: string, args: readonly unknown[] = [], value?: bigint) => ({ address: bound!.registry, abi: runtime.abis.CrownRegistry, functionName, args, value });
  function loadTicker(event: FormEvent) {
    event.preventDefault(); const next = tickerInput.trim().toUpperCase();
    if (!/^[A-Z0-9._-]{1,32}$/.test(next)) { setTickerError('Use 1–32 letters, numbers, dots, underscores or hyphens.'); return; }
    setTickerError(''); setSymbol(next); setTickerInput(next); setLookup(undefined); setLookupInput(''); setCandidate(next === DEFAULT_TICKER ? contract(runtime, 'CrownChallengerToken') ?? '' : '');
    history.replaceState(null, '', `#ticker=${encodeURIComponent(next)}`);
  }
  function findChallenge(event: FormEvent) {
    event.preventDefault();
    try { setLookup(challengeId(lookupInput.trim())); setLookupError(''); }
    catch (e) { setLookupError(explain(e)); }
  }
  async function validateToken(raw: string, different = true) {
    const token = addressInput(raw);
    if (different && token.toLowerCase() === data?.king[0].toLowerCase()) throw new Error('Choose a different token with the same ticker.');
    if (!await crown.client.getBytecode({ address: token })) throw new Error('This token address has no deployed code. Check its network and address.');
    const tokenSymbol = await crown.client.readContract({ address: token, abi: runtime.abis.CrownToken, functionName: 'symbol' }) as string;
    if (tickerHash(tokenSymbol) !== tickerHash(symbol)) throw new Error(`The token must report the symbol ${symbol}.`);
    return token;
  }
  const selectedMatches = data?.selected?.[0] === tickerHash(symbol) && Number(data?.selected?.[3]) > 0;

  return <>
    <a href="#main" className="skip-link">Skip to ticker</a>
    <header className="site-header">
      <a href="#main" className="brand" aria-label="Crown home"><Crown/><span>Crown</span></a>
      <nav aria-label="Main navigation"><a href="#registry">Registry</a><a href="#how-it-works">How it works</a></nav>
      <Wallet runtime={runtime}/>
    </header>
    <main id="main">
      <div className="page-heading" id="registry">
        <div><h1>The <span>{symbol}</span> crown</h1><p>One canonical token, decided by ETH stakes.</p></div>
        <form className="ticker-search" onSubmit={loadTicker}>
          <label htmlFor="ticker">Find a ticker</label><div className="input-action"><input id="ticker" name="ticker" value={tickerInput} onChange={e => setTickerInput(e.target.value)} autoComplete="off" spellCheck={false} maxLength={32} aria-invalid={Boolean(tickerError)} aria-describedby={tickerError ? 'ticker-error' : undefined}/><button aria-label="Show ticker" type="submit"><Arrow/></button></div>
          {tickerError && <p className="error" id="ticker-error" role="alert">{tickerError}</p>}
        </form>
      </div>
      <div className={`network-strip ${snapshot.isError || binding.isError ? 'failed' : ''}`}>
        <span><span className="connection-dot" aria-hidden="true"/>{runtime.chain.name}</span>
        <span>{!crown.configured ? 'Awaiting deployment' : binding.isError || snapshot.isError ? 'Connection interrupted' : data ? `Block ${data.block.toLocaleString()}` : 'Loading contracts…'}</span>
        {crown.configured && <button onClick={() => { void binding.refetch(); void snapshot.refetch(); }} disabled={snapshot.isFetching}>Refresh</button>}
      </div>
      <div className={`crown-grid ${active ? 'live' : ''}`}>
        <section className="king-panel" aria-labelledby="king-title">
          <div className="king-top"><h2 id="king-title">Current king</h2><span className="status-label">{data ? kingExists ? 'Crowned' : 'Unregistered' : 'Not loaded'}</span></div>
          <div className="king-identity"><div className="crown-seal"><Crown/></div><div><h3>{kingExists ? `${symbol} king` : data ? 'A crown awaits' : 'Awaiting the crown'}</h3><p>{kingExists ? <AddressView value={data.king[0]} runtime={runtime} label="king token"/> : 'Canonical token registry'}</p></div></div>
          <dl className="facts king-facts">
            <Fact label="Beneficiary"><AddressView value={data?.king[1]} runtime={runtime} label="beneficiary"/></Fact>
            <Fact label="Reign">{kingExists ? `${Math.floor((now - Number(data.king[2])) / 86400)} days` : 'Not loaded'}</Fact>
          </dl>
          <details className="king-details"><summary>Reign details</summary><dl className="facts"><Fact label="Reign clock since">{kingExists ? date(Number(data.king[2])) : 'Not available'}</Fact><Fact label="Challenge opens">{kingExists ? date(opensAt(data.challengeableAt, data.totals)) : 'After seven days of reign'}</Fact><Fact label="Ticker key"><span className="full-address">{tickerHash(symbol)}</span></Fact></dl></details>
          <div className="king-foot"><span className="crown-mini"><Crown/></span><p>Participating pools pay this ticker’s beneficiary.</p></div>
        </section>

        <section className="action-panel" aria-labelledby="action-title">
          <div className="section-head"><h2 id="action-title">{activePhase === 'staking' ? 'Back your side' : activePhase === 'timelock' ? 'Resolution timelock' : activePhase === 'ready' ? 'Resolve the challenge' : data && !kingExists ? 'Register the first king' : 'Challenge the king'}</h2><Arrow/></div>
          {active && activePhase !== 'none' ? <>
            <div className="stake-totals"><div><span>King</span><strong>{eth(active[8])} ETH</strong></div><div><span>Challenger</span><strong>{eth(active[9])} ETH</strong></div></div>
            <div className="stake-bar" role="img" aria-label={`King ${formatEther(active[8])} ETH, challenger ${formatEther(active[9])} ETH`}><span style={{ width: `${totalStake ? Number(active[8] * 10000n / totalStake) / 100 : 50}%` }}/></div>
            <div className="challenge-clock"><span>{activePhase === 'staking' ? 'Staking closes in' : activePhase === 'timelock' ? 'Finalization opens in' : 'Ready to finalize'}</span><strong>{activePhase === 'ready' ? 'Timelock ended' : remaining(Number(active[activePhase === 'staking' ? 4 : 5]), now)}</strong></div>
            {activePhase === 'staking' ? <>
              <fieldset className="side-picker"><legend>Choose a side</legend>{([0, 1] as const).map(value => <label key={value} className={side === value ? 'selected' : ''}><input type="radio" name="side" checked={side === value} onChange={() => setSide(value)}/>{value === 0 ? 'Back the king' : 'Back challenger'}</label>)}</fieldset>
              <label htmlFor="stake-amount">Stake amount (ETH)</label><input id="stake-amount" inputMode="decimal" value={stakeAmount} onChange={e => setStakeAmount(e.target.value)} autoComplete="off" aria-describedby="stake-risk"/>
              <p id="stake-risk" className="field-help">Locked until finalization. The losing side loses 20%.</p>
              <Transaction key={`stake-${symbol}-${data?.totals[0]}`} {...tx} id="stake" fieldId="stake-amount" label="Review stake" primary disabled={!active || activePhase !== 'staking'} description={<p>Stake <strong>{stakeAmount} ETH</strong> on the <strong>{side === 0 ? 'king' : 'challenger'}</strong> in challenge #{data?.totals[0].toString()}. Your stake is locked until finalization. The losing side loses 20%.</p>} prepare={() => regCall('stake', [data!.totals[0], side], amount(stakeAmount))}/>
            </> : <><p className="field-help">{activePhase === 'timelock' ? 'Staking has closed. Anyone can finalize after the 24-hour timelock.' : 'Finalize to apply the outcome and unlock stake refunds.'}</p><Transaction {...tx} id="finalize" label="Finalize challenge" primary disabled={activePhase !== 'ready'} description={<p>Resolve challenge #{data?.totals[0].toString()}. {quorum && challengerAhead ? 'The challenger currently leads and quorum is met.' : 'Current stakes keep the king in place.'} The contract determines the final outcome and applies the losing side’s 20% slash.</p>} prepare={() => regCall('finalize', [data!.totals[0]])} onSuccess={() => { setLookup(data!.totals[0]); setLookupInput(data!.totals[0].toString()); }}/></>}
            <p className="quorum-label">{quorum ? 'Quorum met' : `${eth(RULES.quorum - totalStake)} ETH to quorum`} · 0.05 ETH required</p>
          </> : data && !kingExists ? <>
            <p className="field-help">First registration crowns a token with this symbol. Check the beneficiary carefully.</p>
            <label htmlFor="register-token">Token address</label><input id="register-token" value={registerToken} onChange={e => setRegisterToken(e.target.value)} placeholder="0x…" autoComplete="off" spellCheck={false}/>
            <label htmlFor="register-beneficiary">Beneficiary wallet</label><input id="register-beneficiary" value={registerBeneficiary} onChange={e => setRegisterBeneficiary(e.target.value)} placeholder="0x…" autoComplete="off" spellCheck={false}/>
            <Transaction {...tx} id="register" primary label="Review registration" description={<p>Crown <span className="full-address">{registerToken}</span> for {symbol}. Swap fees will go to <span className="full-address">{registerBeneficiary}</span>. Registration cannot be undone by an admin.</p>} prepare={async () => regCall('registerKing', [tickerHash(symbol), await validateToken(registerToken, false), addressInput(registerBeneficiary)])}/>
          </> : <>
            <div className="bond-row"><span>Opening bond</span><strong>0.01 ETH</strong></div>
            <label htmlFor="candidate">Challenger token address</label><input id="candidate" value={candidate} onChange={e => setCandidate(e.target.value)} placeholder="0x…" autoComplete="off" spellCheck={false} aria-describedby="candidate-help"/>
            <p className="field-help" id="candidate-help">Same ticker, different token. Your wallet receives the fees if it wins.</p>
            <Transaction key={`open-${symbol}`} {...tx} id="challenge" fieldId="candidate" primary label="Open challenge · 0.01 ETH" disabled={!eligible} description={<p>Open a challenge for {symbol} with a <strong>0.01 ETH</strong> bond. The bond counts as challenger stake and is subject to the 20% losing-side slash. If you win, <span className="full-address">{connection.address}</span> becomes the beneficiary for <span className="full-address">{candidate}</span>.</p>} prepare={async () => regCall('openChallenge', [tickerHash(symbol), await validateToken(candidate)], RULES.bond)}/>
            {data && !eligible && <p className="field-help">Opens {date(opensAt(data.challengeableAt, data.totals))} · {remaining(opensAt(data.challengeableAt, data.totals), now)} remaining.</p>}
          </>}
          {readiness && <p className="readiness" role="status">{readiness}</p>}
        </section>
      </div>

      <section className="ticker-metrics" aria-labelledby="totals-title">
        <div className="metric-title"><h2 id="totals-title">The ticker, to date</h2><p className="muted">Across every reign</p></div>
        <dl><div><dt>Crown paid</dt><dd title={data ? `${formatEther(data.paid)} ETH` : undefined}>{data ? eth(data.paid) : 'Not loaded'}{data && <small> ETH</small>}</dd></div><div><dt>Total staked</dt><dd title={data ? `${formatEther(data.totals[4])} ETH` : undefined}>{data ? eth(data.totals[4]) : 'Not loaded'}{data && <small> ETH</small>}</dd></div><div><dt>Dethrones</dt><dd>{data ? data.totals[3].toString() : 'Not loaded'}</dd></div><div><dt>Challenges</dt><dd>{data ? data.totals[2].toString() : 'Not loaded'}</dd></div></dl>
        <p className="field-help">Crown paid counts ETH transfers and redeemable PoolManager claims. USD value is unavailable.</p>
      </section>

      {active && <section className="detail-section" aria-labelledby="challenge-details-title"><div className="section-head"><h2 id="challenge-details-title">Challenge #{data?.totals[0].toString()}</h2><span className="status-label">{activePhase === 'staking' ? 'Staking open' : activePhase === 'timelock' ? 'Timelocked' : 'Ready'}</span></div><dl className="facts two-columns"><Fact label="Challenger token"><AddressView value={active[1]} runtime={runtime} label="challenger token"/></Fact><Fact label="New beneficiary if it wins"><AddressView value={active[2]} runtime={runtime} label="challenger beneficiary"/></Fact><Fact label="Staking closes">{date(Number(active[4]))}</Fact><Fact label="Finalization opens">{date(Number(active[5]))}</Fact><Fact label="Current outcome">{quorum && challengerAhead ? 'Challenger wins at these stakes' : !quorum ? 'King stays: below quorum' : 'King stays: challenger must lead'}</Fact><Fact label="Total slashed, all challenges">{eth(data?.totals[5])} ETH</Fact></dl></section>}

      <div className="secondary-grid">
        <section className="detail-section" aria-labelledby="refund-title">
          <h2 id="refund-title">Your stake & refunds</h2><p className="muted">Look up any challenge for {symbol}, including a finished one.</p>
          <form onSubmit={findChallenge} className="lookup-form"><label htmlFor="lookup">Challenge number</label><div className="input-action"><input id="lookup" inputMode="numeric" value={lookupInput} onChange={e => setLookupInput(e.target.value)} placeholder={data?.totals[0] ? data.totals[0].toString() : 'Challenge number'} aria-invalid={Boolean(lookupError)} aria-describedby={lookupError ? 'lookup-error' : undefined}/><button type="submit">Look up</button></div>{lookupError && <p id="lookup-error" className="error" role="alert">{lookupError}</p>}</form>
          {lookup && data && !selectedMatches && <p className="error" role="status">Challenge #{lookup.toString()} does not exist for {symbol}. Check the number.</p>}
          {selectedMatches && data ? <><p className="selected-challenge">Challenge #{data.selectedId.toString()} · {selectedPhase === 'finalized' ? data.selected![7] ? 'Challenger won' : 'King retained' : selectedPhase === 'staking' ? 'Staking open' : 'Awaiting finalization'}</p><dl className="facts"><Fact label="Your king stake">{eth(data.ownKing)} ETH</Fact><Fact label="Your challenger stake">{eth(data.ownChallenger)} ETH</Fact><Fact label="Available refund"><span title={`${formatEther(data.claimable)} ETH`}>{eth(data.claimable)} ETH</span></Fact></dl></> : <p className="field-help">{data?.count ? `${data.count.toString()} challenges exist in this registry.` : 'No challenge selected.'}</p>}
          <Transaction key={`claim-${data?.selectedId}`} {...tx} id="claim" label="Claim stake refund" disabled={!selectedMatches || !data?.claimable} description={<p>Claim the current refund of <strong>{data ? formatEther(data.claimable) : '0'} ETH</strong> from challenge #{data?.selectedId.toString()} to your connected wallet. Rounding may change by a few wei if another staker claims first.</p>} prepare={() => regCall('claim', [data!.selectedId])}/>
          {!connection.isConnected && <p className="field-help">Connect to see your stake and claimable refund.</p>}
        </section>
        <section className="detail-section" aria-labelledby="fees-title">
          <h2 id="fees-title">Redeem fee claims</h2><p className="muted">Fees paid as claims belong to the beneficiary directly. The hook holds none.</p>
          <dl className="facts"><Fact label="Your available ETH claims">{connection.isConnected && data ? `${eth(data.feeClaims)} ETH` : 'Connect to view'}</Fact></dl>
          <label htmlFor="redeem-amount">Amount to redeem (ETH)</label><div className="input-action"><input id="redeem-amount" inputMode="decimal" value={redeemAmount} onChange={e => setRedeemAmount(e.target.value)} placeholder="0.00"/><button onClick={() => setRedeemAmount(formatEther(data?.feeClaims ?? 0n))} disabled={!data?.feeClaims}>Max</button></div>
          {!data?.operator ? <><p className="field-help">First, authorize CrownHook to redeem your PoolManager claims. This permission covers all your claim currencies.</p><Transaction {...tx} id="approve-claims" label="Authorize claim redemption" disabled={!data?.feeClaims} description={<p>Authorize CrownHook to operate your PoolManager claims, across all currencies. This is an on-chain approval. You can revoke it here after redeeming.</p>} prepare={() => ({ address: bound!.manager, abi: runtime.abis.PoolManager, functionName: 'setOperator', args: [bound!.hook, true] })}/></> : <><Transaction {...tx} id="redeem" fieldId="redeem-amount" label="Redeem ETH claims" disabled={!data.feeClaims} description={<p>Redeem <strong>{redeemAmount} ETH</strong> in PoolManager claims to your connected wallet. Your wallet must be able to receive ETH.</p>} prepare={() => { const value = amount(redeemAmount); if (value > data.feeClaims) throw new Error('The amount exceeds your available claims.'); return { address: bound!.hook, abi: runtime.abis.CrownHook, functionName: 'redeemClaim', args: [ZERO, value] }; }}/><Transaction {...tx} id="revoke-claims" label="Revoke claim permission" description={<p>Remove CrownHook’s permission to operate your PoolManager claims. Your claims remain yours.</p>} prepare={() => ({ address: bound!.manager, abi: runtime.abis.PoolManager, functionName: 'setOperator', args: [bound!.hook, false] })}/></>}
        </section>
      </div>

      <section id="how-it-works" className="how-section" aria-labelledby="how-title">
        <div><Crown className="how-crown"/><h2 id="how-title">How a crown changes hands</h2><p>One ticker. One king. Rules that everyone can read.</p></div>
        <ol className="steps"><li><span>01</span><div><h3>Let the king reign</h3><p>The first registered token holds the crown. After seven days, anyone except the current beneficiary can challenge with a different token that reports the same symbol.</p></div></li><li><span>02</span><div><h3>Put a stake behind it</h3><p>A 0.01 ETH bond opens a 72-hour vote and counts as challenger stake. Anyone can stake ETH on either side. Stakes stay locked until finalization.</p></div></li><li><span>03</span><div><h3>Let the rules decide</h3><p>After a further 24-hour timelock, anyone can finalize. The challenger needs more stake than the king and at least 0.05 ETH total across both sides. Ties and missed quorum keep the king.</p></div></li><li><span>04</span><div><h3>Claim your share</h3><p>Winners recover their stake plus half the losing side’s 20% slash. The other half goes to the treasury. Losers recover their remaining share. If no one staked on the winning side, all the slash goes to the treasury. Remainders go to each side’s last claimant.</p></div></li></ol>
        <div className="how-notes"><p>A failed challenge starts a three-day cooldown. A new king gets a fresh seven-day reign clock only if the old king was defended with at least 0.01 ETH, the same as the bond; a crown defended with less, or not at all, passes with the clock untouched, so a cheap or uncontested challenge buys no immunity. The registry has no admin override.</p><p>The default hook cut is 1%, on top of the pool’s 1.25% LP fee. ETH fees go to the current beneficiary during the swap, or as PoolManager claims if payment fails. If both paths fail, the swap skips the cut. A buy or exact-ETH sell that the pool cannot fill in full at its price limit is refused rather than charged on the unfilled part.</p></div>
      </section>

      <details className="deployment-details"><summary>Contracts & network</summary><dl className="facts two-columns"><Fact label="CrownHook"><AddressView value={bound?.hook} runtime={runtime} label="CrownHook"/></Fact><Fact label="CrownRegistry"><AddressView value={bound?.registry} runtime={runtime} label="CrownRegistry"/></Fact><Fact label="PoolManager"><AddressView value={bound?.manager} runtime={runtime} label="PoolManager"/></Fact><Fact label="Chain ID">{runtime.chain.id}</Fact></dl><p className="field-help">{runtime.handoff ? 'Addresses loaded from the workflow deployment handoff.' : 'No workflow deployment handoff was supplied. Addresses remain unset until launch.'} Trades and liquidity are unavailable on this ticker page{!runtime.network ? ': no vetted Uniswap network configuration was supplied.' : '.'}</p><p className="field-help">ETH amounts use 18 decimals. ENS lookup and USD pricing are not configured for this chain.</p>
        {data && <><p className="field-help">Treasury payout waiting to be retried: {eth(data.treasuryOwed)} ETH.</p><Transaction {...tx} id="treasury" label="Retry treasury payment" disabled={!data.treasuryOwed} description={<p>Retry payment of {formatEther(data.treasuryOwed)} ETH owed to the registry’s fixed treasury. This does not send funds to you.</p>} prepare={() => regCall('payTreasury')}/></>}
      </details>
      <OwnerPanel crown={crown} runtime={runtime} symbol={symbol}/>
    </main>
    <footer><a href="#main" className="brand"><Crown/><span>Crown</span></a><p>The crown belongs to the ticker.</p><a href={`${runtime.explorer}`} target="_blank" rel="noreferrer">Chain explorer ↗</a></footer>
  </>;
}
