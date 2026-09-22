# Namedrop keeper

Moves fees out of the venue's escrow into the vaults they already belong to, where the
80/20 split happens. It decides **when**, never **where**.

`pullMany(address[])` takes a list of vaults and nothing else. There is no destination
argument anywhere in the path, so a stolen keeper key costs gas and cannot redirect a cent.
The factory also skips a vault that reverts rather than failing the batch, and reports it
as `PullFailed`, which this script surfaces as a `warn` line.

## Why a timer and not a daemon

It runs once and exits. A long-lived process can die quietly and still look alive to
anything that only checks for a PID; a timer that stops firing is visible in
`systemctl list-timers`, and a run that exits non-zero is visible in the journal.

## Why it runs on the host, not as a Coolify container

Every container on the `coolify` network can reach every other one, including the panel's
database, which holds the environment of every app on the box. The keeper holds a signing
key, so it stays off that network.

## Threshold

The batch goes out once the **sum** across all waiting vaults clears `THRESHOLD_WEI`
(default 0.1 ETH). This is not a gas saving: a batched pull across fifteen vaults costs
about $0.022, roughly $0.0015 a vault. It exists to keep the loop quiet when nothing is
trading, and so small accounts ride along with large ones rather than being stranded under
a per-vault minimum they could never reach on their own.

## Gas is set by formula, never by estimation

`pullMany` wraps each vault in try/catch so one bad vault cannot block the batch. The cost
of that is a trap: the **transaction** succeeds even when every inner pull runs out of gas.
`eth_estimateGas` searches for the cheapest gas where the transaction succeeds, so it
converges on an amount where the inner pulls fail and nothing moves.

Measured on a local fork, batch of three: estimate `316,641`, actual `322,814`. Sending at
the estimate produced a successful receipt, a `PullFailed` for every vault, and zero
movement. Left alone, the keeper would have burned gas on a schedule, logged success, and
paid nobody.

So the keeper computes `GAS_BASE + GAS_PER_VAULT * n` and only uses the RPC estimate when
it happens to be higher. If you change anything in `pull`, re-measure `gas_used` in the
logs before trusting the defaults.

## Install

```bash
# as root on the box
useradd --system --no-create-home --shell /usr/sbin/nologin namedrop
mkdir -p /opt/namedrop-keeper /etc/namedrop

rsync -a keeper/ root@host:/opt/namedrop-keeper/
cd /opt/namedrop-keeper && npm install --omit=dev

cp keeper/.env.example /etc/namedrop/keeper.env   # then fill it in
chown root:namedrop /etc/namedrop/keeper.env
chmod 640 /etc/namedrop/keeper.env

cp keeper/namedrop-keeper.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now namedrop-keeper.timer
```

## Verify, do not assume

```bash
DRY_RUN=1 node src/keeper.mjs        # scans and reports, signs nothing, needs no key
systemctl list-timers namedrop-keeper.timer
journalctl -u namedrop-keeper -n 50 --no-pager
```

A healthy quiet run logs `below threshold, nothing to do`. Silence is the expected state
when nothing is trading.

## What is not here yet

`pushMany` is not run on a schedule. Push sends a credited balance to the address an
account bound, is permissionless, and is currently left to the account itself or to anyone
willing to pay the gas. Automating it is a policy decision, not a technical one.
