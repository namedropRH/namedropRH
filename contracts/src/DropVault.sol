// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsFeeEscrow, IPonsLaunchFactory, IPonsSweep} from "./interfaces/IPons.sol";
import {IDropVaultFactory} from "./DropVaultFactory.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title DropVault
 * @notice One vault per social account. The vault is the `creatorFeeRecipient` of every
 *         launch that names that account, so creator fees accrue in the launchpad's escrow
 *         under this address. Anyone may pull them in; on every pull the amount is split
 *         between the recipient share — claimable only by the bound account — and the
 *         protocol cut, which is forwarded to the treasury immediately.
 *
 *         MONEY LEAVES A VAULT THREE WAYS, AND THERE IS NO FOURTH:
 *           claim / claimWithSig   the bound account signs, and picks the destination
 *           push                   anyone may call it; the destination is the bound
 *                                  address and is NOT a parameter
 *
 *         There is deliberately no settlement function, no rescue, no sweep of the
 *         recipient share, no expiry, no pause and no proxy. The protocol cannot move a
 *         recipient's balance under any circumstance, including its own compromise. That
 *         absence is the product, and `test/NoAdminExit.t.sol` asserts it.
 *
 * @dev Deployed as an EIP-1167 clone by DropVaultFactory. All configuration — treasury,
 *      operator, split — is read from the factory at call time, never stored here.
 */
contract DropVault {
    uint256 public constant BPS = 10_000;
    address public constant NATIVE = address(0);

    /// A bind is announced publicly and cannot execute for this long. The window is a
    /// constant so that no key, including the owner's, can shorten it.
    uint256 public constant BIND_DELAY = 48 hours;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("DropVault");
    bytes32 private constant VERSION_HASH = keccak256("1");
    /// Claim(address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)");

    IDropVaultFactory public factory;
    bytes32 public handleId;
    address public beneficiary;
    uint256 public nonce;

    /// The address a pending bind would install, and the moment it becomes executable.
    address public pendingBeneficiary;
    uint256 public bindReadyAt;

    /// Recipient share still claimable, per asset (address(0) = native).
    mapping(address asset => uint256 amount) public claimable;
    /// Balance already accounted for: claimable + any protocol cut the treasury refused.
    /// Anything above this is unallocated and gets split on the next sync.
    mapping(address asset => uint256 amount) public accounted;
    /// Protocol cut held here because the treasury rejected it. Retried by sweepProtocolCut.
    mapping(address asset => uint256 amount) public pendingProtocolCut;

    event Initialized(bytes32 indexed handleId);
    event BindRequested(address indexed candidate, uint256 readyAt);
    event BindCancelled(address indexed candidate);
    event BindExecuted(address indexed beneficiary);
    event BeneficiaryUpdated(address indexed previous, address indexed current);
    event Pulled(address indexed asset, uint256 gross, uint256 recipientShare, uint256 protocolCut);
    event Claimed(address indexed asset, address indexed to, uint256 amount, bool relayed);
    event Pushed(address indexed asset, address indexed to, uint256 amount);
    event ProtocolCutDeferred(address indexed asset, uint256 amount);
    event ProtocolCutSwept(address indexed asset, address indexed treasury, uint256 amount);

    error AlreadyInitialized();
    error NotBeneficiary();
    error NotOperator();
    error BeneficiaryUnset();
    error BeneficiaryAlreadySet();
    error ZeroAddress();
    error NothingToClaim();
    error InsufficientClaimable();
    error SignatureExpired();
    error InvalidSignature();
    error NativeTransferFailed();
    error NothingPending();
    error BindNotReady();
    error Reentrant();

    /// A clone starts with every slot at zero, so the guard must treat 0 as "unlocked".
    /// Initialising this to 1 would only run in the implementation's constructor and would
    /// leave every clone permanently locked.
    uint256 private _lock;

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary || beneficiary == address(0)) revert NotBeneficiary();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != factory.operator() && msg.sender != factory.owner()) revert NotOperator();
        _;
    }

    /// @dev Called once by the factory right after cloning. The beneficiary is NOT set here:
    ///      it can only ever arrive through the public, delayed bind flow below.
    function initialize(bytes32 handleId_) external {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        factory = IDropVaultFactory(msg.sender);
        handleId = handleId_;
        emit Initialized(handleId_);
    }

    receive() external payable {}

    // ── Pulling fees in ──────────────────────────────────────────────────

    /// @notice Pull this vault's native balance out of the launchpad escrow and split it.
    ///         Permissionless: anyone may pay the gas. If we disappear, every balance can
    ///         still be moved out of the escrow and into the vault it belongs to.
    function pull(address escrow) external nonReentrant returns (uint256 gross) {
        if (IPonsFeeEscrow(escrow).balanceOf(address(this)) > 0) IPonsFeeEscrow(escrow).claim();
        gross = _sync(NATIVE);
    }

    /// @notice Same, for a launch priced in an ERC-20.
    function pullToken(address escrow, address token) external nonReentrant returns (uint256 gross) {
        if (token == NATIVE) revert ZeroAddress();
        if (IPonsFeeEscrow(escrow).balanceOfToken(address(this), token) > 0) {
            IPonsFeeEscrow(escrow).claimToken(token);
        }
        gross = _sync(token);
    }

    /// @notice Split any balance of `asset` not yet accounted for — covers value that
    ///         arrived by a plain transfer rather than through the escrow.
    function sync(address asset) external nonReentrant returns (uint256 gross) {
        gross = _sync(asset);
    }

    function _sync(address asset) internal returns (uint256 gross) {
        uint256 balance = _balance(asset);
        uint256 known = accounted[asset];
        if (balance <= known) return 0;
        gross = balance - known;

        uint256 recipientShare = (gross * factory.recipientBps()) / BPS;
        uint256 protocolCut = gross - recipientShare;

        // The recipient is credited BEFORE the treasury is paid, so a treasury that
        // reverts can only ever defer its own share — never block, delay or reduce
        // what the named account is owed.
        claimable[asset] += recipientShare;
        accounted[asset] = known + recipientShare;

        if (protocolCut > 0 && !_tryTransfer(asset, factory.treasury(), protocolCut)) {
            pendingProtocolCut[asset] += protocolCut;
            accounted[asset] += protocolCut;
            emit ProtocolCutDeferred(asset, protocolCut);
        }
        emit Pulled(asset, gross, recipientShare, protocolCut);
    }

    /// @notice Retry delivering a deferred protocol cut. Touches only the protocol's own
    ///         money — `claimable` is never read or written here.
    function sweepProtocolCut(address asset) external nonReentrant returns (uint256 amount) {
        amount = pendingProtocolCut[asset];
        if (amount == 0) revert NothingPending();
        address treasury = factory.treasury();
        pendingProtocolCut[asset] = 0;
        accounted[asset] -= amount;
        _transfer(asset, treasury, amount);
        emit ProtocolCutSwept(asset, treasury, amount);
    }

    // ── The three exits ──────────────────────────────────────────────────

    /// @notice Claim the whole claimable balance of `asset` to `to`. Bound account only.
    function claim(address asset, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != beneficiary || beneficiary == address(0)) revert NotBeneficiary();
        amount = claimable[asset];
        _claim(asset, to, amount, false);
    }

    /// @notice Claim `amount` of `asset` to `to`. Bound account only.
    function claim(address asset, address to, uint256 amount) external nonReentrant {
        if (msg.sender != beneficiary || beneficiary == address(0)) revert NotBeneficiary();
        _claim(asset, to, amount, false);
    }

    /**
     * @notice Relay a claim signed by the bound account (EIP-712). Anyone may submit it,
     *         so claiming is gasless for the recipient.
     * @param amount 0 means "everything claimable at execution time".
     */
    function claimWithSig(address asset, address to, uint256 amount, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        if (beneficiary == address(0)) revert BeneficiaryUnset();
        if (block.timestamp > deadline) revert SignatureExpired();
        uint256 currentNonce = nonce++;
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, asset, to, amount, currentNonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (_recover(digest, signature) != beneficiary) revert InvalidSignature();
        if (amount == 0) amount = claimable[asset];
        _claim(asset, to, amount, true);
    }

    /**
     * @notice Send the whole claimable balance to the address this account has bound.
     *         Permissionless — the protocol can trigger a payment and pay for it — but the
     *         DESTINATION IS NOT A PARAMETER. There is no caller, key or role that can
     *         redirect this anywhere other than the account's own bound address.
     */
    function push(address asset) external nonReentrant returns (uint256 amount) {
        address to = beneficiary;
        if (to == address(0)) revert BeneficiaryUnset();
        amount = claimable[asset];
        if (amount == 0) revert NothingToClaim();
        claimable[asset] = 0;
        accounted[asset] -= amount;
        _transfer(asset, to, amount);
        emit Pushed(asset, to, amount);
    }

    function _claim(address asset, address to, uint256 amount, bool relayed) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToClaim();
        uint256 available = claimable[asset];
        if (amount > available) revert InsufficientClaimable();
        claimable[asset] = available - amount;
        accounted[asset] -= amount;
        _transfer(asset, to, amount);
        emit Claimed(asset, to, amount, relayed);
    }

    // ── Binding: the one trusted step, made slow and loud ─────────────────

    /**
     * @notice Announce that `candidate` claims this account. Emits publicly and starts a
     *         48-hour timer that nobody can shorten. Only possible while the vault has no
     *         beneficiary — once an account is bound, the operator can never re-point it;
     *         only the account itself can, via setBeneficiary.
     */
    function requestBind(address candidate) external onlyOperator {
        if (beneficiary != address(0)) revert BeneficiaryAlreadySet();
        if (candidate == address(0)) revert ZeroAddress();
        pendingBeneficiary = candidate;
        bindReadyAt = block.timestamp + BIND_DELAY;
        emit BindRequested(candidate, bindReadyAt);
    }

    /// @notice Withdraw a pending bind — the escape hatch when someone objects in the window.
    function cancelBind() external onlyOperator {
        address candidate = pendingBeneficiary;
        if (candidate == address(0)) revert NothingPending();
        pendingBeneficiary = address(0);
        bindReadyAt = 0;
        emit BindCancelled(candidate);
    }

    /// @notice Install the pending beneficiary once the window has elapsed. Permissionless,
    ///         so the account never depends on us to finish what we announced.
    function executeBind() external {
        address candidate = pendingBeneficiary;
        if (candidate == address(0)) revert NothingPending();
        if (block.timestamp < bindReadyAt) revert BindNotReady();
        if (beneficiary != address(0)) revert BeneficiaryAlreadySet();
        pendingBeneficiary = address(0);
        bindReadyAt = 0;
        beneficiary = candidate;
        emit BindExecuted(candidate);
        emit BeneficiaryUpdated(address(0), candidate);
    }

    /// @notice Hand the vault to another address. Bound account only, immediate.
    function setBeneficiary(address newBeneficiary) external onlyBeneficiary {
        if (newBeneficiary == address(0)) revert ZeroAddress();
        emit BeneficiaryUpdated(beneficiary, newBeneficiary);
        beneficiary = newBeneficiary;
    }

    // ── Sweeping fees off a launch, for anyone ────────────────────────────

    /**
     * @notice Move this vault's accrued fees off a launch's bonding curve and into the
     *         venue escrow, from where `pull` brings them home.
     *
     *         The venue records the creator FEE RECIPIENT — this vault — as the party
     *         allowed to sweep, so the permission lands here rather than on the launcher.
     *         Exposing it to everyone is safe: a sweep can only ever move money toward the
     *         account it already belongs to, and the venue blocks this path itself whenever
     *         an internal swap would make the slippage floor worth manipulating.
     */
    function sweepCurveFees(address curve, uint256 minBuybackTokensOut) external {
        IPonsSweep(curve).sweepFees(minBuybackTokensOut);
    }

    /// @notice The same, after graduation, when fees accrue on the venue's pool hook instead.
    function sweepPoolFees(address hook, bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut)
        external
    {
        IPonsSweep(hook).sweepPoolFees(poolId, minConversionQuoteOut, minBuybackTokensOut);
    }

    // ── Launch-venue controls, for the account only ───────────────────────

    /// @notice Point a launch's future creator fees somewhere else entirely. The account can
    ///         walk away from this protocol and keep its coins' fee stream.
    function redirectCreatorFees(address ponsFactory, address token, address newRecipient)
        external
        onlyBeneficiary
    {
        IPonsLaunchFactory(ponsFactory).transferCreatorFeeRecipient(token, newRecipient);
    }

    function setBuybackEnabled(address ponsFactory, address token, bool enabled) external onlyBeneficiary {
        IPonsLaunchFactory(ponsFactory).setBuybackEnabled(token, enabled);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice Fees still waiting in the launchpad escrow. The board adds this to `claimable`
    ///         so the number it shows is everything owed, not just the part already pulled.
    function pendingInEscrow(address escrow) external view returns (uint256) {
        return IPonsFeeEscrow(escrow).balanceOf(address(this));
    }

    function pendingTokenInEscrow(address escrow, address token) external view returns (uint256) {
        return IPonsFeeEscrow(escrow).balanceOfToken(address(this), token);
    }

    function unallocated(address asset) external view returns (uint256) {
        uint256 balance = _balance(asset);
        uint256 known = accounted[asset];
        return balance > known ? balance - known : 0;
    }

    // ── Internals ─────────────────────────────────────────────────────────

    function _balance(address asset) internal view returns (uint256) {
        return asset == NATIVE ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool ok) {
        if (asset == NATIVE) {
            (ok,) = to.call{value: amount}("");
        } else {
            bytes memory data;
            (ok, data) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
            ok = ok && (data.length == 0 || abi.decode(data, (bool)));
        }
    }

    function _transfer(address asset, address to, uint256 amount) internal {
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            (bool ok, bytes memory data) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert NativeTransferFailed();
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Reject the malleable upper half of the curve order.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
