// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GuildGovernorFactory} from "../../src/governance/GuildGovernorFactory.sol";
import {GuildGovernorFactorySimple} from "../../src/governance/GuildGovernorFactorySimple.sol";
import {GuildGovernorDeployer, GuildTimelockDeployer} from "../../src/governance/GovernanceDeployers.sol";
import {GuildTimelock} from "../../src/governance/GuildTimelock.sol";
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
        // #832: the Governor/Timelock creation bytecode lives in external deployer
        // shims so the factory itself fits under EIP-170.
        factory = new GuildGovernorFactory(
            address(xp),
            address(new GuildTimelockDeployer()),
            address(new GuildGovernorDeployer())
        );
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

    // =========================================================================
    // #832 — EIP-170 size regression + deployer wiring
    // =========================================================================

    /// @notice The factory must stay deployable: EIP-170 caps runtime code at
    ///         24,576 bytes. Before #832's fix the embedded Governor+Timelock
    ///         creation bytecode put it at 25,507 (deploys revert on mainnet;
    ///         forge's local EVM is laxer, so we assert the size explicitly).
    function test_832_FactoryRuntime_UnderEip170Limit() public view {
        assertLe(address(factory).code.length, 24_576, "factory exceeds EIP-170");
    }

    function test_832_Deployers_RejectedWhenZero() public {
        // Deploy shims BEFORE expectRevert — a `new` inside the argument list is
        // itself a call and would consume the expectation.
        address gd = address(new GuildGovernorDeployer());
        address td = address(new GuildTimelockDeployer());
        vm.expectRevert(GuildGovernorFactory.InvalidDeployer.selector);
        new GuildGovernorFactory(address(xp), address(0), gd);
        vm.expectRevert(GuildGovernorFactory.InvalidDeployer.selector);
        new GuildGovernorFactory(address(xp), td, address(0));
    }

    /// @notice End-to-end wiring through the deployer shims: governor and timelock
    ///         deploy, the mappings fill, the governor holds PROPOSER/CANCELLER on
    ///         the timelock, and the factory has renounced its temporary admin role.
    function test_832_DeployViaShims_RolesWiredAndAdminRenounced() public {
        vm.prank(guildAdmin);
        (address governor, address timelock) = factory.deployGovernance(address(guild));

        assertEq(factory.guildGovernors(address(guild)), governor);
        assertEq(factory.guildTimelocks(address(guild)), timelock);
        assertGt(governor.code.length, 0);
        assertGt(timelock.code.length, 0);

        GuildTimelock tl = GuildTimelock(payable(timelock));
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), governor), "governor lacks PROPOSER");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), governor), "governor lacks CANCELLER");
        assertFalse(
            tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(factory)),
            "factory kept timelock admin"
        );
    }
}
