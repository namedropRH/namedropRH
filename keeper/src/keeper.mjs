#!/usr/bin/env node
/**
 * Namedrop keeper.
 *
 * Moves fees out of the venue's escrow and into the vaults they already belong to, then lets
 * the vault split them 80/20. It decides WHEN, never WHERE: pullMany takes a list of vaults
 * and nothing else, so a compromised keeper key costs gas and cannot redirect a cent.
 *
 * Runs once and exits, so a systemd timer or cron owns the schedule rather than a daemon
 * that can quietly die and look alive.
 */
import { createPublicClient, createWalletClient, http, formatEther, parseEventLogs } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { factoryAbi, escrowAbi } from "./abi.mjs";
import { robinhood, FACTORY, FACTORY_BLOCK, THRESHOLD_WEI, BATCH_SIZE, LOG_WINDOW, DRY_RUN, GAS_BASE, GAS_PER_VAULT, keeperKey } from "./config.mjs";

const log = (level, msg, extra = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), level, msg, ...extra }));

const publicClient = createPublicClient({ chain: robinhood, transport: http() });

/** Every vault the factory has ever created, from its own events. There is no on-chain list. */
async function findVaults(toBlock) {
  const vaults = new Set();
  for (let from = FACTORY_BLOCK; from <= toBlock; from += LOG_WINDOW + 1n) {
    const to = from + LOG_WINDOW > toBlock ? toBlock : from + LOG_WINDOW;
    const logs = await publicClient.getLogs({
      address: FACTORY,
      event: factoryAbi.find((a) => a.name === "VaultCreated"),
      fromBlock: from,
      toBlock: to,
    });
    for (const l of logs) vaults.add(l.args.vault);
  }
  return [...vaults];
}

async function main() {
  const head = await publicClient.getBlockNumber();
  const escrow = await publicClient.readContract({ address: FACTORY, abi: factoryAbi, functionName: "ponsFeeEscrow" });

  const vaults = await findVaults(head);
  if (vaults.length === 0) {
    log("info", "no vaults yet", { head: String(head) });
    return;
  }

  // Fail loudly here rather than letting every balance read return "0x" and look like a
  // contract bug. Usually means the factory points at the wrong escrow, or wrong chain.
  const escrowCode = await publicClient.getCode({ address: escrow });
  if (!escrowCode || escrowCode === "0x") {
    log("error", "no contract at the venue escrow", { escrow });
    process.exitCode = 1;
    return;
  }

  // One unreadable vault must not strand every other one. pullMany itself skips a vault
  // that reverts instead of failing the batch, and the scan ahead of it behaves the same.
  const reads = await Promise.allSettled(
    vaults.map((v) => publicClient.readContract({ address: escrow, abi: escrowAbi, functionName: "balanceOf", args: [v] })),
  );

  const unreadable = [];
  const waiting = [];
  reads.forEach((r, i) => {
    if (r.status === "fulfilled") {
      if (r.value > 0n) waiting.push({ vault: vaults[i], wei: r.value });
    } else {
      unreadable.push(vaults[i]);
    }
  });
  waiting.sort((a, b) => (b.wei > a.wei ? 1 : -1));

  if (unreadable.length) {
    log("warn", "some balances could not be read", { count: unreadable.length, vaults: unreadable.slice(0, 10) });
  }
  // Every read failing is an infrastructure problem, not a quiet day.
  if (unreadable.length === vaults.length) {
    log("error", "no balance could be read at all", { escrow });
    process.exitCode = 1;
    return;
  }

  const total = waiting.reduce((s, v) => s + v.wei, 0n);
  log("info", "scanned", {
    vaults: vaults.length,
    waiting: waiting.length,
    total: formatEther(total),
    threshold: formatEther(THRESHOLD_WEI),
  });

  if (total < THRESHOLD_WEI) {
    log("info", "below threshold, nothing to do");
    return;
  }

  if (DRY_RUN) {
    log("info", "dry run, not sending", { would_pull: waiting.length });
    return;
  }

  const account = privateKeyToAccount(keeperKey());
  const wallet = createWalletClient({ account, chain: robinhood, transport: http() });

  // A hot key with no gas is the single most likely way this loop dies silently.
  const gas = await publicClient.getBalance({ address: account.address });
  if (gas === 0n) {
    log("error", "keeper wallet has no gas", { keeper: account.address });
    process.exitCode = 1;
    return;
  }

  for (let i = 0; i < waiting.length; i += BATCH_SIZE) {
    const batch = waiting.slice(i, i + BATCH_SIZE).map((v) => v.vault);

    // Never let viem estimate this. See the note on GAS_BASE: pullMany swallows inner
    // failures, so the estimator returns an amount where nothing actually moves.
    const formula = GAS_BASE + GAS_PER_VAULT * BigInt(batch.length);
    let gasLimit = formula;
    try {
      const estimated = await publicClient.estimateContractGas({
        address: FACTORY, abi: factoryAbi, functionName: "pullMany", args: [batch], account,
      });
      if (estimated > gasLimit) gasLimit = estimated;
    } catch {
      // An estimate that will not even compute is not a reason to skip the batch.
    }

    const hash = await wallet.writeContract({ address: FACTORY, abi: factoryAbi, functionName: "pullMany", args: [batch], gas: gasLimit });
    const rcpt = await publicClient.waitForTransactionReceipt({ hash });

    // pullMany never reverts on one bad vault, it reports and moves on. Surface that or a
    // vault could sit permanently unpaid while the loop keeps reporting success.
    const failed = parseEventLogs({ abi: factoryAbi, eventName: "PullFailed", logs: rcpt.logs });
    log(failed.length ? "warn" : "info", "pulled", {
      tx: hash,
      batch: batch.length,
      status: rcpt.status,
      gas_limit: String(gasLimit),
      gas_used: String(rcpt.gasUsed),
      failed: failed.map((f) => f.args.vault),
    });
  }
}

main().catch((e) => {
  log("error", "keeper failed", { err: String(e?.shortMessage ?? e?.message ?? e) });
  process.exit(1);
});
