// Only the pieces the keeper calls. Kept deliberately small: a keeper that can reach more
// of the protocol than it needs is a keeper whose key is worth more than it should be.

export const factoryAbi = [
  { type: "function", name: "ponsFeeEscrow", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "vaultCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "pullMany", stateMutability: "nonpayable",
    inputs: [{ name: "vaults", type: "address[]" }], outputs: [{ type: "uint256" }],
  },
  {
    type: "event", name: "VaultCreated",
    inputs: [
      { name: "handleId", type: "bytes32", indexed: true },
      { name: "vault", type: "address", indexed: true },
    ],
  },
  {
    type: "event", name: "PullFailed",
    inputs: [
      { name: "vault", type: "address", indexed: true },
      { name: "reason", type: "bytes", indexed: false },
    ],
  },
];

export const escrowAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
];
