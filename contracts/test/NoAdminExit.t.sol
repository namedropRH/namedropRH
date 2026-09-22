// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DropVault} from "../src/DropVault.sol";
import {DropVaultFactory} from "../src/DropVaultFactory.sol";
import {MockEscrow} from "./Mocks.sol";

/**
 * The promise on the landing page is not a slogan, it is a property of the bytecode:
 * no key, no role and no sequence of calls moves a recipient's balance to the protocol.
 * These tests are the proof. If someone ever adds a settlement path, this file fails.
 */
contract NoAdminExitTest is Test {
    DropVaultFactory factory;
    DropVault vault;
    MockEscrow escrow;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address account = makeAddr("account");
    address attacker = makeAddr("attacker");
    bytes32 constant HANDLE = bytes32(uint256(1234567890));

    function setUp() public {
        escrow = new MockEscrow();
        factory = new DropVaultFactory(owner, operator, treasury, 8000, address(escrow));
        vault = DropVault(payable(factory.createVault(HANDLE)));
        escrow.credit{value: 10 ether}(address(vault));
        vault.pull(address(escrow));
        assertEq(vault.claimable(address(0)), 8 ether, "80% must be credited to the account");
        assertEq(treasury.balance, 2 ether, "20% must reach the treasury");
    }

    /// The whole thesis: the ABI contains no settlement, rescue, sweep, expiry or pause.
    function test_theAbiHasNoAdminExit() public {
        string[9] memory forbidden = [
            "settleOffchain(address,uint256,bytes32)",
            "rescue(address,uint256)",
            "sweep(address)",
            "sweepTo(address,address)",
            "expire(address)",
            "pause()",
            "unpause()",
            "adminWithdraw(address,uint256)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            bytes4 sel = bytes4(keccak256(bytes(forbidden[i])));
            (bool ok,) = address(vault).call(abi.encodePacked(sel));
            assertFalse(ok, forbidden[i]);
        }
    }

    /// Owner, operator and treasury each try every exit they can reach. None moves the money.
    function test_noRoleCanTakeTheRecipientShare() public {
        uint256 before = vault.claimable(address(0));
        address[3] memory roles = [owner, operator, treasury];
        for (uint256 i = 0; i < roles.length; i++) {
            vm.startPrank(roles[i]);
            vm.expectRevert(DropVault.NotBeneficiary.selector);
            vault.claim(address(0), roles[i]);
            vm.expectRevert(DropVault.BeneficiaryUnset.selector);
            vault.push(address(0));
            vm.stopPrank();
        }
        assertEq(vault.claimable(address(0)), before, "claimable must be untouched");
        assertEq(address(vault).balance, before, "the vault must still hold it");
    }

    /// Pointing the treasury at yourself does not retroactively reach credited money.
    function test_ownerRepointingTreasuryCannotReachCreditedFunds() public {
        uint256 before = vault.claimable(address(0));
        vm.prank(owner);
        factory.setTreasury(attacker);
        vm.prank(attacker);
        vm.expectRevert(DropVault.NothingPending.selector);
        vault.sweepProtocolCut(address(0));
        assertEq(vault.claimable(address(0)), before, "credited funds are out of reach");
        assertEq(attacker.balance, 0, "attacker gets nothing");
    }

    /// The split floor is enforced by the contract, not by the docs.
    function test_recipientShareCannotBeSetBelowHalf() public {
        vm.startPrank(owner);
        vm.expectRevert(DropVaultFactory.SplitOutOfRange.selector);
        factory.setRecipientBps(4999);
        factory.setRecipientBps(5000); // the floor itself is allowed
        vm.stopPrank();
        assertEq(factory.recipientBps(), 5000);
    }

    /// Once an account is bound, the operator can never re-point the vault at itself.
    function test_operatorCannotRebindAnAlreadyBoundVault() public {
        _bind(account);
        vm.prank(operator);
        vm.expectRevert(DropVault.BeneficiaryAlreadySet.selector);
        vault.requestBind(attacker);
        assertEq(vault.beneficiary(), account);
    }

    /// push() sends to the bound address. The caller does not choose, and cannot.
    function test_pushIgnoresTheCallerAndPaysTheBoundAddressOnly() public {
        _bind(account);
        uint256 owed = vault.claimable(address(0));
        vm.prank(attacker); // anyone may trigger it, including a hostile party
        vault.push(address(0));
        assertEq(account.balance, owed, "the account is paid in full");
        assertEq(attacker.balance, 0, "the caller receives nothing");
    }

    /// A bind cannot be rushed, not even by the owner.
    function test_bindWindowCannotBeShortened() public {
        vm.prank(operator);
        vault.requestBind(account);
        vm.expectRevert(DropVault.BindNotReady.selector);
        vault.executeBind();
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(DropVault.BindNotReady.selector);
        vault.executeBind();
        vm.warp(block.timestamp + 1);
        vault.executeBind();
        assertEq(vault.beneficiary(), account);
    }

    function _bind(address who) internal {
        vm.prank(operator);
        vault.requestBind(who);
        vm.warp(block.timestamp + 48 hours);
        vault.executeBind();
    }
}
