import { useEffect, useRef, useState } from 'react';
import { useConnect, useConnection, useDisconnect, type Connector } from 'wagmi';
import type { EIP1193Provider } from 'viem';
import { explain, short } from './domain';
import type { Runtime } from './config';

const mobileWallets = [
  { name: 'MetaMask', icon: 'metamask', href: (url: string) => `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, '')}` },
  { name: 'Coinbase Wallet', icon: 'coinbase', href: (url: string) => `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}` },
  { name: 'Rabby', icon: 'rabby', href: (url: string) => `https://go.rabby.io/mobile/?_cmd=open-dapp&dapp=${encodeURIComponent(url)}` },
  { name: 'Phantom', icon: 'phantom', href: (url: string) => `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}` },
];

export async function switchNetwork(provider: EIP1193Provider, runtime: Runtime) {
  const chainId = `0x${runtime.chain.id.toString(16)}`;
  try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] }); }
  catch (error) {
    const e = error as { code?: number; message?: string; cause?: { code?: number } };
    if (e.code !== 4902 && e.cause?.code !== 4902 && !/unknown chain|unrecognized chain|not added/i.test(e.message ?? '')) throw error;
    await provider.request({ method: 'wallet_addEthereumChain', params: [runtime.walletAddChain as never] });
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] });
  }
}
export function Wallet({ runtime }: { runtime: Runtime }) {
  const { address, chainId, connector, isConnected } = useConnection();
  const { connectors, connectAsync, isPending, variables } = useConnect();
  const { disconnect } = useDisconnect();
  const dialog = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const [error, setError] = useState('');
  const [switching, setSwitching] = useState(false);
  const [open, setOpen] = useState(false);
  const mobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) && !connectors.some(c => c.type === 'injected' && c.id !== 'injected') && !('ethereum' in window);
  useEffect(() => { if (open) dialog.current?.showModal(); else if (dialog.current?.open) dialog.current.close(); }, [open]);
  const close = () => { setOpen(false); trigger.current?.focus(); };
  const wrongChain = isConnected && chainId !== runtime.chain.id;
  async function changeChain() {
    if (!connector) return;
    setSwitching(true); setError('');
    try { await switchNetwork(await connector.getProvider() as EIP1193Provider, runtime); }
    catch (e) { setError(explain(e)); }
    finally { setSwitching(false); }
  }
  async function connect(c: Connector) {
    setError('');
    try { await connectAsync({ connector: c }); close(); }
    catch (e) { setError(explain(e)); }
  }
  const named = connectors.some(c => c.type === 'injected' && c.id !== 'injected');
  const listed = [...connectors.filter(c => c.type === 'injected'), ...connectors.filter(c => c.type !== 'injected')]
    .filter(c => !(c.id === 'injected' && named) && !(mobile && c.type === 'injected'));
  return <div className="wallet-control">
    <button className="wallet-button" ref={trigger} onClick={() => wrongChain ? void changeChain() : setOpen(true)} disabled={switching}>
      <span className={`connection-dot ${isConnected && !wrongChain ? 'connected' : ''}`} aria-hidden="true"/>
      {switching ? 'Switching network…' : wrongChain ? `Switch to ${runtime.chain.name}` : address ? short(address) : 'Connect wallet'}
    </button>
    {error && !open && <p className="error wallet-error" role="alert">{error}</p>}
    <dialog ref={dialog} className="wallet-sheet" onCancel={close} onClose={close} onClick={e => { if (e.target === e.currentTarget) close(); }} aria-labelledby="wallet-title">
      <div className="sheet-inner">
        <div className="section-head"><h2 id="wallet-title">{isConnected ? 'Your wallet' : 'Connect a wallet'}</h2><button className="icon-button" aria-label="Close wallet menu" onClick={close}>×</button></div>
        {isConnected && address ? <><p className="full-address">{address}</p><a className="row-link" href={`${runtime.explorer}/address/${address}`} target="_blank" rel="noreferrer">View wallet on explorer ↗</a><button className="wallet-row" onClick={() => { disconnect(); close(); }}>Disconnect wallet</button></> : <>
          <p className="muted">You keep control of your funds. Connecting does not send a transaction.</p>
          {mobile && mobileWallets.map(w => <a className="wallet-row" key={w.name} href={w.href(location.href)}><img src={`./wallets/${w.icon}.svg`} alt="" width="28" height="28"/>Open in {w.name}</a>)}
          {listed.map(c => <button key={c.uid} className="wallet-row" onClick={() => void connect(c)} disabled={isPending}>
            <img src={c.icon ?? `./wallets/${c.id === 'coinbaseWalletSDK' ? 'coinbase' : 'browser'}.svg`} alt="" width="28" height="28"/>
            <span>{c.id === 'injected' ? 'Browser wallet' : c.id === 'coinbaseWalletSDK' ? (mobile ? 'Coinbase Smart Wallet' : 'Coinbase Wallet') : c.name}{isPending && variables?.connector === c ? ' · opening…' : ''}</span>
          </button>)}
          {error && <p className="error" role="alert">{error}</p>}
        </>}
      </div>
    </dialog>
  </div>;
}
