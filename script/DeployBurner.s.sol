// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BuybackBurner } from "../src/BuybackBurner.sol";
import { UniswapV4Venue } from "../src/UniswapV4Venue.sol";

/// Deploys the buyback pair `docs/ops/BUYBACK_RUNBOOK.md` operates: `BuybackBurner`, which spends
/// protocol quote on the platform token and sends what it buys to the burn address, and
/// `UniswapV4Venue`, the adapter it buys through once that token has graduated onto a locked
/// Uniswap V4 pool. Before graduation the venue is the token's own bonding curve, which needs no
/// adapter, so the two are deployed together and the switch is one owner call later.
///
/// Nothing is wired here. The burner lands with no keeper, no venue and a zero cap, so no call
/// can spend from it until an owner says so. Sizing the cap and pointing the venue are steps 2
/// and 3 of the runbook, and they are separate transactions so each can be reviewed on its own.
///
/// The pool key is fixed at the venue's construction and has to be the one the graduation hook
/// opened: a venue keyed to a pool that does not exist reverts on every buy, and one keyed to a
/// different fee tier trades against the wrong market. Every part of it defaults to the network's
/// own record rather than to a constant typed here.
///
/// Every override this script reads is prefixed, because `Deploy.s.sol` reads names of its own and
/// forge shares one environment across the tests that drive both.
///
///   BURNER_TOKEN            the platform token to buy and burn; required
///   BURNER_QUOTE            the settlement token fees arrive in; defaults to the network's `weth`
///   BURNER_POOL_MANAGER     Uniswap V4 PoolManager; defaults to the network's record
///   BURNER_GRADUATION_HOOK  hook the graduated pool is keyed to; defaults to the network's record
///   BURNER_POOL_FEE         pool fee in hundredths of a bip; defaults to the network's record
///   BURNER_TICK_SPACING     pool tick spacing; defaults to the network's record
///   BURNER_OWNER            burner admin; defaults to the network's Safe, else to the deployer
///   ALLOW_MAINNET_DEPLOY    must be true to broadcast on chain 4663
///   WRITE_DEPLOYMENTS       set false to skip the deployments.json write on a broadcast run
///
/// The deployer is whichever sender forge is running as. No environment variable overrides it.
contract DeployBurner is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant DEPLOYMENTS = "./deployments.json";

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    error PoolFeeOutOfRange(uint256 fee);
    error TickSpacingOutOfRange(int256 tickSpacing);

    function run() external returns (BuybackBurner burner, UniswapV4Venue venue) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));

        address token = _required("BURNER_TOKEN");
        // The network's default quote, and deliberately only ever that. Stock-denominated fees
        // go to the treasury and stay out of the $RIPP buyback in v1 (DQ13), because this
        // venue's pool is WETH-quoted: a burner pointed at an allowlisted stock token would be
        // buying through a pool no graduation ever opened. `deployments.json` now carries a
        // whole list of approved assets, any one of which would otherwise look like a
        // candidate, so `contracts/test/DeployBurnerScript.t.sol` pins this as a test rather
        // than leaving it to this comment.
        address quote = _resolve("BURNER_QUOTE", network, "weth");
        address poolManager = _resolve("BURNER_POOL_MANAGER", network, "poolManager");
        address hook = _resolve("BURNER_GRADUATION_HOOK", network, "graduationHook");
        address owner = vm.envOr("BURNER_OWNER", address(0));
        if (owner == address(0)) owner = _governanceOwner(network);

        // Both constructors reject an EOA, but they do it after the transaction is in flight. A
        // typo is cheaper to find here.
        if (token.code.length == 0) revert NoCodeAt(token);
        if (quote.code.length == 0) revert NoCodeAt(quote);
        if (poolManager.code.length == 0) revert NoCodeAt(poolManager);

        uint256 fee = vm.envOr("BURNER_POOL_FEE", _recordUint(network, "poolFee"));
        int256 tickSpacing = vm.envOr("BURNER_TICK_SPACING", _recordInt(network, "tickSpacing"));
        if (fee > type(uint24).max) revert PoolFeeOutOfRange(fee);
        if (tickSpacing < type(int24).min || tickSpacing > type(int24).max) {
            revert TickSpacingOutOfRange(tickSpacing);
        }

        vm.startBroadcast();
        venue = new UniswapV4Venue(
            IPoolManager(poolManager),
            IERC20(quote),
            IERC20(token),
            uint24(fee),
            int24(tickSpacing),
            IHooks(hook)
        );
        // Ownable2Step takes the owner at construction, so the owner holds the burner outright
        // from the first block. The factories hand over in two steps because the deployer has
        // wiring to finish first; the burner has none, and every call that can spend from it is
        // one the runbook sends from the Safe.
        burner = new BuybackBurner(IERC20(quote), IERC20(token), owner);
        vm.stopBroadcast();

        console2.log("buybackBurner", address(burner));
        console2.log("buybackVenue", address(venue));
        console2.log("owner", burner.owner());
        console2.log("quote", address(burner.QUOTE()));
        console2.log("token", address(burner.TOKEN()));

        if (!_writesDeployments()) return (burner, venue);
        vm.writeJson(
            _jsonAddress(address(burner)),
            DEPLOYMENTS,
            string.concat(".", network, ".buybackBurner")
        );
        vm.writeJson(
            _jsonAddress(address(venue)), DEPLOYMENTS, string.concat(".", network, ".buybackVenue")
        );
    }

    /// The network this chain id deploys into, or a revert. Mainnet needs `ALLOW_MAINNET_DEPLOY`,
    /// which is read by the caller so the rule itself can be checked without an environment.
    function guardNetwork(uint256 chainId, bool allowMainnet)
        public
        pure
        returns (string memory network)
    {
        if (chainId == RH_MAINNET) {
            if (!allowMainnet) revert MainnetNotAuthorized();
            return "robinhoodMainnet";
        }
        if (chainId == RH_TESTNET) return "robinhoodTestnet";
        revert UnsupportedChain(chainId);
    }

    /// The Safe the network's admin calls go through: whichever of the record's `owner` and
    /// `pendingOwner` is a contract, `owner` first, which is the rule `ops/rh-safe-exec.sh` uses to
    /// pick the Safe it signs for. The burner's venue, cap and keeper are all owner calls, so it
    /// has to land on the account that will make them. A network whose factories are held by an
    /// ordinary account has no Safe to execute through, and there the deployer keeps it.
    function _governanceOwner(string memory network) private view returns (address) {
        string memory record = vm.readFile(DEPLOYMENTS);
        address[2] memory candidates = [
            vm.parseJsonAddress(record, _path(network, "owner")),
            vm.parseJsonAddress(record, _path(network, "pendingOwner"))
        ];
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i].code.length > 0) return candidates[i];
        }
        return tx.origin;
    }

    /// True when this run will record itself in deployments.json. A dry run or a test prints the
    /// addresses and writes nothing, so the committed record only ever names contracts on chain.
    function _writesDeployments() private view returns (bool) {
        return
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    function _required(string memory variableName) private view returns (address value) {
        value = vm.envOr(variableName, address(0));
        if (value == address(0)) revert DeploymentAddressRequired(variableName);
    }

    /// An environment override, or the network's own entry in deployments.json. Reading the record
    /// rather than repeating its addresses here means a factory redeploy cannot leave this script
    /// pointing at a retired hook.
    function _resolve(string memory variableName, string memory network, string memory field)
        private
        view
        returns (address value)
    {
        value = vm.envOr(variableName, address(0));
        if (value != address(0)) return value;
        value = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), _path(network, field));
        if (value == address(0)) revert DeploymentAddressRequired(variableName);
    }

    function _recordUint(string memory network, string memory field)
        private
        view
        returns (uint256)
    {
        return vm.parseJsonUint(vm.readFile(DEPLOYMENTS), _path(network, field));
    }

    function _recordInt(string memory network, string memory field) private view returns (int256) {
        return vm.parseJsonInt(vm.readFile(DEPLOYMENTS), _path(network, field));
    }

    function _path(string memory network, string memory field)
        private
        pure
        returns (string memory)
    {
        return string.concat(".", network, ".", field);
    }

    /// writeJson takes a JSON document, so a bare address has to arrive quoted.
    function _jsonAddress(address value) private pure returns (string memory) {
        return string.concat('"', vm.toString(value), '"');
    }
}
