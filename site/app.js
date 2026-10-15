/* global ethers, CROWN_CONFIG */
const HOOK_ABI = [
  "function registry() view returns (address)",
  "function crownPaid(bytes32 ticker, address currency) view returns (uint256)",
];
const REGISTRY_ABI = [
  "function king(bytes32) view returns (address kingToken, address beneficiary, uint64 reignStartedAt)",
  "function tickerTotals(bytes32) view returns (uint256 activeChallengeId, uint64 cooldownUntil, uint64 challenges, uint64 dethrones, uint256 totalStaked, uint256 totalSlashed)",
  "function challenges(uint256) view returns (bytes32 ticker, address challengerToken, address challengerBeneficiary, uint64 openedAt, uint64 stakingEndsAt, uint64 finalizableAt, bool finalized, bool challengerWon, uint256 kingStake, uint256 challengerStake, uint256, uint256, uint256, uint256)",
  "function claimable(uint256, address) view returns (uint256)",
  "function openChallenge(bytes32 ticker, address challengerToken) payable returns (uint256)",
  "function stake(uint256 challengeId, uint8 side) payable",
  "function finalize(uint256 challengeId)",
  "function claim(uint256 challengeId) returns (uint256)",
];
const MIN_REIGN = 7 * 86400;
const QUORUM = ethers.parseEther("0.05");
const BOND = ethers.parseEther("0.01");

const $ = (id) => document.getElementById(id);
const cfg = window.CROWN_CONFIG;
const reader = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId);
let signer = null;
let registryAddr = null;
let state = { ticker: null, challengeId: 0n, challenge: null };

const fmtTime = (s) => (Number(s) === 0 ? "—" : new Date(Number(s) * 1000).toLocaleString());
const fmtEth = (w) => ethers.formatEther(w);
const link = (a) => `<a href="${cfg.explorer}/address/${a}" target="_blank" rel="noopener">${a}</a>`;
const tickerOf = (sym) => ethers.keccak256(ethers.toUtf8Bytes(sym.toUpperCase()));
const status = (m) => ($("status").textContent = m);

function left(target) {
  const d = Number(target) - Math.floor(Date.now() / 1000);
  if (d <= 0) return "0s";
  const h = Math.floor(d / 3600), m = Math.floor((d % 3600) / 60), s = d % 60;
  return `${h}h ${m}m ${s}s`;
}

async function contracts(runner) {
  if (!cfg.hook) throw new Error("This page is not configured yet: set the CrownHook address in config.js after launch.");
  const hook = new ethers.Contract(cfg.hook, HOOK_ABI, runner);
  if (!registryAddr) registryAddr = await hook.registry();
  return { hook, registry: new ethers.Contract(registryAddr, REGISTRY_ABI, runner) };
}

async function load() {
  try {
    const sym = ($("ticker").value || cfg.defaultTicker).trim();
    $("ticker").value = sym;
    state.ticker = tickerOf(sym);
    $("t-symbol").textContent = sym.toUpperCase();
    const { hook, registry } = await contracts(reader);
    const [k, totals, paid] = await Promise.all([
      registry.king(state.ticker),
      registry.tickerTotals(state.ticker),
      hook.crownPaid(state.ticker, ethers.ZeroAddress),
    ]);
    const crowned = k.kingToken !== ethers.ZeroAddress;
    $("k-token").innerHTML = crowned ? link(k.kingToken) : "no king yet";
    $("k-benef").innerHTML = crowned ? link(k.beneficiary) : "—";
    $("k-since").textContent = crowned ? fmtTime(k.reignStartedAt) : "—";
    $("k-open").textContent = crowned ? fmtTime(Number(k.reignStartedAt) + MIN_REIGN) : "—";
    $("paid-eth").textContent = fmtEth(paid);
    $("tt-challenges").textContent = totals.challenges.toString();
    $("tt-dethrones").textContent = totals.dethrones.toString();
    $("tt-staked").textContent = fmtEth(totals.totalStaked);
    $("tt-slashed").textContent = fmtEth(totals.totalSlashed);
    $("tt-cooldown").textContent = fmtTime(totals.cooldownUntil);
    state.challengeId = totals.activeChallengeId;
    if (state.challengeId === 0n) {
      state.challenge = null;
      $("challenge").hidden = true;
      $("no-challenge").hidden = false;
    } else {
      state.challenge = await registry.challenges(state.challengeId);
      $("claim-id").value = state.challengeId.toString();
      renderChallenge();
    }
    status("Loaded from " + cfg.chainName + ".");
  } catch (e) {
    status(e.shortMessage || e.message);
  }
}

function renderChallenge() {
  const c = state.challenge;
  if (!c) return;
  $("challenge").hidden = false;
  $("no-challenge").hidden = true;
  $("c-id").textContent = state.challengeId.toString();
  $("c-token").innerHTML = link(c.challengerToken);
  $("c-benef").innerHTML = link(c.challengerBeneficiary);
  $("c-ends").textContent = fmtTime(c.stakingEndsAt);
  $("c-final").textContent = fmtTime(c.finalizableAt);
  const now = Math.floor(Date.now() / 1000);
  $("c-left").textContent = now < Number(c.stakingEndsAt)
    ? "staking: " + left(c.stakingEndsAt)
    : now < Number(c.finalizableAt) ? "timelock: " + left(c.finalizableAt) : "ready to finalize";
  $("c-kstake").textContent = fmtEth(c.kingStake);
  $("c-cstake").textContent = fmtEth(c.challengerStake);
  const total = c.kingStake + c.challengerStake;
  $("c-quorum").textContent = `${fmtEth(total)} / 0.05 ${total >= QUORUM ? "✓" : ""}`;
  const pk = total === 0n ? 50 : Number((c.kingStake * 1000n) / total) / 10;
  $("bar-k").style.width = pk + "%";
  $("bar-c").style.width = 100 - pk + "%";
  const wins = c.challengerStake > c.kingStake && total >= QUORUM;
  $("c-outcome").textContent = wins ? "challenger is crowned" : "king keeps the crown";
}

async function connect() {
  if (!window.ethereum) return status("No wallet found.");
  const provider = new ethers.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  const hex = "0x" + cfg.chainId.toString(16);
  try {
    await provider.send("wallet_switchEthereumChain", [{ chainId: hex }]);
  } catch (e) {
    await provider.send("wallet_addEthereumChain", [{
      chainId: hex, chainName: cfg.chainName, rpcUrls: [cfg.rpcUrl],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, blockExplorerUrls: [cfg.explorer],
    }]);
  }
  signer = await new ethers.BrowserProvider(window.ethereum).getSigner();
  $("connect").textContent = (await signer.getAddress()).slice(0, 8) + "…";
}

async function send(fn) {
  try {
    if (!signer) await connect();
    const { registry } = await contracts(signer);
    const tx = await fn(registry);
    status("Sent " + tx.hash + " …");
    await tx.wait();
    status("Confirmed " + tx.hash);
    await load();
  } catch (e) {
    status(e.shortMessage || e.reason || e.message);
  }
}

$("load").onclick = load;
$("connect").onclick = () => connect().catch((e) => status(e.message));
$("stake").onclick = () => send((r) => {
  if (state.challengeId === 0n) throw new Error("No live challenge.");
  return r.stake(state.challengeId, Number($("side").value), { value: ethers.parseEther($("stake-amt").value || "0") });
});
$("finalize").onclick = () => send((r) => {
  if (state.challengeId === 0n) throw new Error("No live challenge.");
  return r.finalize(state.challengeId);
});
$("claim").onclick = () => send((r) => r.claim(BigInt($("claim-id").value)));
$("claimable").onclick = async () => {
  try {
    if (!signer) await connect();
    const { registry } = await contracts(reader);
    const amt = await registry.claimable(BigInt($("claim-id").value), await signer.getAddress());
    $("claim-info").textContent = "Claimable: " + fmtEth(amt) + " ETH";
  } catch (e) { status(e.shortMessage || e.message); }
};
$("open").onclick = () => send((r) => r.openChallenge(state.ticker, $("ch-token").value.trim(), { value: BOND }));

setInterval(renderChallenge, 1000);
load();
