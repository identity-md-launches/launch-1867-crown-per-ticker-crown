import React from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { loadRuntime, walletConfig } from './config';
import { App } from './App';
import './styles.css';

const root = createRoot(document.getElementById('root')!);
loadRuntime().then(runtime => {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: true } } });
  root.render(<React.StrictMode><WagmiProvider config={walletConfig(runtime)}><QueryClientProvider client={queryClient}><App runtime={runtime}/></QueryClientProvider></WagmiProvider></React.StrictMode>);
}).catch(() => root.render(<main className="boot-error"><img src="./favicon.svg" width="48" height="48" alt=""/><h1>Crown could not load</h1><p>The deployment configuration or its ABI files could not be verified. Reload to try again. No wallet action is available until this is fixed.</p><button onClick={() => location.reload()}>Reload page</button></main>));
