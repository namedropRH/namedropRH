// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DropVault} from "../src/DropVault.sol";
import {DropVaultFactory} from "../src/DropVaultFactory.sol";
import {IPonsFactoryFull, IPonsCurve} from "../src/interfaces/IPons.sol";

/**
 * Seeds an anvil fork of Robinhood Chain with REAL activity so the web app has genuine
 * data to render: deploys the factory, creates two vaults, launches two real venue coins
 * naming them (2% creator tax), trades, sweeps, pulls. Nothing is faked — the numbers the
 * board shows afterwards are the venue's own arithmetic.
 *
 *   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545 &
 *   forge script script/Seed.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *
 * (that key is anvil's published default account #0 — it holds nothing on any real chain)
 */
contract Seed is Script {
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    function run() external {
        uint256 pk = vm.envOr("SEED_PK", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        DropVaultFactory factory = new DropVaultFactory(me, me, me, 8000, ESCROW);
        console2.log("FACTORY", address(factory));
        console2.log("FACTORY_BLOCK", block.number);

        // two accounts, by numeric id (these are illustrative ids, not real accounts)
        bytes32 idA = bytes32(uint256(1000000001));
        bytes32 idB = bytes32(uint256(1000000002));
        DropVault a = DropVault(payable(factory.createVault(idA)));
        DropVault b = DropVault(payable(factory.createVault(idB)));

        (address tokA, address curveA) = _launch(address(a), "Whitfield Coin", "DWF", "Fees to @danawhitfield via Namedrop");
        (address tokB, address curveB) = _launch(address(b), "Ely Coin", "ELY", "Fees to @marcusely via Namedrop");
        console2.log("TOKEN_A", tokA);
        console2.log("TOKEN_B", tokB);
        vm.stopBroadcast();

        // trades happen after the snipe window; anvil lets us jump
        vm.roll(block.number + 400);
        vm.warp(block.timestamp + 90 minutes);

        vm.startBroadcast(pk);
        IPonsCurve(curveA).buy{value: 1.5 ether}(1.5 ether, 0, me);
        IPonsCurve(curveB).buy{value: 0.4 ether}(0.4 ether, 0, me);
        a.sweepCurveFees(curveA, 0);
        b.sweepCurveFees(curveB, 0);
        address[] memory vs = new address[](2);
        vs[0] = address(a); vs[1] = address(b);
        factory.pullMany(vs);
        // leave B's second trade unswept so the board shows "still in escrow" as a real number
        IPonsCurve(curveB).buy{value: 0.2 ether}(0.2 ether, 0, me);
        b.sweepCurveFees(curveB, 0);
        vm.stopBroadcast();

        console2.log("A claimable", a.claimable(address(0)));
        console2.log("B claimable", b.claimable(address(0)));
        console2.log("B in escrow", b.pendingInEscrow(ESCROW));
    }

    function _launch(address vault, string memory name, string memory sym, string memory desc)
        internal returns (address token, address curve)
    {
        IPonsFactoryFull pons = IPonsFactoryFull(PONS);
        IPonsFactoryFull.TokenParams memory p;
        p.name = name; p.symbol = sym; p.description = desc;
        p.creatorFeeRecipient = vault;
        p.creatorTaxBps = 200;
        p.expectedEconomics = pons.previewLaunchEconomics(0, address(0));
        p.salt = keccak256(bytes(sym));
        address[] memory none = new address[](0);
        (token, curve) = pons.launchToken{value: pons.launchFee()}(p, 0, address(0), none);
    }
}
