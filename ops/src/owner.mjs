#!/usr/bin/env node
/**
 * Owner operations, with the guardrails the raw key does not have.
 *
 * The factory owner can do exactly three things. None of them can reach a vault balance,
 * and this tool cannot either. What it adds over `cast send` is refusing the mistakes that
 * are permanent or embarrassing: lowering the recipient share, pointing the treasury at
 * nothing, or handing ownership to an address with a typo in it.
 *
 * Nothing runs without --yes. A dry run is the default on purpose.
 *
 *   node src/owner.mjs show
 *   node src/owner.mjs set-treasury   0xNEW            [--yes]
 *   node src/owner.mjs set-recipient  8500            [--yes]
 *   node src/owner.mjs transfer-owner 0xMULTISIG      [--yes]
 */
import { createPublicClient, createWalletClient, http, defineChain, isAddress, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`missing env ${k}`); process.exit(1); } return v; };
const FACTORY = need("FACTORY");
const chain = defineChain({
  id: Number(process.env.CHAIN_ID ?? 4663), name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com"] } },
});

const abi = [
  { type:"function", name:"owner",            stateMutability:"view", inputs:[], outputs:[{type:"address"}] },
  { type:"function", name:"operator",         stateMutability:"view", inputs:[], outputs:[{type:"address"}] },
  { type:"function", name:"treasury",         stateMutability:"view", inputs:[], outputs:[{type:"address"}] },
  { type:"function", name:"recipientBps",     stateMutability:"view", inputs:[], outputs:[{type:"uint256"}] },
  { type:"function", name:"MIN_RECIPIENT_BPS",stateMutability:"view", inputs:[], outputs:[{type:"uint256"}] },
  { type:"function", name:"vaultCount",       stateMutability:"view", inputs:[], outputs:[{type:"uint256"}] },
  { type:"function", name:"setTreasury",      stateMutability:"nonpayable", inputs:[{name:"t",type:"address"}], outputs:[] },
  { type:"function", name:"setRecipientBps",  stateMutability:"nonpayable", inputs:[{name:"b",type:"uint256"}], outputs:[] },
  { type:"function", name:"transferOwnership",stateMutability:"nonpayable", inputs:[{name:"o",type:"address"}], outputs:[] },
];

const pc = createPublicClient({ chain, transport: http() });
const read = (fn) => pc.readContract({ address: FACTORY, abi, functionName: fn });

async function show() {
  const [owner, operator, treasury, bps, floor, vaults] = await Promise.all(
    ["owner","operator","treasury","recipientBps","MIN_RECIPIENT_BPS","vaultCount"].map(read));
  console.log(`factory        ${FACTORY}`);
  console.log(`owner          ${owner}`);
  console.log(`operator       ${operator}`);
  console.log(`treasury       ${treasury}`);
  console.log(`recipientBps   ${bps}  (lantai ${floor}, = ${Number(bps)/100}% ke penerima)`);
  console.log(`vaultCount     ${vaults}`);
  return { owner, treasury, bps, floor };
}

async function send(fn, args, label) {
  const account = privateKeyToAccount(need("OWNER_PK"));
  const onchainOwner = await read("owner");
  // The most common way to waste an hour: signing with a key that is not the owner.
  if (account.address.toLowerCase() !== onchainOwner.toLowerCase()) {
    console.error(`OWNER_PK is ${account.address}, but the factory's owner is ${onchainOwner}. Refusing.`);
    process.exit(1);
  }
  if (!process.argv.includes("--yes")) {
    console.log(`\nDRY RUN. ${label}\nAdd --yes to actually send it.`);
    return;
  }
  const wallet = createWalletClient({ account, chain, transport: http() });
  const hash = await wallet.writeContract({ address: FACTORY, abi, functionName: fn, args });
  const r = await pc.waitForTransactionReceipt({ hash });
  console.log(`\n${label}\ntx ${hash}  status ${r.status}`);
}

const addr = (s) => {
  if (!s || !isAddress(s)) { console.error(`"${s}" is not an address.`); process.exit(1); }
  return getAddress(s);
};

const [cmd, arg] = process.argv.slice(2);
const state = await show();

if (cmd === "show" || !cmd) {
  // nothing else
} else if (cmd === "set-treasury") {
  const t = addr(arg);
  if (t === getAddress(state.treasury)) { console.log("\nAlready that treasury. Nothing to do."); process.exit(0); }
  await send("setTreasury", [t], `setTreasury ${state.treasury} -> ${t}`);
} else if (cmd === "set-recipient") {
  const bps = BigInt(arg ?? "0");
  // The contract enforces the floor too. Failing here costs no gas and says why.
  if (bps < state.floor) { console.error(`\n${bps} is below MIN_RECIPIENT_BPS (${state.floor}). Refusing.`); process.exit(1); }
  if (bps > 10000n) { console.error(`\n${bps} is above 10000 bps. Refusing.`); process.exit(1); }
  if (bps < state.bps) console.log(`\nNOTE: this LOWERS the recipient share, ${state.bps} -> ${bps}.`);
  await send("setRecipientBps", [bps], `setRecipientBps ${state.bps} -> ${bps}`);
} else if (cmd === "transfer-owner") {
  const o = addr(arg);
  const code = await pc.getCode({ address: o });
  console.log(`\ntarget is ${code && code !== "0x" ? "a CONTRACT (multisig, good)" : "an EOA (single key)"}`);
  console.log("Two steps: this starts it, the new owner must call acceptOwnership() to finish.");
  await send("transferOwnership", [o], `transferOwnership ${state.owner} -> ${o}`);
} else {
  console.error(`unknown command: ${cmd}`);
  process.exit(1);
}
