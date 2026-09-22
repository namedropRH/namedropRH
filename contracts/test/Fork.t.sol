// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DropVault} from "../src/DropVault.sol";
import {DropVaultFactory} from "../src/DropVaultFactory.sol";
import {IPonsFactoryFull, IPonsCurve} from "../src/interfaces/IPons.sol";

/**
 * Runs the vault against the launchpad's REAL contracts on a fork of Robinhood Chain.
 *
 *     forge test --match-contract Fork --fork-url robinhood -vv
 *
 * Nothing here is mocked — the factory, the curve and the escrow are the deployed ones.
 * This is what closes Phase 0: it proves on-chain that a 2% creator tax reaches a CONTRACT
 * recipient, and that the numbers printed on the landing page are the numbers the venue
 * actually produces.
 */
contract ForkTest is Test {
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    uint16 constant CREATOR_TAX_BPS = 200; // our 2%, on top of the venue's fixed 1% base

    DropVaultFactory factory;
    DropVault vault;
    address token;
    address curve;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address launcher = makeAddr("launcher");
    address trader = makeAddr("trader");

    bytes32 constant HANDLE = bytes32(uint256(1234567890));

    modifier onFork() {
        if (block.chainid != 4663) {
            console2.log("skipped: not on a Robinhood Chain fork");
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        factory = new DropVaultFactory(owner, operator, treasury, 8000, ESCROW);
        vault = DropVault(payable(factory.createVault(HANDLE)));

        vm.deal(launcher, 10 ether);
        vm.deal(trader, 200 ether);

        IPonsFactoryFull pons = IPonsFactoryFull(PONS);
        IPonsFactoryFull.TokenParams memory p;
        p.name = "Namedrop Fork Test";
        p.symbol = "NDFT";
        p.logo = "";
        p.description = "Fees to an account via Namedrop";
        p.creatorFeeRecipient = address(vault); // the vault, before anyone is bound to it
        p.creatorTaxBps = CREATOR_TAX_BPS;
        p.buybackEnabled = false;
        p.expectedEconomics = pons.previewLaunchEconomics(0, address(0));
        p.salt = keccak256("namedrop-fork");

        address[] memory none = new address[](0);
        vm.prank(launcher);
        (token, curve) = pons.launchToken{value: pons.launchFee()}(p, 0, address(0), none);
    }

    /// The venue accepts a CONTRACT as creator fee recipient — the whole design depends on it.
    function test_theVenueAcceptsAVaultAsFeeRecipient() public onFork {
        assertTrue(token != address(0), "token deployed");
        assertTrue(curve != address(0), "curve deployed");
        console2.log("token", token);
        console2.log("curve", curve);
    }

    /// Trade, sweep, pull — and check the split against the numbers on the landing page.
    function test_feesReachTheVaultAndSplitEightyTwenty() public onFork {
        // The venue's snipe restriction is measured in L1 blocks; trades inside the window
        // revert or are taxed. Roll past it before measuring anything.
        vm.roll(block.number + 400);
        vm.warp(block.timestamp + 90 minutes);

        // Stay under the venue's 4.2 ETH graduation threshold: past it the curve is done
        // and fees move to the Uniswap hook, which is a different sweep path.
        (uint256 qBefore,) = IPonsCurve(curve).getReserves();
        uint256 spend = 1 ether;
        vm.prank(trader);
        uint256 out = IPonsCurve(curve).buy{value: spend}(spend, 0, trader);
        (uint256 qAfter,) = IPonsCurve(curve).getReserves();
        console2.log("tokens out", out);
        console2.log("quote reserve moved", qAfter - qBefore);
        assertGt(out, 0, "the trade must actually execute");
        assertFalse(IPonsCurve(curve).graduated(), "still on the curve");

        // The venue lets the creator fee recipient sweep, and that is the vault — so the
        // sweep goes through the vault, and anyone may trigger it.
        vm.prank(makeAddr("anyone"));
        vault.sweepCurveFees(curve, 0);

        uint256 inEscrow = vault.pendingInEscrow(ESCROW);
        console2.log("credited to the vault in escrow (wei)", inEscrow);
        assertGt(inEscrow, 0, "the venue credited our contract");

        vault.pull(ESCROW); // permissionless
        uint256 owed = vault.claimable(address(0));
        uint256 got = treasury.balance;

        console2.log("to the account (wei)", owed);
        console2.log("to the protocol (wei)", got);
        assertEq(owed + got, inEscrow, "nothing is lost in the split");
        assertApproxEqRel(owed, (inEscrow * 8000) / 10000, 1e12, "80% to the account");
        assertApproxEqRel(got, (inEscrow * 2000) / 10000, 1e12, "20% to the protocol");

        // These three assertions ARE the landing page. If the venue ever changes its base
        // fee or its cut of it, this test fails and the page stops being true.
        uint256 bpsOfSpend = (inEscrow * 10_000) / spend;
        uint256 accountBps = (owed * 10_000) / spend;
        uint256 protocolBps = (got * 10_000) / spend;
        console2.log("reached the vault, in bps of spend", bpsOfSpend);
        console2.log("to the account, in bps of spend", accountBps);
        console2.log("to the protocol, in bps of spend", protocolBps);
        assertEq(bpsOfSpend, 270, "2.70% reaches the vault (1% base less the venue's 30%, plus the 2% tax)");
        assertEq(accountBps, 216, "2.16% to the named account");
        assertEq(protocolBps, 54, "0.54% to the protocol");
    }

    /// And the money still leaves only by the account's own signature.
    function test_onlyTheBoundAccountCanTakeItOut() public onFork {
        vm.roll(block.number + 400);
        vm.warp(block.timestamp + 90 minutes);
        vm.prank(trader);
        IPonsCurve(curve).buy{value: 1 ether}(1 ether, 0, trader);
        vault.sweepCurveFees(curve, 0);
        vault.pull(ESCROW);

        vm.prank(owner);
        vm.expectRevert(DropVault.NotBeneficiary.selector);
        vault.claim(address(0), owner);

        address account = makeAddr("account");
        vm.prank(operator);
        vault.requestBind(account);
        vm.warp(block.timestamp + 48 hours);
        vault.executeBind();

        uint256 owed = vault.claimable(address(0));
        vault.push(address(0)); // anyone may trigger; destination is fixed
        assertEq(account.balance, owed, "paid to the bound address only");
    }
}
