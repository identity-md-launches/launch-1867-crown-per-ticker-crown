import { BaseError, ContractFunctionRevertedError, formatEther, getAddress, isAddress, parseEther, type Address } from 'viem';
import { RULES, ZERO } from './config';

export type King = readonly [Address, Address, number];
export type Totals = readonly [bigint, number, bigint, bigint, bigint, bigint];
export type Challenge = readonly [string, Address, Address, number, number, number, boolean, boolean, bigint, bigint, bigint, bigint, bigint, bigint];
export const short = (address: string) => `${getAddress(address).slice(0, 6)}…${getAddress(address).slice(-4)}`;
export function eth(value: bigint | undefined, max = 6) {
  if (value === undefined) return 'Not loaded';
  const text = formatEther(value);
  const [whole, fraction = ''] = text.split('.');
  if (value > 0n && value < 10n ** BigInt(18 - max)) return `<0.${'0'.repeat(max - 1)}1`;
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')}${fraction.slice(0, max).replace(/0+$/, '') ? `.${fraction.slice(0, max).replace(/0+$/, '')}` : ''}`;
}
export function amount(input: string): bigint {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(input.trim())) throw new Error('Enter an ETH amount with up to 18 decimal places.');
  const value = parseEther(input.trim());
  if (value <= 0n || value >= 2n ** 256n) throw new Error('Enter an ETH amount greater than zero and within the supported range.');
  return value;
}
export function addressInput(input: string): Address {
  const value = input.trim();
  if (!isAddress(value) || value.toLowerCase() === ZERO) throw new Error('Enter a valid, nonzero token or wallet address.');
  return getAddress(value);
}
export function challengeId(input: string): bigint {
  if (!/^[1-9]\d*$/.test(input) || BigInt(input) >= 2n ** 256n) throw new Error('Enter a positive challenge number.');
  return BigInt(input);
}
export function phase(c: Challenge | undefined, now: number) {
  if (!c || !Number(c[3])) return 'none';
  if (c[6]) return 'finalized';
  if (now < Number(c[4])) return 'staking';
  if (now < Number(c[5])) return 'timelock';
  return 'ready';
}
export function remaining(until: number, now: number) {
  const seconds = Math.max(0, Math.ceil(until - now));
  const days = Math.floor(seconds / 86400), hours = Math.floor(seconds % 86400 / 3600), minutes = Math.floor(seconds % 3600 / 60);
  return days ? `${days}d ${hours}h` : hours ? `${hours}h ${minutes}m` : `${minutes}m ${seconds % 60}s`;
}
// The registry's own gate: challengeableAt (seven days after registration or a defended dethroning) or the cooldown.
export function opensAt(challengeableAt: number | bigint, totals: Totals) { return Math.max(Number(challengeableAt), Number(totals[1])); }
export const date = (time: number) => new Intl.DateTimeFormat('en', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }).format(Number(time) * 1000) + ' UTC';
const errors: Record<string, string> = {
  AlreadyCrowned: 'This ticker already has a king. Refresh to see it.', NoKing: 'Register a king before opening a challenge.',
  TickerMismatch: 'The token must report the same symbol as this ticker.', WrongBond: 'Opening a challenge requires exactly 0.01 ETH.',
  ChallengeLive: 'A challenge is already open. Stake in it or wait for resolution.', ReignTooShort: 'The king must reign for seven days before a challenge.',
  CoolingDown: 'The three-day cooldown is still active. Wait until the displayed opening time.', SameToken: 'Choose a different token with the same ticker.',
  SelfChallenge: 'The current beneficiary cannot challenge its own crown. Use a different wallet, or wait to be challenged.',
  PartialFill: 'The pool could not fill the whole amount at that price limit, so the swap was refused rather than over-charged. Lower the amount or widen the limit.',
  AmountTooLarge: 'That amount is larger than any pool can trade. Enter a smaller amount.', TickerTaken: 'Another token already holds this ticker. Configure the pool explicitly or challenge for the ticker first.',
  UnknownChallenge: 'That challenge does not exist. Check its number.', StakingClosed: 'Staking has closed. Wait for the timelock to end.',
  ZeroStake: 'Enter an ETH amount greater than zero.', TimelockActive: 'The timelock is still active. Wait for the finalization time.',
  AlreadyFinalized: 'This challenge is already finalized. Refresh to view your refund.', NotFinalized: 'Finalize this challenge before claiming.',
  AlreadyClaimed: 'This wallet has already claimed its refund.', NothingToClaim: 'This wallet has no refund to claim.',
  TransferFailed: 'The receiving wallet could not accept ETH. Try a compatible wallet.', NotOwner: 'Only the hook owner can configure a new pool.',
  PoolAlreadyLive: 'Live pools cannot be reconfigured.', BpsTooHigh: 'Use a fee between 0 and 500 basis points.',
  ZeroAddress: 'Enter a nonzero token or beneficiary address.', WrongHook: 'The pool must use this CrownHook.',
  ZeroTicker: 'Enter a valid ticker before configuring the pool.', Reentrancy: 'A conflicting action is in progress. Refresh and retry.',
};
export function explain(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk(e => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError;
    if (reverted?.data?.errorName) return errors[reverted.data.errorName] ?? `The contract refused this action (${reverted.data.errorName}). Refresh and check the details.`;
  }
  const message = error instanceof Error ? error.message : String(error);
  if (/provider.*not found|no.*provider/i.test(message)) return 'No browser wallet was found. Choose Coinbase Wallet, or open this page inside a wallet app.';
  if (/reject|denied|4001/i.test(message)) return 'Request declined in your wallet. You can try again.';
  if (/insufficient funds|exceeds.*balance/i.test(message)) return 'Your wallet needs enough ETH for the amount and network gas.';
  if (/chain|network/i.test(message)) return 'Network mismatch or connection failure. Check the network, then retry.';
  if (/timeout|fetch|http|rpc|connection/i.test(message)) return 'Could not reach the network. Check your connection and retry.';
  return error instanceof Error && message.length < 190 ? message : 'The request did not complete. Refresh the state and try again.';
}
