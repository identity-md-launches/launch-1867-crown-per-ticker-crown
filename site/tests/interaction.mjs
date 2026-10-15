import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, stat } from 'node:fs/promises';
import { dirname, resolve, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { encodeFunctionResult, decodeFunctionData, encodeErrorResult, parseEther, keccak256, toBytes } from 'viem';

// Playwright lives outside the repository. IMD_PLAYWRIGHT names its module (as the design probe does); the
// fallback is the worker tool path used when this suite was first written.
const { chromium } = await import(pathToFileURL(process.env.IMD_PLAYWRIGHT ?? '/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs').href);

// These addresses and values are isolated browser-test fixtures. They are never copied to dist.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(root, 'dist');
const shots = resolve(root, 'test/scratch/interaction');
await mkdir(shots, { recursive: true });
const readJson = async path => JSON.parse(await readFile(path, 'utf8'));
const config = await readJson(resolve(dist, 'crown-config.json'));
const abis = Object.fromEntries(await Promise.all(Object.entries(config.abis).map(async ([name, path]) => [name, await readJson(resolve(dist, path))])));
const A = { hook: '0x10000000000000000000000000000000000010cc', registry: '0x2000000000000000000000000000000000000002', manager: '0x3000000000000000000000000000000000000003', king: '0x4000000000000000000000000000000000000004', beneficiary: '0x5000000000000000000000000000000000000005', challenger: '0x6000000000000000000000000000000000000006', account: '0x7000000000000000000000000000000000000007' };
const ZERO = `0x${'0'.repeat(40)}`;
const hash32 = `0x${'a'.repeat(64)}`;
const ticker = keccak256(toBytes('CRWN'));
const eth = parseEther;
const state = { now: 2_000_000_000, king: A.king, beneficiary: A.beneficiary, reign: 1_999_000_000, active: 0n,
  kingStake: 0n, challengerStake: 0n, ownKing: 0n, ownChallenger: 0n, opens: 0, ends: 0, finalAt: 0, finalized: false,
  won: false, claimed: false, claims: eth('0.003'), operator: false, treasury: eth('0.001'), total: 0n, slashed: 0n,
  simulationError: '', failReads: false, rejectSend: false, holdReceipt: false, registrations: new Map(), long: false };
const transactions = [];
const applied = new Set();
const calls = [];
let connected = false;
let chainBlock = 100n;
const hex = value => `0x${BigInt(value).toString(16)}`;
const abiAt = to => to.toLowerCase() === A.hook ? abis.CrownHook : to.toLowerCase() === A.registry ? abis.CrownRegistry : to.toLowerCase() === A.manager ? abis.PoolManager : abis.CrownToken;
function challenge() { return [ticker, A.challenger, A.account, BigInt(state.opens), BigInt(state.ends), BigInt(state.finalAt), state.finalized, state.won, state.kingStake, state.challengerStake, 0n, 0n, 0n, 0n]; }
function apply(tx) {
  const { functionName: f, args = [] } = decodeFunctionData({ abi: abiAt(tx.to), data: tx.data });
  const value = BigInt(tx.value ?? 0);
  if (f === 'openChallenge') { state.active = 1n; state.opens = state.now; state.ends = state.now + 72 * 3600; state.finalAt = state.ends + 86400; state.challengerStake = value; state.ownChallenger = value; state.total += value; }
  if (f === 'stake') { if (Number(args[1]) === 0) { state.kingStake += value; state.ownKing += value; } else { state.challengerStake += value; state.ownChallenger += value; } state.total += value; }
  if (f === 'finalize') { state.finalized = true; state.won = state.challengerStake > state.kingStake && state.total >= eth('0.05'); state.active = 0n; if (state.won) { state.king = A.challenger; state.beneficiary = A.account; if (state.kingStake > 0n) state.reign = state.now; } }
  if (f === 'claim') state.claimed = true;
  if (f === 'setOperator') state.operator = args[1];
  if (f === 'redeemClaim') state.claims -= args[1];
  if (f === 'payTreasury') state.treasury = 0n;
  if (f === 'registerKing') state.registrations.set(args[0], [args[1], args[2], BigInt(state.now)]);
}
function block() { return { number: hex(chainBlock), hash: hash32, parentHash: hash32, nonce: '0x0000000000000000', sha3Uncles: hash32,
  logsBloom: `0x${'0'.repeat(512)}`, transactionsRoot: hash32, stateRoot: hash32, receiptsRoot: hash32, miner: A.account,
  difficulty: '0x0', totalDifficulty: '0x0', extraData: '0x', size: '0x100', gasLimit: '0x1c9c380', gasUsed: '0x5208', timestamp: hex(state.now), transactions: [], uncles: [], baseFeePerGas: '0x3b9aca00', mixHash: hash32 }; }
function rpc(method, params = []) {
  calls.push(method);
  if (state.failReads && ['eth_call', 'eth_getBlockByNumber', 'eth_getCode'].includes(method)) throw { code: -32000, message: 'RPC test outage' };
  if (method === 'eth_chainId') return '0x1237';
  if (method === 'eth_accounts') return connected ? [A.account] : [];
  if (method === 'eth_requestAccounts') { connected = true; return [A.account]; }
  if (method === 'eth_getCode') return '0x60006000';
  if (method === 'eth_getBalance') return hex(eth('100'));
  if (method === 'eth_blockNumber') return hex(++chainBlock);
  if (method === 'eth_getBlockByNumber' || method === 'eth_getBlockByHash') return block();
  if (method === 'eth_estimateGas') return '0x186a0';
  if (method === 'eth_gasPrice' || method === 'eth_maxPriorityFeePerGas') return '0x3b9aca00';
  if (method === 'eth_getTransactionCount') return '0x0';
  if (method === 'eth_getLogs') return [];
  if (method === 'eth_sendTransaction') {
    if (state.rejectSend) { state.rejectSend = false; throw { code: 4001, message: 'User rejected request' }; }
    const txHash = `0x${(transactions.length + 1).toString(16).padStart(64, '0')}`;
    transactions.push({ ...params[0], hash: txHash }); return txHash;
  }
  if (method === 'eth_getTransactionReceipt') {
    if (state.receiptError) throw { code: -32000, message: 'Receipt provider test outage' };
    if (state.holdReceipt) return null;
    const tx = transactions.find(t => t.hash === params[0]);
    if (!tx) return null;
    if (!applied.has(tx.hash)) { apply(tx); applied.add(tx.hash); }
    return { transactionHash: tx.hash, transactionIndex: '0x0', blockHash: hash32, blockNumber: '0x64', from: A.account, to: tx.to,
      cumulativeGasUsed: '0x186a0', gasUsed: '0x186a0', effectiveGasPrice: '0x3b9aca00', contractAddress: null, logs: [], logsBloom: `0x${'0'.repeat(512)}`, status: '0x1', type: '0x2' };
  }
  if (method === 'eth_getTransactionByHash') { const tx = transactions.find(t => t.hash === params[0]); return tx ? { ...tx, blockHash: hash32, blockNumber: '0x64', transactionIndex: '0x0', input: tx.data, gas: '0x186a0', gasPrice: '0x3b9aca00', nonce: '0x0', value: tx.value ?? '0x0', type: '0x0', v: '0x25', r: hash32, s: hash32 } : null; }
  if (method === 'eth_call') {
    const [request] = params;
    const abi = abiAt(request.to);
    const { functionName: f, args = [] } = decodeFunctionData({ abi, data: request.data });
    const encode = result => encodeFunctionResult({ abi, functionName: f, result });
    const huge = (2n ** 256n - 1n);
    if (f === 'registry') return encode(A.registry);
    if (f === 'poolManager') return encode(A.manager);
    if (f === 'owner') return encode(A.account);
    if (f === 'king') return encode(args[0] === ticker ? [state.king, state.beneficiary, BigInt(state.reign)] : state.registrations.get(args[0]) ?? [ZERO, ZERO, 0n]);
    if (f === 'tickerTotals') return encode(args[0] === ticker ? [state.active, 0n, state.opens ? 1n : 0n, state.won ? 1n : 0n, state.long ? huge : state.total, state.slashed] : [0n, 0n, 0n, 0n, 0n, 0n]);
    if (f === 'crownPaid') return encode(state.long ? huge : eth(state.won ? '0.002' : '0.001'));
    if (f === 'treasuryOwed') return encode(state.treasury);
    if (f === 'challengeCount') return encode(state.opens ? 1n : 0n);
    if (f === 'challenges') return encode(args[0] === 1n && state.opens ? challenge() : [`0x${'0'.repeat(64)}`, ZERO, ZERO, 0n, 0n, 0n, false, false, 0n, 0n, 0n, 0n, 0n, 0n]);
    if (f === 'stakeOf') return encode(Number(args[2]) === 0 ? state.ownKing : state.ownChallenger);
    if (f === 'claimable') return encode(state.finalized && !state.claimed ? state.ownChallenger : 0n);
    if (f === 'balanceOf') return encode(state.claims);
    if (f === 'isOperator') return encode(state.operator);
    if (f === 'symbol') return encode(state.registrationMode ? 'TEST' : 'CRWN');
    if (f === 'decimals') return encode(18);
    if (state.simulationError) throw { code: 3, message: 'execution reverted', data: encodeErrorResult({ abi: abis.CrownRegistry, errorName: state.simulationError }) };
    return encode(f === 'openChallenge' ? 1n : f === 'claim' ? state.ownChallenger : f === 'setOperator' ? true : undefined);
  }
  throw { code: -32601, message: `Unhandled test RPC method ${method}` };
}
const server = createServer(async (request, response) => {
  const path = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
  const file = resolve(dist, path.replace(/^\/preview\//, '') || 'index.html');
  if (!file.startsWith(`${dist}/`) || !path.startsWith('/preview/')) { response.writeHead(404).end(); return; }
  try { const bytes = await readFile(file); response.setHeader('content-type', { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' }[extname(file)] ?? 'application/octet-stream'); response.end(bytes); }
  catch { response.writeHead(404).end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/preview/index.html`;
const browser = await chromium.launch({ headless: true });
const results = [];
const check = (name, value = true) => { assert.ok(value, name); results.push(name); console.log(`PASS ${name}`); };
async function waitText(page, selector, text) { try { await page.locator(selector).filter({ hasText: text }).first().waitFor(); } catch (error) { console.log('Observed UI:', await page.locator(selector).allTextContents()); await page.screenshot({ path: resolve(shots, 'failure.png'), fullPage: true }); throw error; } }
async function transact(page, action) {
  await page.locator(`[data-action="${action}"] > button`).click();
  await page.getByRole('dialog', { name: 'Review transaction' }).waitFor();
  await page.getByRole('button', { name: 'Confirm in wallet', exact: true }).click();
  await page.waitForFunction(id => { const panel = document.querySelector(`[data-action="${id}"]`); return !panel || panel.querySelector('.tx-result')?.textContent.includes('Transaction confirmed.'); }, action, { timeout: 25_000 });
}
try {
  const plain = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await plain.newPage(); const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(url); await page.getByRole('heading', { name: 'Challenge the king' }).waitFor();
  check('Unconfigured export labels deployment honestly', await page.getByText('Awaiting deployment', { exact: true }).isVisible());
  check('Unconfigured transaction remains disabled', await page.locator('[data-action="challenge"] > button').isDisabled());
  check('Main action appears above 844px on the 390px screen', (await page.locator('[data-action="challenge"] > button').boundingBox()).y + (await page.locator('[data-action="challenge"] > button').boundingBox()).height <= 844);
  await page.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  await page.getByRole('dialog', { name: 'Connect a wallet' }).waitFor();
  await page.getByRole('button', { name: 'Browser wallet', exact: true }).click();
  await page.getByText('No browser wallet was found.', { exact: false }).waitFor();
  check('Missing-wallet state explains how to connect');
  await page.keyboard.press('Escape');
  check('Wallet dialog restores keyboard focus', await page.getByRole('button', { name: 'Connect wallet', exact: true }).evaluate(e => e === document.activeElement));
  await page.screenshot({ path: resolve(shots, '390-pending.png'), fullPage: true });
  check('Static export has no browser script errors', errors.length === 0);
  await plain.close();

  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.exposeFunction('crownRpc', (method, params) => { try { return { result: rpc(method, params) }; } catch (error) { return { error }; } });
  await context.addInitScript(({ account }) => {
    let chain = '0x1'; let authorized = false; let added = false; const listeners = new Map();
    window.walletEvents = []; window.testChain = value => { chain = value; (listeners.get('chainChanged') ?? []).forEach(f => f(chain)); };
    const provider = { on(event, listener) { listeners.set(event, [...(listeners.get(event) ?? []), listener]); }, removeListener(event, listener) { listeners.set(event, (listeners.get(event) ?? []).filter(f => f !== listener)); },
      async request({ method, params }) {
        window.walletEvents.push(method);
        if (method === 'eth_chainId') return chain;
        if (method === 'eth_accounts') return authorized ? [account] : [];
        if (method === 'eth_requestAccounts') { authorized = true; return [account]; }
        if (method === 'wallet_switchEthereumChain') { if (!added) throw { code: 4902, message: 'Unknown chain' }; window.testChain(params[0].chainId); return null; }
        if (method === 'wallet_addEthereumChain') { added = true; return null; }
        if (method === 'wallet_requestPermissions') return [{ parentCapability: 'eth_accounts' }];
        if (method === 'wallet_revokePermissions') { authorized = false; return null; }
        const response = await window.crownRpc(method, params); if (response.error) throw response.error; return response.result;
      } };
    window.ethereum = provider;
    const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: { info: { uuid: 'd3224ad3-b67e-4c4b-bdc8-911c1a873baa', name: 'Crown test wallet', icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>', rdns: 'test.crown.wallet' }, provider } }));
    window.addEventListener('eip6963:requestProvider', announce); announce();
  }, { account: A.account });
  await context.route('**/crown-config.json', route => route.fulfill({ json: { ...config, contracts: [{ name: 'CrownHook', address: A.hook }, { name: 'CrownChallengerToken', address: A.challenger }] } }));
  await context.route('https://rpc.mainnet.chain.robinhood.com/**', async route => {
    const request = route.request().postDataJSON();
    const response = body => { try { return { jsonrpc: '2.0', id: body.id, result: rpc(body.method, body.params) }; } catch (error) { return { jsonrpc: '2.0', id: body.id, error }; } };
    await route.fulfill({ json: Array.isArray(request) ? request.map(response) : response(request) });
  });
  const p = await context.newPage(); p.on('pageerror', e => errors.push(e.message));
  await p.goto(url); await waitText(p, '.king-identity', 'CRWN king');
  check('Public reads load current king before connecting', await p.locator('.king-identity a').getAttribute('href') === `${config.explorerUrl}/address/${A.king}`);
  await p.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  await p.getByRole('button', { name: 'Crown test wallet', exact: true }).click();
  await p.getByRole('button', { name: 'Switch to Robinhood Chain', exact: true }).waitFor();
  check('Wrong chain blocks contract actions', await p.locator('[data-action="challenge"] > button').isDisabled());
  await p.getByRole('button', { name: 'Switch to Robinhood Chain', exact: true }).click();
  await p.waitForFunction(() => window.walletEvents.includes('wallet_addEthereumChain'));
  await p.waitForFunction(() => !document.querySelector('[data-action="challenge"] > button').disabled);
  check('Unknown chain uses add-chain then switches again', (await p.evaluate(() => window.walletEvents)).filter(x => x === 'wallet_switchEthereumChain').length === 2);
  await p.evaluate(() => scrollTo(0, 0));
  const connectedAction = await p.locator('[data-action="challenge"] > button').boundingBox();
  check('Connected challenge action is fully visible on the first screen', connectedAction.y + connectedAction.height <= 844);
  await p.locator('#candidate').fill('invalid'); await p.locator('[data-action="challenge"] > button').click();
  await waitText(p, '[data-action="challenge"]', 'Enter a valid'); check('Invalid address never reaches wallet signing', transactions.length === 0);
  check('Invalid address error is linked to its input', await p.locator('#candidate').getAttribute('aria-invalid') === 'true');
  await p.locator('#candidate').fill(A.king); await p.locator('[data-action="challenge"] > button').click();
  await waitText(p, '[data-action="challenge"]', 'different token');
  await p.locator('#candidate').fill(A.challenger);
  state.simulationError = 'ReignTooShort'; await p.locator('[data-action="challenge"] > button').click();
  await waitText(p, '[data-action="challenge"]', 'seven days'); check('Custom contract revert is translated before signing', transactions.length === 0); state.simulationError = '';
  state.rejectSend = true;
  await p.locator('#candidate').focus(); await p.keyboard.press('Tab');
  check('Keyboard tab reaches the primary action', await p.locator('[data-action="challenge"] > button').evaluate(e => e === document.activeElement));
  await p.screenshot({ path: resolve(shots, '390-keyboard-focus.png') });
  await p.keyboard.press('Enter'); await p.getByRole('dialog', { name: 'Review transaction' }).waitFor();
  await p.getByRole('button', { name: 'Go back', exact: true }).focus(); await p.keyboard.press('Tab');
  await p.locator('#ticker').evaluate(e => e.focus());
  check('Review dialog traps focus and reaches confirmation by keyboard', await p.getByRole('button', { name: 'Confirm in wallet', exact: true }).evaluate(e => e === document.activeElement));
  await p.keyboard.press('Enter');
  await waitText(p, '[data-action="challenge"]', 'declined'); check('Wallet rejection releases the action lock', await p.locator('[data-action="challenge"] > button').isEnabled());
  state.holdReceipt = true;
  await p.locator('[data-action="challenge"] > button').click();
  check('Transaction review names amount and beneficiary', await p.getByRole('dialog', { name: 'Review transaction' }).innerText().then(t => t.includes('0.01 ETH') && t.toLowerCase().includes(A.account)));
  await p.getByRole('button', { name: 'Confirm in wallet', exact: true }).click();
  await waitText(p, '[data-action="challenge"]', 'Waiting for confirmation');
  check('Action stays disabled after transaction hash', await p.locator('[data-action="challenge"] > button').isDisabled());
  check('Opening sends exact bond and ABI arguments', BigInt(transactions[0].value) === eth('0.01') && decodeFunctionData({ abi: abis.CrownRegistry, data: transactions[0].data }).args[0] === ticker);
  state.holdReceipt = false;
  await p.getByRole('heading', { name: 'Back your side' }).waitFor({ timeout: 25_000 });
  await p.screenshot({ path: resolve(shots, '390-active.png'), fullPage: true });
  const stakeBox = await p.locator('[data-action="stake"] > button').boundingBox();
  check('Active voting action remains on the first mobile screen', stakeBox.y + stakeBox.height <= 844);
  await p.locator('#stake-amount').fill('0.0000000000000000001'); await p.locator('[data-action="stake"] > button').click();
  await waitText(p, '[data-action="stake"]', '18 decimal places');
  check('Sub-wei input is rejected without rounding', transactions.length === 1);
  await p.locator('#stake-amount').fill('0.04');
  state.receiptError = true;
  await p.locator('[data-action="stake"] > button').click(); await p.getByRole('button', { name: 'Confirm in wallet', exact: true }).click();
  await p.getByRole('button', { name: 'Check confirmation', exact: true }).waitFor();
  check('Uncertain receipt does not allow a second submission', await p.locator('[data-action="stake"] > button').isDisabled());
  state.receiptError = false; await p.getByRole('button', { name: 'Check confirmation', exact: true }).click();
  await waitText(p, '[data-action="stake"] .tx-result', 'Transaction confirmed.');
  check('Receipt recovery confirms the original transaction', transactions.length === 2);
  check('Stake sends exact ETH amount and selected side', BigInt(transactions[1].value) === eth('0.04') && decodeFunctionData({ abi: abis.CrownRegistry, data: transactions[1].data }).args[1] === 1);
  await waitText(p, '.quorum-label', 'Quorum met');
  state.now = state.ends; await p.getByRole('button', { name: 'Refresh', exact: true }).click();
  await p.getByRole('heading', { name: 'Resolution timelock' }).waitFor();
  check('Staking closes exactly at boundary and finalize waits', await p.locator('[data-action="finalize"] > button').isDisabled() && await p.locator('[data-action="stake"]').count() === 0);
  state.now = state.finalAt; await p.getByRole('button', { name: 'Refresh', exact: true }).click();
  await p.getByRole('heading', { name: 'Resolve the challenge' }).waitFor(); await transact(p, 'finalize');
  await p.waitForFunction(address => document.querySelector('.king-identity a')?.href.toLowerCase().includes(address), A.challenger);
  check('Finalization refreshes crown token and beneficiary', state.king === A.challenger && (await p.locator('.king-facts').innerText()).includes('0x7000'));
  await transact(p, 'claim'); check('Finalized stake can be claimed with no ETH value', state.claimed && BigInt(transactions.at(-1).value ?? 0) === 0n);
  await p.locator('#lookup').fill('999'); await p.getByRole('button', { name: 'Look up', exact: true }).click();
  await waitText(p, '.detail-section', 'does not exist for CRWN'); check('Missing challenge cannot be claimed', await p.locator('[data-action="claim"] > button').isDisabled());
  await transact(p, 'approve-claims'); check('Claim authorization targets PoolManager and CrownHook', state.operator && transactions.at(-1).to.toLowerCase() === A.manager);
  await p.locator('#redeem-amount').fill('0.001'); await transact(p, 'redeem'); check('Fee claim redemption sends the requested native amount', state.claims === eth('0.002'));
  await transact(p, 'revoke-claims'); check('Claim operator authorization can be revoked', state.operator === false);
  await p.locator('.deployment-details > summary').filter({ hasText: 'Contracts & network' }).click(); await transact(p, 'treasury'); check('Treasury retry is wired to the registry', state.treasury === 0n);
  await p.locator('.owner-panel > summary').click();
  await p.locator('#pool-token').fill(A.challenger); await p.locator('#pool-bps').fill('501');
  await p.locator('[data-action="configure-pool"] > button').click(); await waitText(p, '[data-action="configure-pool"]', '0 to 500');
  await p.locator('#pool-bps').fill('125'); await transact(p, 'configure-pool');
  const poolArgs = decodeFunctionData({ abi: abis.CrownHook, data: transactions.at(-1).data }).args;
  check('Owner config uses the actual hook, native pair and launch fee', poolArgs[0].hooks.toLowerCase() === A.hook && poolArgs[0].currency0 === ZERO && poolArgs[0].fee === 12500 && poolArgs[2] === 125);
  await p.locator('[data-action="approve-claims"] > button').click(); await p.getByRole('dialog', { name: 'Review transaction' }).waitFor();
  await p.evaluate(() => window.testChain('0x1'));
  await p.getByRole('dialog', { name: 'Review transaction' }).waitFor({ state: 'hidden' });
  check('Network change cancels a prepared review', await p.locator('[data-action="approve-claims"] > button').isDisabled());
  await p.getByRole('button', { name: 'Switch to Robinhood Chain', exact: true }).click();
  state.failReads = true; await p.getByRole('button', { name: 'Refresh', exact: true }).click();
  await waitText(p, '.network-strip', 'Connection interrupted');
  check('Read failure disables transactions even with cached data', await p.locator('[data-action="approve-claims"] > button').isDisabled());
  state.failReads = false; await p.getByRole('button', { name: 'Refresh', exact: true }).click();
  await p.waitForFunction(() => !document.querySelector('[data-action="approve-claims"] > button').disabled);
  check('Successful refresh recovers after an RPC error');
  state.long = true; await p.getByRole('button', { name: 'Refresh', exact: true }).click();
  await p.waitForTimeout(200);
  for (const width of [320, 390, 768, 1440]) {
    await p.setViewportSize({ width, height: 1000 });
    check(`Longest uint256 totals do not overflow at ${width}px`, await p.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  }
  await p.screenshot({ path: resolve(shots, '1440-connected.png'), fullPage: true });
  state.registrationMode = true;
  await p.locator('#ticker').fill('test'); await p.getByRole('button', { name: 'Show ticker', exact: true }).click();
  await p.getByRole('heading', { name: 'Register the first king' }).waitFor();
  await p.locator('#register-token').fill(A.king); await p.locator('#register-beneficiary').fill(A.account); await transact(p, 'register');
  check('Ticker search normalizes case and registers an uncrowned ticker', state.registrations.has(keccak256(toBytes('TEST'))));
  check('No browser errors across mocked transactions', errors.length === 0);
  check('All RPC methods were handled', !calls.some(c => c === 'unhandled'));
  await context.close();

  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148', isMobile: true, hasTouch: true });
  const mp = await mobile.newPage(); await mp.goto(url); await mp.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  for (const name of ['MetaMask', 'Coinbase Wallet', 'Rabby', 'Phantom']) check(`Mobile opens ${name} at the current page`, await mp.getByRole('link', { name: `Open in ${name}`, exact: true }).isVisible());
  const rabby = new URL(await mp.getByRole('link', { name: 'Open in Rabby', exact: true }).getAttribute('href'));
  check('Rabby link follows its open-dapp command', rabby.searchParams.get('_cmd') === 'open-dapp' && rabby.searchParams.get('dapp') === url);
  check('Mobile includes Coinbase Smart Wallet', await mp.getByRole('button', { name: 'Coinbase Smart Wallet', exact: true }).isVisible());
  await mp.screenshot({ path: resolve(shots, '390-wallet.png') }); await mobile.close();
  console.log(`\n${results.length} interaction assertions passed. No real transactions broadcast.`);
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
