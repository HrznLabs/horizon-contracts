// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GuildGovernorFactory} from "../../src/governance/GuildGovernorFactory.sol";
import {GuildGovernorFactorySimple} from "../../src/governance/GuildGovernorFactorySimple.sol";
import {GuildXPMock} from "../../src/governance/GuildXPMock.sol";

/// @notice Minimal stand-in for GuildDAO's admin check.
contract MockGuildDAO {
    mapping(address => bool) public admins;

    function setAdmin(address account, bool ok) external {
        admins[account] = ok;
    }

    function isAdmin(address account) external view returns (bool) {
        return admins[account];
    }
}

/// @notice A "guild" address with no isAdmin() at all (e.g. an EOA-controlled contract).
contract NoAdminGuild {}

/**
 * @title GuildGovernorFactoryAccessTest
 * @notice Audit M7 — `deployGovernance` / `deployGovernanceWithParams` were permissionless
 *         and wrote a one-shot mapping entry, so anyone could squat a guild's governance
 *         slot with adversarial parameters (quorum 0, no timelock delay).
 */
contract GuildGovernorFactoryAccessTest is Test {
    GuildGovernorFactory factory;
    GuildGovernorFactorySimple simpleFactory;
    GuildXPMock xp;
    MockGuildDAO guild;

    address factoryOwner = address(this); // both factories are Ownable(msg.sender)
    address guildAdmin = makeAddr("guildAdmin");
    address attacker = makeAddr("attacker");

    function setUp() public {
        xp = new GuildXPMock();
        factory = new GuildGovernorFactory(address(xp));
        simpleFactory = new GuildGovernorFactorySimple(address(xp));

        guild = new MockGuildDAO();
        guild.setAdmin(guildAdmin, true);
    }

    // =========================================================================
    // GuildGovernorFactory (governor + timelock)
    // =========================================================================

    /// @notice FAILED BEFORE FIX: the attacker's call succeeded and permanently occupied
    ///         the guild's governance slot.
    function test_M7_Deploy_ByStranger_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(GuildGovernorFactory.NotGuildAdmin.selector);
        factory.deployGovernance(address(guild));

        assertFalse(factory.hasGovernance(address(guild)));
    }

    function test_M7_DeployWithParams_ByStranger_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(GuildGovernorFactory.NotGuildAdmin.selector);
        factory.deployGovernanceWithParams(address(guild), 1, 50_400, 100, 0, 0);

        assertFalse(factory.hasGovernance(address(guild)));
    }

    function test_M7_Deploy_ByGuildAdmin_Succeeds() public {
        vm.prank(guildAdmin);
        (address governor, address timelock) = factory.deployGovernance(address(guild));

        assertTrue(governor != address(0));
        assertTrue(timelock != address(0));
        assertTrue(factory.hasGovernance(address(guild)));
    }

    function test_M7_Deploy_ByFactoryOwner_Succeeds() public {
        (address governor, ) = factory.deployGovernance(address(guild));
        assertTrue(governor != address(0));
    }

    /// @notice The owner can bootstrap governance for a guild that has no isAdmin().
    function test_M7_Deploy_NoAdminInterface_OwnerOnly() public {
        NoAdminGuild plain = new NoAdminGuild();

        vm.prank(attacker);
        vm.expectRevert(GuildGovernorFactory.NotGuildAdmin.selector);
        factory.deployGovernance(address(plain));

        (address governor, ) = factory.deployGovernance(address(plain));
        assertTrue(governor != address(0));
    }

    function test_M7_Deploy_ZeroGuild_Reverts() public {
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.deployGovernance(address(0));
    }

    /// @notice FAILED BEFORE FIX: quorumPercent = 0 was accepted, producing a governor
    ///         where any single vote meets quorum.
    function test_M7_Deploy_ZeroQuorum_Reverts() public {
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.deployGovernanceWithParams(address(guild), 1, 50_400, 100, 0, 1 days);
    }

    function test_M7_Deploy_BelowMinQuorum_Reverts() public {
        uint256 belowMin = factory.MIN_QUORUM_PERCENT() - 1;
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.deployGovernanceWithParams(address(guild), 1, 50_400, 100, belowMin, 1 days);
    }

    /// @notice FAILED BEFORE FIX: a zero timelock delay made execution instant.
    function test_M7_Deploy_ZeroTimelockDelay_Reverts() public {
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.deployGovernanceWithParams(address(guild), 1, 50_400, 100, 10, 0);
    }

    function test_M7_Deploy_ZeroVotingPeriod_Reverts() public {
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.deployGovernanceWithParams(address(guild), 1, 0, 100, 10, 1 days);
    }

    function test_M7_Deploy_Twice_Reverts() public {
        vm.prank(guildAdmin);
        factory.deployGovernance(address(guild));

        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactory.GovernanceAlreadyDeployed.selector);
        factory.deployGovernance(address(guild));
    }

    function test_M7_SetDefaults_BelowMinQuorum_Reverts() public {
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.setDefaults(1, 50_400, 100, 0, 1 days);
    }

    function test_M7_SetDefaults_BelowMinTimelock_Reverts() public {
        vm.expectRevert(GuildGovernorFactory.InvalidParameters.selector);
        factory.setDefaults(1, 50_400, 100, 10, 1 minutes);
    }

    // =========================================================================
    // GuildGovernorFactorySimple (no timelock)
    // =========================================================================

    function test_M7_Simple_Deploy_ByStranger_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(GuildGovernorFactorySimple.NotGuildAdmin.selector);
        simpleFactory.deployGovernance(address(guild));

        assertFalse(simpleFactory.hasGovernance(address(guild)));
    }

    function test_M7_Simple_Deploy_ByGuildAdmin_Succeeds() public {
        vm.prank(guildAdmin);
        address governor = simpleFactory.deployGovernance(address(guild));
        assertTrue(governor != address(0));
        assertTrue(simpleFactory.hasGovernance(address(guild)));
    }

    function test_M7_Simple_Deploy_ByFactoryOwner_Succeeds() public {
        address governor = simpleFactory.deployGovernance(address(guild));
        assertTrue(governor != address(0));
    }

    function test_M7_Simple_Deploy_ZeroQuorum_Reverts() public {
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactorySimple.InvalidParameters.selector);
        simpleFactory.deployGovernanceWithParams(address(guild), 1, 50_400, 100, 0);
    }

    function test_M7_Simple_Deploy_ZeroVotingPeriod_Reverts() public {
        vm.prank(guildAdmin);
        vm.expectRevert(GuildGovernorFactorySimple.InvalidParameters.selector);
        simpleFactory.deployGovernanceWithParams(address(guild), 1, 0, 100, 10);
    }

    function test_M7_Simple_SetDefaults_BelowMinQuorum_Reverts() public {
        vm.expectRevert(GuildGovernorFactorySimple.InvalidParameters.selector);
        simpleFactory.setDefaults(1, 50_400, 100, 0);
    }
}
