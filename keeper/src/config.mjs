import { defineChain } from "viem";

const req = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
};

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RPC_URL ?? "https://rpc.robinhood.com"] } },
});

export const FACTORY = req("FACTORY");
export const FACTORY_BLOCK = BigInt(process.env.FACTORY_BLOCK ?? "0");

/**
 * The batch only goes out once the SUM across every waiting vault clears this.
 *
 * Not a gas saving. A batched pull across fifteen vaults costs about $0.022 on this chain,
 * roughly $0.0015 a vault, which is noise. The threshold exists so the loop stays quiet when
 * nothing is trading, and so small accounts ride along with large ones instead of being
 * stranded under a per-vault minimum they can never reach.
 */
export const THRESHOLD_WEI = BigInt(process.env.THRESHOLD_WEI ?? "100000000000000000"); // 0.1 ETH

/** Vaults per transaction. Large batches are cheap here, but a revert wastes the whole call. */
export const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? "40");

/** Blocks per getLogs window. Public RPCs usually cap the range. */
export const LOG_WINDOW = BigInt(process.env.LOG_WINDOW ?? "9000");

/**
 * Gas is set from a formula, NOT from eth_estimateGas. This is not belt and braces, it is
 * load bearing.
 *
 * pullMany wraps each vault in try/catch so one bad vault cannot block the batch. That also
 * means the TRANSACTION succeeds when every inner pull runs out of gas. Estimation searches
 * for the cheapest gas where the transaction succeeds, so it converges on an amount where
 * the inner pulls fail and nothing moves. Measured on a local fork: estimate 316,641 for a
 * batch of three, actual cost 322,814. The keeper would have burned gas on a nightly
 * schedule, logged success, and paid nobody.
 *
 * Measured about 97.6k a vault. The default leaves room for a real escrow claim and a
 * treasury transfer that may fail and defer.
 */
export const GAS_BASE = BigInt(process.env.GAS_BASE ?? "60000");
export const GAS_PER_VAULT = BigInt(process.env.GAS_PER_VAULT ?? "160000");

export const DRY_RUN = process.env.DRY_RUN === "1";

/** Only read when the keeper actually intends to send. A dry run needs no key at all. */
export const keeperKey = () => req("KEEPER_PK");
