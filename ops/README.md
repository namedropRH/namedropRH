# Owner operations

The factory owner can do three things, and this is the only tool that should do them.

```
docker run --rm --env-file /etc/namedrop/owner.env namedrop-ops show
docker run --rm --env-file /etc/namedrop/owner.env namedrop-ops set-treasury 0xNEW --yes
docker run --rm --env-file /etc/namedrop/owner.env namedrop-ops set-recipient 8500 --yes
docker run --rm --env-file /etc/namedrop/owner.env namedrop-ops transfer-owner 0xSAFE --yes
```

Without `--yes` every command is a dry run that prints what it would do. `show` needs no key.

## What it refuses

- Signing with a key that is not the on-chain owner. This is the mistake that wastes an hour.
- A recipient share below `MIN_RECIPIENT_BPS`, which the contract would reject anyway, and
  above 10000, which it would not but which is nonsense.
- An address that is not an address.

It also says out loud whether a `transfer-owner` target is a contract or a single key, since
handing a protocol to an EOA by accident looks identical to doing it on purpose.

## What it cannot do

Reach a vault balance. No owner function can. That is the point of the protocol, and this
tool inherits it rather than being trusted with it.

## The key

`OWNER_PK` lives in `/etc/namedrop/owner.env`, root owned, mode 600, and is read only by
`docker run --env-file` at the moment a command runs. Nothing keeps it resident: there is no
service, no timer, and no container left running with it in the environment.

Keeping this key on the server is a deliberate trade the user made: convenience over the
cold-key advantage it had before. It is the only key in the system with permanent authority,
so it stays out of every image and every container that serves traffic.
