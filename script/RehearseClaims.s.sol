// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CollectionParams, Collection721, Mode } from "../src/Collection721.sol";
import { LaunchParams, LinkedParams, TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { LPLocker } from "../src/LPLocker.sol";
import { ObjectVesting } from "../src/ObjectVesting.sol";

/// A rehearsal of the claims generation against a live network: one launch whose vest belongs to
/// the piece, a mint on it, a later drop attached to the same market, a mint on that, and the
/// reads a claim page is built on.
///
/// It proves the three things a unit test cannot: that the deployed factory takes the tuple this
/// build encodes, that a wave binds to a raise that is already running, and that
/// `claimableOwnedBy` answers over real ids held by a real wallet.
///
///   Environment:
///     TOKEN_LAUNCH_FACTORY   the factory to rehearse against
///     REHEARSAL_QUOTE        the settlement asset, which pays the fee and the mints
contract RehearseClaims is Script {
    /// What a piece costs in the rehearsal, in the quote's own units. It has to clear the
    /// registry row's floor, and on a live network it is worth keeping small: every mint here is
    /// real money into a real market.
    function price() internal view returns (uint256) {
        return vm.envOr("REHEARSAL_PRICE", uint256(0.01e18));
    }

    function run() external {
        TokenLaunchFactory factory = TokenLaunchFactory(vm.envAddress("TOKEN_LAUNCH_FACTORY"));
        IERC20 quote = IERC20(vm.envAddress("REHEARSAL_QUOTE"));
        address me = msg.sender;

        LaunchParams memory tp;
        tp.name = "Claims rehearsal";
        tp.symbol = "CLR";
        tp.curveSupply = 800_000_000e18;
        tp.lpTokenSupply = 265_000_000e18;
        tp.vQuoteInit = 5.25e18;
        tp.vTokenInit = 1_073_000_000e18;
        tp.graduationQuote = 4.2e18;
        tp.logo = "https://ripples.run/icon.png";

        LinkedParams memory lp = LinkedParams({
            nftAllocationBps: 500,
            mintToCurveBps: 2_000,
            vestDuration: 365 days,
            vestCliff: 30 days,
            objectClaim: true,
            wavesOpen: true
        });

        vm.startBroadcast();
        quote.approve(address(factory), type(uint256).max);
        (, address locker, address collection, address vesting) =
            factory.createLinkedLaunch(tp, _drop("Rehearsal genesis", "RG1"), lp);

        quote.approve(collection, type(uint256).max);
        Collection721(collection).mint(2, 0);

        address wave = factory.launchWave(locker, _drop("Rehearsal season two", "RG2"), 1_000);
        quote.approve(wave, type(uint256).max);
        Collection721(wave).mint(1, 0);
        vm.stopBroadcast();

        console2.log("locker             ", locker);
        console2.log("genesis collection ", collection);
        console2.log("wave collection    ", wave);
        console2.log("vesting            ", vesting);
        console2.log("object claim       ", Collection721(collection).objectClaim());
        console2.log("wave object claim  ", Collection721(wave).objectClaim());
        console2.log("collections routing", LPLocker(locker).linkedCollectionCount());
        console2.log("recorders          ", ObjectVesting(vesting).recorderCount());
        console2.log("routed so far      ", LPLocker(locker).contributedQuote());
        console2.log("piece 1 contributed", ObjectVesting(vesting).contribution(collection, 1));
        console2.log("piece 2 contributed", ObjectVesting(vesting).contribution(collection, 2));
        console2.log("wave 1 contributed ", ObjectVesting(vesting).contribution(wave, 1));
    }

    function _drop(string memory name, string memory symbol)
        private
        view
        returns (CollectionParams memory np)
    {
        np.name = name;
        np.symbol = symbol;
        np.priceQuote = price();
        np.maxSupply = 1_000;
        np.mode = Mode.PREGEN;
        np.baseURI = "https://ripples.run/rehearsal/";
        np.placeholderURI = "https://ripples.run/rehearsal/placeholder.json";
        np.royaltyBps = 500;
        np.quote = vm.envAddress("REHEARSAL_QUOTE");
    }
}
