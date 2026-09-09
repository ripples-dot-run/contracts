#!/usr/bin/env bash
# The whole contract suite, in two passes.
#
# `vm.setEnv` writes the real process environment and forge runs suites in parallel, so the fork
# suites and the plain ones cannot share a process: `_mainnetEnv` in DeployScriptFork points WETH
# at canonical WETH, and a DeployScript run that reads it mid-flight reverts `NoCodeAt` in an EVM
# where nothing is deployed there. It surfaces as roughly one failure in a full local run and
# never in CI, which runs only the first pass.
set -euo pipefail
cd "$(dirname "$0")"

forge test --no-match-path 'test/*Fork.t.sol' "$@"
forge test --match-path 'test/*Fork.t.sol' "$@"
