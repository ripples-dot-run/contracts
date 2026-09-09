// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Permissionless WETH relay for exact payments and bound contract calls.
/// @dev EIP-2612 authorizes this router to pull WETH but does not bind where it goes or what
///      call it funds. The router's separate EIP-712 intent binds those terms. Anyone may relay
///      a valid intent; there is no signer role or target allowlist.
///
///      **WETH-only, and out of scope for per-launch quotes in v1** (DQ11). `WETH` is immutable
///      and the signed intents name an owner, a recipient and a value but never an asset, so
///      there is nothing here to point at a second token: a stock-quoted buy cannot be relayed
///      through this contract at all. That is the documented limitation, not a gap to be closed
///      quietly. A buyer settling in a stock token uses the direct-approve path and approves
///      the curve itself. Generalising this would mean an asset in the typehash, which is a new
///      domain and a re-freeze, and it buys nothing until a stock token on 4663 answers
///      EIP-2612 the way WETH does. `WETHSettlementRouter.t.sol` pins the boundary.
contract WETHSettlementRouter is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant NAME = "Ripples WETH Settlement Router";
    string public constant VERSION = "1";

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address owner,address recipient,uint256 value,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant EXECUTION_TYPEHASH = keccak256(
        "Execution(address owner,address target,uint256 value,bytes32 callHash,bytes32 nonce,uint256 deadline)"
    );

    struct Payment {
        address owner;
        address recipient;
        uint256 value;
        bytes32 nonce;
        uint256 deadline;
    }

    struct Execution {
        address owner;
        address target;
        uint256 value;
        bytes32 callHash;
        bytes32 nonce;
        uint256 deadline;
    }

    /// An all-zero permit is omitted. A permit that was front-run may revert here after already
    /// installing the allowance, so failure is tolerated and the resulting allowance is checked.
    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    IERC20 public immutable WETH;

    mapping(address owner => mapping(bytes32 nonce => bool used)) public usedNonces;

    event PaymentSettled(
        address indexed owner, address indexed to, bytes32 indexed nonce, uint256 value
    );
    event CallExecuted(
        address indexed owner,
        address indexed target,
        bytes32 indexed nonce,
        uint256 value,
        bytes32 callHash
    );

    error ZeroAddress();
    error NotAContract();
    error ZeroValue();
    error IntentExpired(uint256 deadline);
    error NonceAlreadyUsed(address owner, bytes32 nonce);
    error InvalidIntentSignature();
    error CallHashMismatch(bytes32 expected, bytes32 actual);
    error InsufficientAllowance(uint256 available, uint256 required);
    error WrongTokenMovement();
    error WrongExecutionSpend(uint256 expected, uint256 actual);

    constructor(address weth) EIP712(NAME, VERSION) {
        if (weth == address(0)) revert ZeroAddress();
        if (weth.code.length == 0) revert NotAContract();
        WETH = IERC20(weth);
    }

    /// @notice Pull exactly `payment.value` WETH and deliver it to the signed recipient.
    function settle(
        Payment calldata payment,
        Permit calldata permitData,
        bytes calldata intentSignature
    ) external nonReentrant {
        if (payment.recipient == address(0) || payment.recipient == address(this)) {
            revert ZeroAddress();
        }
        _authorize(
            payment.owner, payment.nonce, payment.deadline, _paymentDigest(payment), intentSignature
        );

        uint256 routerBefore = _permitAndPull(payment.owner, payment.value, permitData);
        _transferExact(payment.recipient, payment.value);
        if (WETH.balanceOf(address(this)) != routerBefore) revert WrongTokenMovement();

        emit PaymentSettled(payment.owner, payment.recipient, payment.nonce, payment.value);
    }

    /// @notice Fund and execute the exact target calldata the owner signed.
    /// @dev The target receives an allowance for exactly `execution.value` and must consume all
    ///      of it before returning. The allowance is cleared even when the target consumed it.
    function execute(
        Execution calldata execution,
        bytes calldata callData,
        Permit calldata permitData,
        bytes calldata intentSignature
    ) external nonReentrant returns (bytes memory result) {
        if (execution.target == address(0) || execution.target == address(this)) {
            revert ZeroAddress();
        }
        bytes32 callHash = keccak256(callData);
        if (callHash != execution.callHash) {
            revert CallHashMismatch(execution.callHash, callHash);
        }
        _authorize(
            execution.owner,
            execution.nonce,
            execution.deadline,
            _executionDigest(execution),
            intentSignature
        );

        uint256 routerBefore = _permitAndPull(execution.owner, execution.value, permitData);
        result = _callExact(execution.target, execution.value, callData, routerBefore);

        emit CallExecuted(
            execution.owner, execution.target, execution.nonce, execution.value, callHash
        );
        return result;
    }

    function paymentDigest(Payment calldata payment) external view returns (bytes32) {
        return _paymentDigest(payment);
    }

    function executionDigest(Execution calldata execution) external view returns (bytes32) {
        return _executionDigest(execution);
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _authorize(
        address owner,
        bytes32 nonce,
        uint256 deadline,
        bytes32 digest,
        bytes calldata signature
    ) private {
        if (owner == address(0) || owner == address(this)) revert ZeroAddress();
        if (deadline < block.timestamp) revert IntentExpired(deadline);
        if (usedNonces[owner][nonce]) revert NonceAlreadyUsed(owner, nonce);
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) {
            revert InvalidIntentSignature();
        }
        usedNonces[owner][nonce] = true;
    }

    function _permitAndPull(address owner, uint256 value, Permit calldata permitData)
        private
        returns (uint256 routerBefore)
    {
        if (value == 0) revert ZeroValue();
        if (
            permitData.deadline != 0 || permitData.v != 0 || permitData.r != bytes32(0)
                || permitData.s != bytes32(0)
        ) {
            try IERC20Permit(address(WETH))
                .permit(
                    owner,
                    address(this),
                    value,
                    permitData.deadline,
                    permitData.v,
                    permitData.r,
                    permitData.s
                ) { }
                catch { }
        }

        uint256 allowance = WETH.allowance(owner, address(this));
        if (allowance < value) revert InsufficientAllowance(allowance, value);

        uint256 ownerBefore = WETH.balanceOf(owner);
        routerBefore = WETH.balanceOf(address(this));
        WETH.safeTransferFrom(owner, address(this), value);
        uint256 ownerAfter = WETH.balanceOf(owner);
        uint256 routerAfter = WETH.balanceOf(address(this));
        if (
            ownerAfter > ownerBefore || ownerBefore - ownerAfter != value
                || routerAfter < routerBefore || routerAfter - routerBefore != value
        ) revert WrongTokenMovement();
    }

    function _transferExact(address to, uint256 value) private {
        uint256 routerBefore = WETH.balanceOf(address(this));
        uint256 recipientBefore = WETH.balanceOf(to);
        WETH.safeTransfer(to, value);
        uint256 routerAfter = WETH.balanceOf(address(this));
        uint256 recipientAfter = WETH.balanceOf(to);
        if (
            routerAfter > routerBefore || routerBefore - routerAfter != value
                || recipientAfter < recipientBefore || recipientAfter - recipientBefore != value
        ) revert WrongTokenMovement();
    }

    function _callExact(
        address target,
        uint256 value,
        bytes calldata callData,
        uint256 routerBefore
    ) private returns (bytes memory result) {
        WETH.forceApprove(target, value);
        (bool success, bytes memory returnData) = target.call(callData);
        WETH.forceApprove(target, 0);
        if (!success) _revert(returnData);

        uint256 routerAfter = WETH.balanceOf(address(this));
        uint256 funded = routerBefore + value;
        if (routerAfter > funded) revert WrongTokenMovement();
        uint256 spent = funded - routerAfter;
        if (spent != value) revert WrongExecutionSpend(value, spent);
        return returnData;
    }

    function _paymentDigest(Payment calldata payment) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_TYPEHASH,
                    payment.owner,
                    payment.recipient,
                    payment.value,
                    payment.nonce,
                    payment.deadline
                )
            )
        );
    }

    function _executionDigest(Execution calldata execution) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    EXECUTION_TYPEHASH,
                    execution.owner,
                    execution.target,
                    execution.value,
                    execution.callHash,
                    execution.nonce,
                    execution.deadline
                )
            )
        );
    }

    function _revert(bytes memory returnData) private pure {
        if (returnData.length == 0) revert WrongTokenMovement();
        assembly ("memory-safe") {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }
}
