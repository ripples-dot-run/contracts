// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @notice Every address and number the terminal test uses, in one place, so the three stages
///         cannot drift apart and the record in `docs/qa/` can be checked against the source.
///
///         The two mined salts were found with `cast create2` against the artifacts this
///         checkout builds. If a source file under `src/tt/` changes, the init code changes, the
///         salts stop producing these addresses, and `_create2` will fail its own assertion
///         rather than deploy something at an address that no longer carries the bitmap.
library TerminalTestConfig {
    // --- Robinhood Chain mainnet, chain id 4663 ---
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Uniswap's own periphery, found on chain rather than in a deployment list: the Universal
    // Router answers `poolManager()` with the PoolManager above and `V4_POSITION_MANAGER()` with
    // the v4 Positions NFT, which had minted 1,953,700 positions when this test was written.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    address internal constant DEPLOYER = 0x22AF0946261D967e65445233d76CdC077AEb52cD;

    // --- mined ---
    bytes32 internal constant HOOK_SALT =
        0x311528b67175fa54cde54bf178c2615ec05c5e1ecae6f1c569ff1e5d0d960ce8;
    address internal constant HOOK = 0x08Ca632A6641c1d4aDCDf1c6590042A6aB222aC4;

    // Mined to sort below WETH so the launch token is currency0 and WETH is currency1, which is
    // the ordering the plan's seeding shape assumes: token-only position above the current tick.
    bytes32 internal constant TOKEN_SALT =
        0x45d07ced262e28f197e99cef7bcf8f77734b055002bff90968f2bb74bc4c61a1;
    address internal constant TOKEN = 0x002939da54ae7fb1C521371EfFA4662bb459f3ee;

    // Not mined: nothing about the seeder's address matters, only that both stages agree on it.
    bytes32 internal constant SEEDER_SALT = keccak256("ripples.terminal-test.seeder.1");

    // --- token ---
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant SEED_AMOUNT = 250_000_000e18;

    // --- pool ---
    uint24 internal constant FEE = 0;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant TICK_LOWER = -207_200;
    int24 internal constant TICK_UPPER = -193_400;
    /// @dev TickMath.getSqrtPriceAtTick(TICK_LOWER); the pool opens at the bottom of the range,
    ///      so the seed needs no quote and the position is live at block one.
    uint160 internal constant SQRT_PRICE_X96 = 2_510_809_139_091_789_284_100_322;
    uint128 internal constant LIQUIDITY = 15_896_090_150_931_041_124_583;

    // --- swap ---
    uint128 internal constant SWAP_AMOUNT_IN = 0.002 ether;
    /// @dev SqrtPriceMath puts the exact output at 1,983,540 TTEST. Floor at 1,900,000 so a
    ///      front-run or a rounding change fails the transaction rather than filling badly.
    uint128 internal constant SWAP_MIN_OUT = 1_900_000e18;

    function poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(WETH),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function predict(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))
                )
            )
        );
    }
}
