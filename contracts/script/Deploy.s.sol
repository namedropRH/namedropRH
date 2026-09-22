// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DropVaultFactory} from "../src/DropVaultFactory.sol";

/**
 * Deploys the factory. Nothing here is a secret; the addresses below are the venue's
 * published ones on Robinhood Chain.
 *
 *   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast \
 *     --private-key $DEPLOYER_PK --verify
 *
 * OWNER should be a multisig, not the key that signs the deploy, and it should be
 * transferred as the last step of going live. The owner can only point the PROTOCOL's
 * own cut and raise the recipient's share — it can never reach a vault balance.
 */
contract Deploy is Script {
    address constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    function run() external {
        address owner = vm.envAddress("NAMEDROP_OWNER");
        address operator = vm.envAddress("NAMEDROP_OPERATOR");
        address treasury = vm.envAddress("NAMEDROP_TREASURY");
        uint256 recipientBps = vm.envOr("NAMEDROP_RECIPIENT_BPS", uint256(8000));

        vm.startBroadcast();
        DropVaultFactory factory =
            new DropVaultFactory(owner, operator, treasury, recipientBps, PONS_FEE_ESCROW);
        vm.stopBroadcast();

        console2.log("DropVaultFactory", address(factory));
        console2.log("implementation  ", factory.implementation());
        console2.log("recipientBps    ", factory.recipientBps());
    }
}
