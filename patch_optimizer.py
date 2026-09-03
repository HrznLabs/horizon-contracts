import re

with open("src/governance/GuildGovernorFactory.sol", "r") as f:
    content = f.read()

# Let's remove the whole defaults mechanism to save code size

content = content.replace(
"""    /// @notice Default governance parameters
    uint48 public defaultVotingDelay = 1; // 1 block (~2 seconds on Base)
    uint32 public defaultVotingPeriod = 50_400; // ~1 week at 12s blocks
    uint256 public defaultProposalThreshold = 100; // 100 XP to propose
    uint256 public defaultQuorum = 10; // 10% quorum
    uint256 public defaultTimelockDelay = 1 days;""", "")

content = content.replace(
"""    event DefaultsUpdated(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorum,
        uint256 timelockDelay
    );""", "")

content = content.replace(
"""    /**
     * @notice Deploy governance for a guild with default parameters
     * @param guildDAO Address of the GuildDAO contract
     * @return governor Address of deployed GuildGovernor
     * @return timelock Address of deployed GuildTimelock
     */
    function deployGovernance(address guildDAO) external returns (address governor, address timelock) {
        return deployGovernanceWithParams(
            guildDAO,
            defaultVotingDelay,
            defaultVotingPeriod,
            defaultProposalThreshold,
            defaultQuorum,
            defaultTimelockDelay
        );
    }""", "")

content = content.replace(
"""    /**
     * @notice Update default governance parameters
     */
    function setDefaults(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorum,
        uint256 timelockDelay
    ) external onlyOwner {
        if (quorum > 100) revert InvalidParameters();

        defaultVotingDelay = votingDelay;
        defaultVotingPeriod = votingPeriod;
        defaultProposalThreshold = proposalThreshold;
        defaultQuorum = quorum;
        defaultTimelockDelay = timelockDelay;

        emit DefaultsUpdated(votingDelay, votingPeriod, proposalThreshold, quorum, timelockDelay);
    }""", "")

content = content.replace(
"""    /**
     * @notice Get default parameters
     */
    function getDefaults() external view returns (uint48, uint32, uint256, uint256, uint256) {
        return (defaultVotingDelay, defaultVotingPeriod, defaultProposalThreshold, defaultQuorum, defaultTimelockDelay);
    }""", "")

with open("src/governance/GuildGovernorFactory.sol", "w") as f:
    f.write(content)
