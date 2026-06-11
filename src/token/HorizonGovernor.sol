// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title HorizonGovernor
/// @notice Protocol-level on-chain governance backed by HRZN token voting power.
/// @dev Uses OZ Governor v5 multi-extension pattern (mirrors GuildGovernor's override structure).
///
///      Settings (adjustable via governance):
///        - votingDelay:       1 day  (in seconds — HorizonToken uses timestamp clock)
///        - votingPeriod:      5 days
///        - proposalThreshold: 100,000 HRZN (100_000e18)
///        - quorum:            4% of total supply at snapshot time
///
///      Execution: proposals are queued in HorizonTimelock (2-day min delay) before execution.
contract HorizonGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /// @param _token    HorizonToken address (implements IVotes / ERC20Votes)
    /// @param _timelock HorizonTimelock address
    constructor(
        IVotes _token,
        TimelockController _timelock
    )
        Governor("HorizonGovernor")
        GovernorSettings(
            1 days,          // votingDelay  — 1 day before voting opens
            5 days,          // votingPeriod — 5 days to cast votes
            100_000e18       // proposalThreshold — 100k HRZN to propose
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4) // 4% quorum of total supply
        GovernorTimelockControl(_timelock)
    {}

    // =============================================================================
    // CLOCK — timestamp mode (must match HorizonToken's clock)
    // =============================================================================

    /// @notice Returns the current block timestamp cast to uint48.
    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice Returns the ERC-6372 clock mode string.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override(Governor, GovernorVotes) returns (string memory) {
        return "mode=timestamp";
    }

    // =============================================================================
    // REQUIRED OVERRIDES — resolve OZ v5 diamond-inheritance ambiguity
    // =============================================================================

    function votingDelay()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
