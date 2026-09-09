// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The deploying factory, read by curves and lockers at payout time so an admin rotation
/// there reaches launches that are already live, and by the graduation hook to authorize the
/// caller opening a launch's pool.
///
/// **Append only.** Every function below is called live by a contract that is already deployed;
/// reordering or removing one silently changes what an in-flight payout reads. A new capability
/// is a new function at the end of this list, never an edit to the four above it.
interface ITokenLaunchpad {
    function owner() external view returns (address);
    function treasury() external view returns (address);
    /// The graduation hook every launch's pool is keyed to. Zero until the operator sets it.
    function graduationHook() external view returns (address);
    /// The launch token a factory-deployed locker graduates, or zero for any other address.
    function lockerToken(address locker) external view returns (address);
    /// The shared `IQuoteRegistry` this factory validates a launch's settlement asset against,
    /// or zero on a v1 factory that predates per-launch quotes. Read at **create only**: a
    /// curve, a locker and a collection each capture their quote at construction and never ask
    /// again, so revoking a quote here cannot reach a market that is already trading.
    function quoteRegistry() external view returns (address);
}
