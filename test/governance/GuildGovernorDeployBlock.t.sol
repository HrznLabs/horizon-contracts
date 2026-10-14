// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GuildXP} from "../../src/governance/GuildXP.sol";
import {GuildGovernor} from "../../src/governance/GuildGovernor.sol";
import {GuildGovernorSimple} from "../../src/governance/GuildGovernorSimple.sol";
import {GuildGovernorFactory} from "../../src/governance/GuildGovernorFactory.sol";
import {GuildGovernorFactorySimple} from "../../src/governance/GuildGovernorFactorySimple.sol";
import {GuildGovernorDeployer, GuildTimelockDeployer} from "../../src/governance/GovernanceDeployers.sol";

/// @notice Issue #969: GuildXPVotes keyed its initial XP-source / quorum checkpoints at the
///         deployment block. OZ `propose` reads the proposer's votes at `clock() - 1`, which then
///         resolved the XP source to address(0) and reverted, so a factory-deployed governor
///         could not accept a proposal in its deployment block. FAILED BEFORE FIX (both
///         factories: the propose call reverted).
contract GuildGovernorDeployBlockTest is Test {
    GuildXP xp;
    GuildGovernorFactory factory;
    GuildGovernorFactorySimple simpleFactory;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address guild = makeAddr("guild");
    address guild2 = makeAddr("guild2");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint48 constant VOTING_DELAY = 1;
    uint32 constant VOTING_PERIOD = 10;
    uint256 constant THRESHOLD = 100;
    uint256 constant QUORUM_PCT = 20;

    function setUp() public {
        vm.roll(100);
        xp = new GuildXP(admin, relayer);
        factory = new GuildGovernorFactory(
            address(xp), address(new GuildTimelockDeployer()), address(new GuildGovernorDeployer())
        );
        simpleFactory = new GuildGovernorFactorySimple(address(xp));
        vm.startPrank(relayer);
        xp.updateXP(guild, alice, 600);
        xp.updateXP(guild, bob, 400);
        xp.updateXP(guild2, alice, 600);
        xp.updateXP(guild2, bob, 400);
        vm.stopPrank();
        vm.roll(block.number + 1); // XP is in a past block before the governors exist
    }

    function _calls() internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(0xdead);
    }

    function _proposeAndPass(IGovernor gov) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _calls();
        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, "deploy-block proposal");
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Pending));
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(alice);
        gov.castVote(id, 1);
        assertEq(gov.getVotes(alice, gov.proposalSnapshot(id)), 600);
        assertEq(gov.quorum(gov.proposalSnapshot(id)), (1000 * QUORUM_PCT) / 100);
        vm.roll(block.number + VOTING_PERIOD);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_FactoryDeployedGovernor_AcceptsProposalInDeploymentBlock() public {
        (address governor,) = factory.deployGovernanceWithParams(
            guild, VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT, 1 hours
        );
        // Same block as the deployment: the threshold lookup at clock()-1 must resolve.
        assertEq(GuildGovernor(payable(governor)).getVotes(alice, block.number - 1), 600);
        _proposeAndPass(IGovernor(governor));
    }

    function test_SimpleFactoryDeployedGovernor_AcceptsProposalInDeploymentBlock() public {
        address governor = simpleFactory.deployGovernanceWithParams(
            guild2, VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT
        );
        _proposeAndPass(IGovernor(governor));
    }

    /// @notice The constructor values are the baseline at every past timepoint; setters stay
    ///         keyed at clock()+1 (ABI unchanged).
    function test_InitialCheckpoints_CoverPastTimepoints() public {
        GuildGovernorSimple gov =
            new GuildGovernorSimple(guild, address(xp), VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT);
        assertEq(gov.quorumNumerator(0), QUORUM_PCT);
        assertEq(gov.quorumNumerator(block.number - 1), QUORUM_PCT);
        assertEq(gov.quorumNumerator(), QUORUM_PCT);
        assertEq(address(gov.xpContract()), address(xp));
        assertEq(gov.quorum(block.number - 1), (1000 * QUORUM_PCT) / 100);
    }
}
