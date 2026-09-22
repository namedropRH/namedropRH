// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DropVault} from "./DropVault.sol";

interface IDropVaultFactory {
    function owner() external view returns (address);
    function operator() external view returns (address);
    function treasury() external view returns (address);
    function recipientBps() external view returns (uint256);
}

/**
 * @title DropVaultFactory
 * @notice Deploys one DropVault per account at a deterministic address derived from that
 *         account's STABLE NUMERIC ID — never from the handle text. Handles are rentable:
 *         if the address came from the text, anyone could rename into a freed handle and take
 *         the balance. A numeric id survives every rename.
 *
 *         Because the address is known before the vault exists, a launch can name it the same
 *         second, and fees accrue in the launchpad escrow until someone creates the vault and
 *         pulls them in.
 *
 * @dev Vault creation is PERMISSIONLESS. It is safe to leave open precisely because a fresh
 *      vault has no beneficiary — the only way an address is ever installed is the public,
 *      48-hour-delayed bind inside the vault. Nothing an attacker can do by creating a vault
 *      first gets them any claim on its balance.
 */
contract DropVaultFactory is IDropVaultFactory {
    uint256 public constant BPS = 10_000;
    /// The recipient share may be raised in the account's favour, never lowered past this.
    uint256 public constant MIN_RECIPIENT_BPS = 5_000;

    address public immutable implementation;

    address private _owner;
    address private _pendingOwner;
    address public operator;
    address public treasury;
    uint256 public recipientBps;
    address public ponsFeeEscrow;

    mapping(bytes32 handleId => address vault) public vaultOf;
    mapping(address vault => bytes32 handleId) public handleOf;
    uint256 public vaultCount;

    event VaultCreated(bytes32 indexed handleId, address indexed vault);
    event OperatorUpdated(address indexed operator);
    event TreasuryUpdated(address indexed treasury);
    event RecipientBpsUpdated(uint256 recipientBps);
    event PonsFeeEscrowUpdated(address indexed escrow);
    event PullFailed(address indexed vault, bytes reason);
    event OwnershipTransferStarted(address indexed previous, address indexed pending);
    event OwnershipTransferred(address indexed previous, address indexed current);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error VaultExists();
    error SplitOutOfRange();

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address operator_, address treasury_, uint256 recipientBps_, address escrow_) {
        if (owner_ == address(0) || operator_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (recipientBps_ < MIN_RECIPIENT_BPS || recipientBps_ > BPS) revert SplitOutOfRange();
        DropVault impl = new DropVault();
        // Lock the raw implementation so nobody can initialise it against their own factory.
        impl.initialize(bytes32(0));
        implementation = address(impl);
        _owner = owner_;
        operator = operator_;
        treasury = treasury_;
        recipientBps = recipientBps_;
        ponsFeeEscrow = escrow_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ── Vaults ────────────────────────────────────────────────────────────

    /// @notice The vault address for an account id, whether or not it has been deployed.
    function predictVault(bytes32 handleId) public view returns (address predicted) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), handleId, keccak256(_cloneInitCode(implementation)))
        );
        predicted = address(uint160(uint256(hash)));
    }

    /// @notice Deploy the vault for `handleId`. Anyone may call it; see the note on the contract.
    function createVault(bytes32 handleId) external returns (address vault) {
        if (vaultOf[handleId] != address(0)) revert VaultExists();
        bytes memory code = _cloneInitCode(implementation);
        assembly {
            vault := create2(0, add(code, 0x20), mload(code), handleId)
        }
        if (vault == address(0)) revert VaultExists();
        DropVault(payable(vault)).initialize(handleId);
        vaultOf[handleId] = vault;
        handleOf[vault] = handleId;
        vaultCount++;
        emit VaultCreated(handleId, vault);
    }

    /// @notice Pull native fees for many vaults in one transaction. A vault that reverts is
    ///         skipped and reported, never blocking the rest of the batch.
    function pullMany(address[] calldata vaults) external returns (uint256 total) {
        address escrow = ponsFeeEscrow;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (handleOf[vaults[i]] == bytes32(0)) {
                emit PullFailed(vaults[i], "not a vault");
                continue;
            }
            try DropVault(payable(vaults[i])).pull(escrow) returns (uint256 gross) {
                total += gross;
            } catch (bytes memory reason) {
                emit PullFailed(vaults[i], reason);
            }
        }
    }

    /// @notice Same, for a launch priced in an ERC-20.
    function pullManyToken(address[] calldata vaults, address token) external returns (uint256 total) {
        address escrow = ponsFeeEscrow;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (handleOf[vaults[i]] == bytes32(0)) {
                emit PullFailed(vaults[i], "not a vault");
                continue;
            }
            try DropVault(payable(vaults[i])).pullToken(escrow, token) returns (uint256 gross) {
                total += gross;
            } catch (bytes memory reason) {
                emit PullFailed(vaults[i], reason);
            }
        }
    }

    /// @notice Push many vaults' balances to the addresses their accounts bound. The
    ///         destination is each vault's own beneficiary — this call cannot redirect it.
    function pushMany(address[] calldata vaults, address asset) external returns (uint256 total) {
        for (uint256 i = 0; i < vaults.length; i++) {
            if (handleOf[vaults[i]] == bytes32(0)) {
                emit PullFailed(vaults[i], "not a vault");
                continue;
            }
            try DropVault(payable(vaults[i])).push(asset) returns (uint256 amount) {
                total += amount;
            } catch (bytes memory reason) {
                emit PullFailed(vaults[i], reason);
            }
        }
    }

    // ── Admin ─────────────────────────────────────────────────────────────
    // Note what is absent: the owner can set where the PROTOCOL's own cut goes and can
    // raise the recipient's share. There is no owner function that touches a vault's
    // claimable balance, and none that can be added — the vaults are not upgradeable.

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorUpdated(operator_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice The recipient share can never be set below 50%.
    function setRecipientBps(uint256 recipientBps_) external onlyOwner {
        if (recipientBps_ < MIN_RECIPIENT_BPS || recipientBps_ > BPS) revert SplitOutOfRange();
        recipientBps = recipientBps_;
        emit RecipientBpsUpdated(recipientBps_);
    }

    function setPonsFeeEscrow(address escrow) external onlyOwner {
        ponsFeeEscrow = escrow;
        emit PonsFeeEscrowUpdated(escrow);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(_owner, _pendingOwner);
        _owner = _pendingOwner;
        _pendingOwner = address(0);
    }

    // ── Internals ─────────────────────────────────────────────────────────

    /// EIP-1167 minimal proxy init code.
    function _cloneInitCode(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
