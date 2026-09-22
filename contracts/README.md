# Namedrop contracts

One vault per social account. A launch names the vault as its creator fee recipient; the
vault splits what arrives and holds the account's share until that account signs for it.

## The point

The protocol cannot move a recipient's balance. Not the owner, not the operator, not the
treasury, not a compromised key. Money leaves a vault three ways and there is no fourth:

| exit | who | destination |
|---|---|---|
| `claim` | the bound account | chosen by the signer |
| `claimWithSig` | the bound account signs, anyone submits | chosen by the signer |
| `push` | anyone | **the bound address — not a parameter** |

Absent by design: `settleOffchain`, `rescue`, `sweep` of the recipient share, `expire`,
`pause`, and any proxy. `test/NoAdminExit.t.sol` asserts all of it, including that those
selectors are not in the ABI. If someone adds a settlement path, that file fails.

## Layout

```
src/DropVault.sol          one clone per account
src/DropVaultFactory.sol   deterministic addresses, batched pulls, the 50% split floor
src/interfaces/IPons.sol   only what we call on the venue
test/NoAdminExit.t.sol     the promise, as tests
test/DropVault.t.sol       behaviour: splits, exits, binding
test/Fork.t.sol            the real venue, on a fork of Robinhood Chain
```

## First, the dependency

`forge-std` is not vendored here. Pull it once:

```bash
forge install foundry-rs/forge-std
```

## Running

```bash
forge test                                              # 28 local tests
forge test --match-contract Fork --fork-url robinhood    # 3 against the live venue
```

## What the fork test establishes

Launching on the real venue with a 2% creator tax, and a contract as fee recipient:

```
trader spends        1.0000 ETH
reaches the vault    0.0270 ETH   2.70%   (1% base less the venue's 30%, plus the 2% tax)
  named account      0.0216 ETH   2.16%
  protocol           0.0054 ETH   0.54%
```

Those three figures are asserted exactly, so if the venue changes its base fee or its share
of it, the test fails and the landing page stops being true.

## Two things the fork test taught us

1. **The venue records the creator FEE RECIPIENT as the curve's `deployer`.** So the vault,
   not the launcher, is who may sweep fees off a curve. `sweepCurveFees` exposes that to
   everyone — a sweep only moves money toward the account it belongs to, and the venue
   blocks the path itself when an internal swap would make the slippage floor worth gaming.
2. **A clone starts with every storage slot at zero.** A reentrancy guard initialised to `1`
   in the implementation's constructor leaves every clone permanently locked. The guard
   here treats `0` as unlocked.

## Deploying

```bash
NAMEDROP_OWNER=0x…      # a multisig
NAMEDROP_OPERATOR=0x…   # the key that requests binds; it can do nothing else
NAMEDROP_TREASURY=0x…
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
```

Transfer ownership to the multisig as the last step.

## Known risk, disclosed

The venue's owner can reroute any coin's creator fee recipient after a three-day timelock,
and the current recipient cannot veto it. That applies to every coin on the venue, including
ours. Money already inside a vault is untouchable by it; future fees are not.
