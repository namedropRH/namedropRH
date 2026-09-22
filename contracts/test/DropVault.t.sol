// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DropVault} from "../src/DropVault.sol";
import {DropVaultFactory} from "../src/DropVaultFactory.sol";
import {MockEscrow, MockERC20, RejectingTreasury} from "./Mocks.sol";

contract DropVaultTest is Test {
    DropVaultFactory factory;
    DropVault vault;
    MockEscrow escrow;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");

    uint256 accountPk = 0xA11CE;
    address account;
    bytes32 constant HANDLE = bytes32(uint256(1234567890));

    function setUp() public {
        account = vm.addr(accountPk);
        escrow = new MockEscrow();
        factory = new DropVaultFactory(owner, operator, treasury, 8000, address(escrow));
        vault = DropVault(payable(factory.createVault(HANDLE)));
    }

    // ── address derivation ────────────────────────────────────────────────

    function test_vaultAddressIsKnownBeforeItExists() public {
        bytes32 other = bytes32(uint256(999));
        address predicted = factory.predictVault(other);
        assertEq(predicted.code.length, 0, "must not exist yet");
        address created = factory.createVault(other);
        assertEq(created, predicted, "a launch can name the address in advance");
    }

    function test_differentAccountsGetDifferentVaults() public {
        address a = factory.createVault(bytes32(uint256(1)));
        address b = factory.createVault(bytes32(uint256(2)));
        assertTrue(a != b);
    }

    function test_creatingTheSameVaultTwiceReverts() public {
        vm.expectRevert(DropVaultFactory.VaultExists.selector);
        factory.createVault(HANDLE);
    }

    /// Creation is open, and that is safe: a fresh vault has no beneficiary, so being
    /// first to deploy it grants nothing.
    function test_anyoneMayCreateAVaultButGainsNothing() public {
        vm.prank(stranger);
        DropVault v = DropVault(payable(factory.createVault(bytes32(uint256(7)))));
        assertEq(v.beneficiary(), address(0));
        escrow.credit{value: 1 ether}(address(v));
        v.pull(address(escrow));
        vm.prank(stranger);
        vm.expectRevert(DropVault.NotBeneficiary.selector);
        v.claim(address(0), stranger);
    }

    // ── the split ─────────────────────────────────────────────────────────

    function test_pullSplitsEightyTwenty() public {
        escrow.credit{value: 10 ether}(address(vault));
        vault.pull(address(escrow));
        assertEq(vault.claimable(address(0)), 8 ether);
        assertEq(treasury.balance, 2 ether);
    }

    function test_pullIsPermissionless() public {
        escrow.credit{value: 1 ether}(address(vault));
        vm.prank(stranger);
        vault.pull(address(escrow));
        assertEq(vault.claimable(address(0)), 0.8 ether);
    }

    /// A treasury that refuses payment defers only its OWN share.
    function test_hostileTreasuryCannotBlockTheRecipient() public {
        RejectingTreasury bad = new RejectingTreasury();
        vm.prank(owner);
        factory.setTreasury(address(bad));

        escrow.credit{value: 10 ether}(address(vault));
        vault.pull(address(escrow));

        assertEq(vault.claimable(address(0)), 8 ether, "recipient credited regardless");
        assertEq(vault.pendingProtocolCut(address(0)), 2 ether, "only the protocol waits");

        _bind(account);
        vm.prank(account);
        vault.claim(address(0), account);
        assertEq(account.balance, 8 ether, "and can still withdraw in full");
    }

    function test_deferredProtocolCutCanBeRetriedLater() public {
        RejectingTreasury bad = new RejectingTreasury();
        vm.prank(owner);
        factory.setTreasury(address(bad));
        escrow.credit{value: 10 ether}(address(vault));
        vault.pull(address(escrow));

        vm.prank(owner);
        factory.setTreasury(treasury);
        vault.sweepProtocolCut(address(0));
        assertEq(treasury.balance, 2 ether);
        assertEq(vault.pendingProtocolCut(address(0)), 0);
    }

    function test_directTransfersAreSplitOnSync() public {
        (bool ok,) = address(vault).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(vault.unallocated(address(0)), 5 ether);
        vault.sync(address(0));
        assertEq(vault.claimable(address(0)), 4 ether);
        assertEq(treasury.balance, 1 ether);
    }

    function test_erc20FeesSplitTheSameWay() public {
        MockERC20 token = new MockERC20();
        token.mint(address(escrow), 10 ether);
        escrow.creditToken(address(vault), address(token), 10 ether);
        vault.pullToken(address(escrow), address(token));
        assertEq(vault.claimable(address(token)), 8 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    // ── the exits ─────────────────────────────────────────────────────────

    function test_boundAccountClaimsToAnyDestination() public {
        _fund(10 ether);
        _bind(account);
        vm.prank(account);
        vault.claim(address(0), stranger);
        assertEq(stranger.balance, 8 ether, "the signer picks the destination");
    }

    function test_claimWithSigIsGaslessForTheAccount() public {
        _fund(10 ether);
        _bind(account);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(accountPk, address(0), account, 0, vault.nonce(), deadline);
        vm.prank(relayer);
        vault.claimWithSig(address(0), account, 0, deadline, sig);
        assertEq(account.balance, 8 ether);
        assertEq(vault.nonce(), 1, "nonce consumed");
    }

    function test_aSignatureCannotBeReplayed() public {
        _fund(10 ether);
        _bind(account);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(accountPk, address(0), account, 1 ether, vault.nonce(), deadline);
        vault.claimWithSig(address(0), account, 1 ether, deadline, sig);
        vm.expectRevert(DropVault.InvalidSignature.selector);
        vault.claimWithSig(address(0), account, 1 ether, deadline, sig);
    }

    function test_anotherKeyCannotSignForTheAccount() public {
        _fund(10 ether);
        _bind(account);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(0xBEEF, address(0), stranger, 0, vault.nonce(), deadline);
        vm.expectRevert(DropVault.InvalidSignature.selector);
        vault.claimWithSig(address(0), stranger, 0, deadline, sig);
    }

    function test_claimCannotExceedWhatIsOwed() public {
        _fund(10 ether);
        _bind(account);
        vm.prank(account);
        vm.expectRevert(DropVault.InsufficientClaimable.selector);
        vault.claim(address(0), account, 8 ether + 1);
    }

    function test_pushRevertsWhileNoAddressIsBound() public {
        _fund(1 ether);
        vm.expectRevert(DropVault.BeneficiaryUnset.selector);
        vault.push(address(0));
    }

    function test_balanceSurvivesIndefinitelyWhenNobodyClaims() public {
        _fund(10 ether);
        vm.warp(block.timestamp + 3650 days);
        assertEq(vault.claimable(address(0)), 8 ether, "nothing expires, ever");
        _bind(account);
        vm.prank(account);
        vault.claim(address(0), account);
        assertEq(account.balance, 8 ether);
    }

    // ── binding ───────────────────────────────────────────────────────────

    function test_onlyOperatorCanRequestABind() public {
        vm.prank(stranger);
        vm.expectRevert(DropVault.NotOperator.selector);
        vault.requestBind(stranger);
    }

    function test_aPendingBindCanBeCancelledInTheWindow() public {
        vm.prank(operator);
        vault.requestBind(stranger);
        vm.prank(operator);
        vault.cancelBind();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(DropVault.NothingPending.selector);
        vault.executeBind();
        assertEq(vault.beneficiary(), address(0));
    }

    function test_executeBindIsPermissionlessAfterTheWindow() public {
        vm.prank(operator);
        vault.requestBind(account);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(stranger); // the account never depends on us to finish
        vault.executeBind();
        assertEq(vault.beneficiary(), account);
    }

    function test_accountCanHandTheVaultOn() public {
        _bind(account);
        vm.prank(account);
        vault.setBeneficiary(stranger);
        assertEq(vault.beneficiary(), stranger);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _fund(uint256 amount) internal {
        escrow.credit{value: amount}(address(vault));
        vault.pull(address(escrow));
    }

    function _bind(address who) internal {
        vm.prank(operator);
        vault.requestBind(who);
        vm.warp(block.timestamp + 48 hours);
        vault.executeBind();
    }

    function _signClaim(uint256 pk, address asset, address to, uint256 amount, uint256 n, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(vault.CLAIM_TYPEHASH(), asset, to, amount, n, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
