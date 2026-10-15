import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useConnection, useWalletClient } from 'wagmi';
import type { Abi, Address, Hash, TransactionReceipt } from 'viem';
import type { CrownState } from './useCrown';
import type { Runtime } from './config';
import { explain } from './domain';

export type Call = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint };
export function Transaction({ label, id, description, disabled, prepare, crown, runtime, onSuccess, primary = false, fieldId }: {
  label: string; id: string; description: ReactNode; disabled?: boolean;
  prepare: () => Call | Promise<Call>; crown: CrownState; runtime: Runtime; onSuccess?: () => void | Promise<void>; primary?: boolean; fieldId?: string;
}) {
  const { address, chainId } = useConnection();
  const { data: wallet, error: walletError } = useWalletClient({ chainId: runtime.chain.id, query: { enabled: Boolean(address && chainId === runtime.chain.id) } });
  const [status, setStatus] = useState<'idle' | 'checking' | 'review' | 'signing' | 'confirming' | 'unconfirmed' | 'done' | 'error'>('idle');
  const [invalidField, setInvalidField] = useState(false);
  const [error, setError] = useState('');
  const [hash, setHash] = useState<Hash>();
  const [call, setCall] = useState<Call>();
  const [gas, setGas] = useState<bigint>();
  const [submittedDescription, setSubmittedDescription] = useState<ReactNode>();
  const busy = ['checking', 'review', 'signing', 'confirming', 'unconfirmed'].includes(status);
  const receiptHash = useRef<Hash | undefined>(undefined);
  const replaced = useRef(false);
  const ref = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const lock = useRef(false);
  const context = useRef('');
  const currentContext = `${address}:${chainId}`;
  const unavailable = disabled || !address || !wallet || chainId !== runtime.chain.id || !crown.binding.data || !crown.snapshot.data || crown.binding.isError || crown.snapshot.isError || Date.now() - crown.snapshot.data.observedAt > 30_000;
  useEffect(() => { if (status === 'review') ref.current?.showModal(); else ref.current?.close(); }, [status]);
  useEffect(() => { if (status === 'review' && context.current !== currentContext) { setStatus('error'); setError('Your wallet or network changed. Review this action again.'); lock.current = false; } }, [currentContext, status]);
  useEffect(() => {
    const field = fieldId && invalidField ? document.getElementById(fieldId) : null;
    if (!field) return;
    const previousDescription = field.getAttribute('aria-describedby');
    field.setAttribute('aria-invalid', 'true'); field.setAttribute('aria-describedby', `${previousDescription ?? ''} ${id}-result`.trim()); field.focus();
    const clear = () => { setInvalidField(false); setError(''); };
    field.addEventListener('input', clear);
    return () => { field.removeEventListener('input', clear); field.removeAttribute('aria-invalid'); if (previousDescription) field.setAttribute('aria-describedby', previousDescription); else field.removeAttribute('aria-describedby'); };
  }, [fieldId, invalidField, id]);
  const cancel = () => { if (status !== 'review') return; setStatus('idle'); lock.current = false; trigger.current?.focus(); };
  async function review() {
    if (unavailable || lock.current) return;
    lock.current = true; setStatus('checking'); setError(''); setHash(undefined); setInvalidField(false); receiptHash.current = undefined; replaced.current = false; context.current = currentContext;
    try {
      let prepared: Call;
      try { prepared = await prepare(); } catch (e) { setInvalidField(true); throw e; }
      await crown.client.simulateContract({ ...prepared, account: address! });
      const estimate = await crown.client.estimateContractGas({ ...prepared, account: address! });
      const price = await crown.client.getGasPrice();
      const fee = estimate * price;
      if ((prepared.value ?? 0n) + fee > await crown.client.getBalance({ address: address! })) throw new Error('Your wallet needs enough ETH for the amount and network gas.');
      setGas(fee); setCall(prepared); setSubmittedDescription(description); setStatus('review');
    } catch (e) { setError(explain(e)); setStatus('error'); lock.current = false; }
  }
  async function finish(receipt: TransactionReceipt) {
    lock.current = false;
    if (replaced.current || receipt.status !== 'success') {
      setError(replaced.current ? 'The wallet replaced or cancelled this transaction. Check the explorer for the action that was confirmed.' : 'The transaction reverted. No contract change was confirmed.');
      setStatus('error');
    } else { setError(''); setStatus('done'); }
    await crown.snapshot.refetch();
    if (!replaced.current && receipt.status === 'success') await onSuccess?.();
    trigger.current?.focus();
  }
  async function checkReceipt() {
    if (!receiptHash.current) return;
    setStatus('confirming');
    try { await finish(await crown.client.getTransactionReceipt({ hash: receiptHash.current })); }
    catch { setError('Confirmation is still unknown. Check the explorer or retry the receipt check.'); setStatus('unconfirmed'); }
  }
  async function send() {
    if (status !== 'review' || !call || !wallet || unavailable || context.current !== currentContext) return;
    setStatus('signing');
    try {
      if (await wallet.getChainId() !== runtime.chain.id) throw new Error('Switch your wallet to the configured network.');
      const accounts = await wallet.getAddresses();
      if (accounts[0]?.toLowerCase() !== address?.toLowerCase()) throw new Error('Your wallet account changed. Review again.');
      const simulated = await crown.client.simulateContract({ ...call, account: address! });
      const txHash = await wallet.writeContract({ ...simulated.request, chain: runtime.chain, account: address! });
      receiptHash.current = txHash; setHash(txHash); setStatus('confirming');
      const receipt = await crown.client.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000,
        onReplaced: replacement => { receiptHash.current = replacement.transaction.hash; setHash(replacement.transaction.hash); replaced.current = replacement.reason !== 'repriced'; } });
      await finish(receipt);
    } catch (e) {
      if (receiptHash.current) { setError('Submitted, but confirmation could not be checked. Check the explorer before taking another action.'); setStatus('unconfirmed'); }
      else { setError(explain(e)); setStatus('error'); lock.current = false; trigger.current?.focus(); }
    }
  }
  const pendingLabel = status === 'checking' ? 'Checking transaction…' : status === 'review' ? 'Review transaction' : status === 'signing' ? 'Confirm in wallet…' : status === 'confirming' ? 'Waiting for confirmation…' : status === 'unconfirmed' ? 'Confirmation not yet known' : label;
  return <div className="transaction" data-action={id}>
    <button ref={trigger} className={primary ? 'primary' : 'secondary'} disabled={unavailable || busy} onClick={() => void review()} aria-busy={busy}>{busy && <span className="spinner" aria-hidden="true"/>}{pendingLabel}</button>
    {walletError && address && chainId === runtime.chain.id && <p className="error" role="alert">The wallet connection is not ready. Disconnect and reconnect to retry.</p>}
    {(error || status === 'done' || hash) && <div id={`${id}-result`} className={`tx-result ${error ? 'error' : ''}`} role={error ? 'alert' : 'status'}>
      {error || (status === 'done' ? 'Transaction confirmed.' : 'Transaction submitted. Waiting for its receipt.')}
      {hash && <a href={`${runtime.explorer}/tx/${hash}`} target="_blank" rel="noreferrer">View transaction ↗</a>}
      {status === 'unconfirmed' && <button onClick={() => void checkReceipt()}>Check confirmation</button>}
    </div>}
    <dialog className="review-sheet" ref={ref} onCancel={cancel} aria-labelledby={`${id}-title`}>
      <h2 id={`${id}-title`}>Review transaction</h2>
      <div className="review-description">{submittedDescription}</div>
      <dl className="facts"><div><dt>Network</dt><dd>{runtime.chain.name}</dd></div><div><dt>Contract</dt><dd className="full-address">{call?.address}</dd></div><div><dt>Estimated gas</dt><dd>{gas === undefined ? 'Checking…' : `${(Number(gas) / 1e18).toPrecision(3)} ETH`}</dd></div></dl>
      <p className="muted">Your wallet shows the final network fee. USD value is unavailable.</p>
      <div className="review-buttons"><button className="secondary" onClick={cancel}>Go back</button><button className="primary" onClick={() => void send()} disabled={unavailable}>Confirm in wallet</button></div>
    </dialog>
  </div>;
}
