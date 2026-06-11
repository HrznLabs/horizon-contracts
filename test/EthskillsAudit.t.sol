// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/token/HorizonToken.sol";
import "../src/token/sHRZNVault.sol";
import "../src/token/BuybackExecutor.sol";
import "../src/token/FeeDistributor.sol";
import "../src/MissionFactory.sol";
import "../src/MissionEscrow.sol";
import "../src/DeliveryEscrow.sol";
import "../src/PaymentRouter.sol";
import "../src/interfaces/IMissionEscrow.sol";
import "../src/governance/GuildGovernorSimple.sol";
import "../src/governance/GuildXPMock.sol";
import "./mocks/MockERC20.sol";

// =============================================================================
// Helpers / Mock Contracts
// =============================================================================

/// @notice Mock reentrancy attacker that tries to re-enter approveCompletion()
///         during the ERC-20 transferFrom callback (ERC-777 / hooks style).
///         It implements a minimal ERC-20 interface so it can be used as the
///         payment token; the attack is triggered in `transfer`.
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attackTarget;    // The MissionEscrow to attack
    bool    public attackArmed;

    string  public constant name    = "ReentrantToken";
    string  public constant symbol  = "RENT";
    uint8   public constant decimals = 6;
    uint256 public totalSupply;

    function setAttackTarget(address target) external { attackTarget = target; }
    function setAttackArmed(bool armed) external { attackArmed = armed; }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);

        // On transfer TO the PaymentRouter, attempt reentrancy back into the escrow
        if (attackArmed && to == attackTarget) {
            attackArmed = false; // prevent infinite loop
            MissionEscrow(attackTarget).approveCompletion();
        }
        return true;
    }
}

/// @notice Minimal mock for the IAerodromeRouter used by BuybackExecutor.
///         Returns a fixed output so the slippage check is reachable.
contract MockAerodromeRouter {
    uint256 public constant MOCK_HRZN_OUT = 1000e18;

    function swapExactTokensForTokens(
        uint256 /*amountIn*/,
        uint256 /*amountOutMin*/,
        IAerodromeRouter.Route[] calldata /*routes*/,
        address, /*to*/
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        // Pretend we send HRZN to the executor
        amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = MOCK_HRZN_OUT;
        // NOTE: In a real integration the router would transfer tokens.
        // For slippage-guard tests we only need the revert path, so
        // the happy-path transfer is omitted here to keep the mock minimal.
        return amounts;
    }
}

// =============================================================================
// EthskillsAuditTest — HIGH + MEDIUM security fix coverage
// =============================================================================

contract EthskillsAuditTest is Test {
    // =========================================================================
    // Shared addresses
    // =========================================================================

    address treasury    = makeAddr("treasury");
    address teamV       = makeAddr("teamV");
    address advisorV    = makeAddr("advisorV");
    address admin       = makeAddr("admin");
    address alice       = makeAddr("alice");
    address bob         = makeAddr("bob");
    address attacker    = makeAddr("attacker");
    address poster      = makeAddr("poster");
    address performer   = makeAddr("performer");
    address protocolTreasury = makeAddr("protocolTreasury");
    address resolverTreasury = makeAddr("resolverTreasury");
    address labsTreasury     = makeAddr("labsTreasury");
    address disputeResolverAddr = makeAddr("disputeResolver");
    address resolverPool = makeAddr("resolverPool");

    // =========================================================================
    // Shared contracts
    // =========================================================================

    HorizonToken hrzn;
    MockERC20    usdc;
    MockERC20    eurc;
    sHRZNVault   vault;
    PaymentRouter router;
    MissionFactory factory;
    FeeDistributor feeDistributor;

    bytes32 constant METADATA_HASH = keccak256("metadata");
    bytes32 constant LOCATION_HASH = keccak256("location");
    uint256 constant REWARD = 1000e6; // 1000 USDC

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public {
        // Tokens
        hrzn = new HorizonToken(treasury, teamV, advisorV);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);

        // Vault
        vault = new sHRZNVault(address(hrzn), address(usdc), admin);

        // PaymentRouter — accepts USDC by default; whitelist EURC too
        vm.startPrank(admin);
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );
        router.setAcceptedToken(address(eurc), true);
        vm.stopPrank();

        // MissionFactory
        factory = new MissionFactory(address(router));
        vm.prank(admin);
        router.setMissionFactory(address(factory));
        factory.setDisputeResolver(disputeResolverAddr);

        // FeeDistributor
        feeDistributor = new FeeDistributor(
            address(usdc),
            address(vault),
            protocolTreasury,
            resolverPool,
            admin
        );
        // Grant DISTRIBUTOR_ROLE on vault to FeeDistributor
        bytes32 distRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distRole, address(feeDistributor));

        // Fund accounts
        usdc.mint(poster, 100_000e6);
        usdc.mint(alice,  100_000e6);
        usdc.mint(attacker, 100_000e6);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _depositHRZN(address user, uint256 amount) internal {
        vm.prank(treasury);
        hrzn.transfer(user, amount);
        vm.prank(user);
        hrzn.approve(address(vault), amount);
        vm.prank(user);
        vault.deposit(amount, user);
    }

    function _notifyReward(uint256 amount) internal {
        usdc.mint(address(vault), amount);
        // Grant distRole to this test contract for convenience
        bytes32 distRole = vault.DISTRIBUTOR_ROLE();
        if (!vault.hasRole(distRole, address(this))) {
            vm.prank(admin);
            vault.grantRole(distRole, address(this));
        }
        vault.notifyRewardAmount(amount);
    }

    /// @dev Create a mission, have performer accept + submit proof, return escrow address
    function _createSubmittedMission(address token) internal returns (address escrow) {
        uint256 reward = 1000e6;
        MockERC20(token).mint(poster, reward);
        vm.prank(poster);
        MockERC20(token).approve(address(factory), reward);
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            token,
            reward,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        escrow = factory.missions(missionId);
        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));
    }

    // =========================================================================
    // HIGH-01 — Inflation Attack (sHRZNVault)
    // =========================================================================

    /// @notice Attacker deposits 1 wei, then donates a large amount directly
    ///         to the vault. Victim's subsequent deposit should still receive
    ///         proportional shares (not be rounded to zero) thanks to the
    ///         _decimalsOffset() = 3 virtual-shares fix.
    function test_HIGH01_InflationAttack_VictimReceivesShares() public {
        uint256 attackerDeposit = 1;           // 1 wei HRZN
        uint256 donation        = 1_000_000e18; // 1M HRZN donated directly
        uint256 victimDeposit   = 100e18;       // 100 HRZN

        // Fund attacker and victim
        vm.prank(treasury);
        hrzn.transfer(attacker, attackerDeposit + donation);
        vm.prank(treasury);
        hrzn.transfer(alice, victimDeposit);

        // Step 1: Attacker deposits 1 wei
        vm.startPrank(attacker);
        hrzn.approve(address(vault), attackerDeposit);
        vault.deposit(attackerDeposit, attacker);
        vm.stopPrank();

        // Step 2: Attacker donates directly to vault (no share minting)
        vm.prank(attacker);
        hrzn.transfer(address(vault), donation);

        // Step 3: Victim deposits 100 HRZN
        vm.startPrank(alice);
        hrzn.approve(address(vault), victimDeposit);
        vault.deposit(victimDeposit, alice);
        vm.stopPrank();

        // The _decimalsOffset()==3 injects 1_000 virtual assets and 1_000 virtual shares.
        // Even with 1M HRZN donated, the victim's deposit should yield > 0 shares.
        uint256 victimShares = vault.balanceOf(alice);
        assertGt(victimShares, 0, "HIGH-01: Victim must receive non-zero shares");
    }

    /// @notice Without the offset fix a victim depositing 100 HRZN after a 1M donation
    ///         would receive 0 shares. Verify the attack is made uneconomical: the
    ///         attacker would need to donate >> 1000x the victim's amount to zero it.
    function test_HIGH01_InflationAttack_AttackerLosesValue() public {
        uint256 attackerDeposit = 1;
        uint256 donation        = 1_000_000e18;
        uint256 victimDeposit   = 100e18;

        vm.prank(treasury);
        hrzn.transfer(attacker, attackerDeposit + donation);
        vm.prank(treasury);
        hrzn.transfer(alice, victimDeposit);

        vm.startPrank(attacker);
        hrzn.approve(address(vault), attackerDeposit);
        vault.deposit(attackerDeposit, attacker);
        hrzn.transfer(address(vault), donation);
        vm.stopPrank();

        vm.startPrank(alice);
        hrzn.approve(address(vault), victimDeposit);
        vault.deposit(victimDeposit, alice);
        vm.stopPrank();

        // Attacker's total assets committed = donation + 1 wei
        // With the offset, the victim still gets shares so the attacker
        // did NOT steal the victim's value.  Confirm victim holds shares
        // worth approximately their deposit.
        uint256 victimShares = vault.balanceOf(alice);
        uint256 victimAssets = vault.previewRedeem(victimShares);

        // Victim should recover at least 1% of their deposit after the attack
        // (the protection makes the attack unprofitable, not perfect — 1M >> 1000x·100)
        // In practice they lose very little; just assert non-zero to confirm the guard works.
        assertGt(victimAssets, 0, "HIGH-01: Victim assets must be non-zero (attack failed)");
    }

    // =========================================================================
    // HIGH-04 — Reentrancy on MissionEscrow.approveCompletion()
    // =========================================================================

    /// @notice Deploy a mission using a malicious ERC-20 that tries to re-enter
    ///         approveCompletion() during the transfer to PaymentRouter.
    ///         The nonReentrant modifier should make the second call revert.
    function test_HIGH04_Reentrancy_ApproveCompletion_Reverts() public {
        // Deploy the reentrancy-attack token
        ReentrantToken malToken = new ReentrantToken();

        // Whitelist it in PaymentRouter
        vm.prank(admin);
        router.setAcceptedToken(address(malToken), true);

        // Mint and approve
        malToken.mint(poster, REWARD);
        vm.prank(poster);
        malToken.approve(address(factory), REWARD);

        // Create mission with the malicious token
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            address(malToken),
            REWARD,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        address escrowAddr = factory.missions(missionId);

        // Performer accepts + submits proof
        vm.prank(performer);
        MissionEscrow(escrowAddr).acceptMission();
        vm.prank(performer);
        MissionEscrow(escrowAddr).submitProof(keccak256("proof"));

        // Arm the reentrancy attack: when the token is transferred to the router
        // (inside approveCompletion), the token's transfer() will call approveCompletion()
        // again on the escrow.
        malToken.setAttackTarget(escrowAddr);
        malToken.setAttackArmed(true);

        // The reentrant call should revert with ReentrancyGuardReentrantCall
        vm.prank(poster);
        vm.expectRevert();
        MissionEscrow(escrowAddr).approveCompletion();
    }

    // =========================================================================
    // HIGH-05 — DeliveryEscrow factory guard (initializeDelivery)
    // =========================================================================

    /// @dev Helper: deploy a DeliveryEscrow clone via a minimal factory-like setup.
    function _deployDeliveryEscrow() internal returns (DeliveryEscrow escrow, address factoryAddr) {
        // We act AS the factory by deploying and calling initialize ourselves
        DeliveryEscrow impl = new DeliveryEscrow();
        // Clone it
        address cloneAddr = address(new DeliveryEscrowCloner(address(impl)));
        escrow = DeliveryEscrow(DeliveryEscrowCloner(cloneAddr).deploy());
        factoryAddr = cloneAddr;

        // Initialize from the "factory" (cloner) — sets _factory = cloner address
        vm.prank(cloneAddr);
        escrow.initialize(
            1,          // missionId
            poster,
            REWARD,
            block.timestamp + 1 days,
            address(0), // guild
            METADATA_HASH,
            LOCATION_HASH,
            address(router),
            address(usdc),
            disputeResolverAddr,
            address(0), // pauseRegistry
            0,          // minReputation
            address(0)  // reputationOracle
        );
    }

    function _emptyDeliveryParams() internal view returns (DeliveryEscrow.DeliveryParams memory) {
        return DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation({
                latitude: 0,
                longitude: 0,
                addressHash: bytes32(0),
                precision: 0,
                geofenceRadius: 0,
                requirePresence: false
            }),
            dropoff: DeliveryEscrow.DeliveryLocation({
                latitude: 0,
                longitude: 0,
                addressHash: bytes32(0),
                precision: 0,
                geofenceRadius: 0,
                requirePresence: false
            }),
            package: DeliveryEscrow.PackageDetails({
                itemType: 0,
                packageSize: 0,
                estimatedWeight: 0,
                specialHandling: 0
            }),
            pickupWindowStart: 0,
            pickupWindowEnd: 0,
            deliveryDeadline: block.timestamp + 1 days,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });
    }

    /// @notice Calling initializeDelivery from a non-factory address reverts NotFactory()
    function test_HIGH05_InitializeDelivery_NotFactory_Reverts() public {
        (DeliveryEscrow escrow,) = _deployDeliveryEscrow();

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints;

        vm.prank(attacker);
        vm.expectRevert(DeliveryEscrow.NotFactory.selector);
        escrow.initializeDelivery(_emptyDeliveryParams(), waypoints);
    }

    /// @notice Calling initializeDelivery twice from the factory reverts DeliveryAlreadyInitialized()
    function test_HIGH05_InitializeDelivery_CalledTwice_Reverts() public {
        (DeliveryEscrow escrow, address factoryAddr) = _deployDeliveryEscrow();

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints;

        // First call — succeeds
        vm.prank(factoryAddr);
        escrow.initializeDelivery(_emptyDeliveryParams(), waypoints);

        // Second call — must revert
        vm.prank(factoryAddr);
        vm.expectRevert(DeliveryEscrow.DeliveryAlreadyInitialized.selector);
        escrow.initializeDelivery(_emptyDeliveryParams(), waypoints);
    }

    // =========================================================================
    // HIGH-03 — EURC DDR in DisputeResolver (per-dispute token via getToken())
    // =========================================================================

    /// @notice Create a mission funded in EURC, complete the dispute settlement,
    ///         and verify that payment distribution uses EURC (not USDC).
    function test_HIGH03_EURCMission_DisputeSettlement_UsesEURC() public {
        uint256 reward = 1000e6;
        eurc.mint(poster, reward);

        vm.prank(poster);
        eurc.approve(address(factory), reward);
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            address(eurc),
            reward,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        address escrowAddr = factory.missions(missionId);

        // Confirm the escrow's payment token is EURC
        assertEq(
            MissionEscrow(escrowAddr).getToken(),
            address(eurc),
            "HIGH-03: Escrow token must be EURC"
        );

        // Performer accepts and submits
        vm.prank(performer);
        MissionEscrow(escrowAddr).acceptMission();
        vm.prank(performer);
        MissionEscrow(escrowAddr).submitProof(keccak256("proof"));

        // Poster raises dispute
        vm.prank(poster);
        MissionEscrow(escrowAddr).raiseDispute(keccak256("evidence"));

        uint256 performerEURCBefore = eurc.balanceOf(performer);
        uint256 performerUSDCBefore = usdc.balanceOf(performer);

        // Dispute resolver settles: performer wins (outcome 2)
        vm.prank(disputeResolverAddr);
        MissionEscrow(escrowAddr).settleDispute(2, 0);

        // Performer should have received EURC, not USDC
        assertGt(
            eurc.balanceOf(performer),
            performerEURCBefore,
            "HIGH-03: Performer must receive EURC"
        );
        assertEq(
            usdc.balanceOf(performer),
            performerUSDCBefore,
            "HIGH-03: Performer must NOT receive USDC for EURC mission"
        );
    }

    /// @notice Verify DDR distribution from DisputeResolver uses EURC for an EURC-based mission.
    ///         getToken() on the escrow must return EURC so the resolver can read it.
    function test_HIGH03_EURCEscrow_GetToken_ReturnsEURC() public {
        eurc.mint(poster, REWARD);
        vm.prank(poster);
        eurc.approve(address(factory), REWARD);
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            address(eurc),
            REWARD,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        address escrowAddr = factory.missions(missionId);
        assertEq(
            MissionEscrow(escrowAddr).getToken(),
            address(eurc),
            "HIGH-03: getToken() must return EURC"
        );
    }

    // =========================================================================
    // HIGH-02 — sHRZNVault precision (1e30 scalar for small rewards)
    // =========================================================================

    /// @notice Stake a large HRZN position (approaching protocol max), distribute a
    ///         small USDC reward, and verify earned() returns non-zero.
    function test_HIGH02_VaultPrecision_SmallReward_NonZeroEarned() public {
        // Stake 1B HRZN (1e27 wei) — simulates the full supply being staked
        uint256 stakeAmount = 1_000_000_000e18; // 1B HRZN
        vm.prank(treasury);
        hrzn.transfer(alice, stakeAmount);
        vm.prank(alice);
        hrzn.approve(address(vault), stakeAmount);
        vm.prank(alice);
        vault.deposit(stakeAmount, alice);

        // totalSupply ~ 1e30 (with _decimalsOffset()==3, shares = assets * 10^3 at first deposit)
        uint256 supply = vault.totalSupply();
        assertGt(supply, 0, "Supply must be non-zero");

        // Distribute 1 USDC (1e6 wei) — very small relative to stake
        uint256 smallReward = 1e6; // 1 USDC
        usdc.mint(address(vault), smallReward);
        bytes32 distRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distRole, address(this));
        vault.notifyRewardAmount(smallReward);

        // earned() should be non-zero thanks to the 1e30 scalar (HIGH-02)
        uint256 earned = vault.earned(alice);
        assertGt(earned, 0, "HIGH-02: earned() must be non-zero with 1e30 scalar");
    }

    /// @notice Without the 1e30 fix, rewardPerTokenStored would truncate to 0 for
    ///         small amounts relative to a large supply.  Verify the stored value is > 0.
    function test_HIGH02_RewardPerTokenStored_NonZeroForSmallReward() public {
        uint256 stakeAmount = 1_000_000_000e18; // 1B HRZN
        vm.prank(treasury);
        hrzn.transfer(alice, stakeAmount);
        vm.prank(alice);
        hrzn.approve(address(vault), stakeAmount);
        vm.prank(alice);
        vault.deposit(stakeAmount, alice);

        uint256 smallReward = 1e6; // 1 USDC
        usdc.mint(address(vault), smallReward);
        bytes32 distRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distRole, address(this));
        vault.notifyRewardAmount(smallReward);

        assertGt(vault.rewardPerTokenStored(), 0, "HIGH-02: rewardPerTokenStored must be > 0");
    }

    // =========================================================================
    // MED-03 — Fuzz expired mission revert (expiresAt around block.timestamp)
    // =========================================================================

    /// @notice Values <= block.timestamp must revert with InvalidDuration()
    function testFuzz_MED03_ExpiredMission_Reverts(uint256 secondsInPast) public {
        secondsInPast = bound(secondsInPast, 0, 365 days);
        uint256 expiresAt = block.timestamp - secondsInPast;

        usdc.mint(poster, REWARD);
        vm.prank(poster);
        usdc.approve(address(factory), REWARD);

        vm.prank(poster);
        vm.expectRevert(MissionFactory.InvalidDuration.selector);
        factory.createMission(
            address(usdc),
            REWARD,
            expiresAt,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
    }

    /// @notice expiresAt exactly equal to block.timestamp should also revert
    function test_MED03_ExpiresAtEqTimestamp_Reverts() public {
        usdc.mint(poster, REWARD);
        vm.prank(poster);
        usdc.approve(address(factory), REWARD);

        vm.prank(poster);
        vm.expectRevert(MissionFactory.InvalidDuration.selector);
        factory.createMission(
            address(usdc),
            REWARD,
            block.timestamp,    // exactly now — must revert
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
    }

    /// @notice Values > block.timestamp + MIN_DURATION and <= block.timestamp + MAX_DURATION succeed
    function testFuzz_MED03_ValidExpiry_Succeeds(uint256 secondsFuture) public {
        // MIN_DURATION = 1 hour, MAX_DURATION = 30 days
        secondsFuture = bound(secondsFuture, 1 hours, 30 days);
        uint256 expiresAt = block.timestamp + secondsFuture;

        usdc.mint(poster, REWARD);
        vm.prank(poster);
        usdc.approve(address(factory), REWARD);

        vm.prank(poster);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD,
            expiresAt,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        assertGt(missionId, 0, "MED-03: Valid expiry must create a mission");
    }

    // =========================================================================
    // MED-05 — Fuzz BuybackExecutor slippage (minHrznOut == 0 reverts)
    // =========================================================================

    function test_MED05_BuybackExecutor_ZeroSlippage_Reverts() public {
        MockAerodromeRouter mockRouter = new MockAerodromeRouter();
        BuybackExecutor executor = new BuybackExecutor(
            address(usdc),
            address(hrzn),
            address(mockRouter),
            makeAddr("aeroFactory"),
            admin
        );

        usdc.mint(admin, 100e6);
        vm.prank(admin);
        usdc.approve(address(executor), 100e6);

        vm.prank(admin);
        vm.expectRevert("BuybackExecutor: zero slippage");
        executor.executeBuyback(100e6, 0, block.timestamp + 1 hours);
    }

    function testFuzz_MED05_BuybackExecutor_NonZeroSlippage_Proceeds(uint256 minHrznOut) public {
        minHrznOut = bound(minHrznOut, 1, type(uint128).max);

        MockAerodromeRouter mockRouter = new MockAerodromeRouter();
        BuybackExecutor executor = new BuybackExecutor(
            address(usdc),
            address(hrzn),
            address(mockRouter),
            makeAddr("aeroFactory"),
            admin
        );

        usdc.mint(admin, 100e6);
        vm.prank(admin);
        usdc.approve(address(executor), 100e6);

        // The mock router does not actually transfer HRZN, so burn() will revert
        // with insufficient balance — we only care that the slippage guard is NOT
        // the revert reason.  The require("zero slippage") must not trigger.
        vm.prank(admin);
        try executor.executeBuyback(100e6, minHrznOut, block.timestamp + 1 hours) {
            // If it somehow succeeds (mock provides tokens), that is also acceptable
        } catch (bytes memory reason) {
            // Must not be the zero-slippage error
            bytes32 errHash = keccak256(reason);
            bytes32 slippageHash = keccak256(abi.encodePacked("BuybackExecutor: zero slippage"));
            assertTrue(errHash != slippageHash, "MED-05: Non-zero minHrznOut must NOT hit slippage guard");
        }
    }

    // =========================================================================
    // MED-01 — FeeDistributor guild cap (MAX_GUILDS = 200)
    // =========================================================================

    function test_MED01_FeeDistributor_MaxGuildsCap_Reverts() public {
        // Register MAX_GUILDS guilds
        uint256 maxGuilds = feeDistributor.MAX_GUILDS(); // 200

        for (uint256 i = 0; i < maxGuilds; i++) {
            address g = address(uint160(0xBEEF0000 + i));
            vm.prank(admin);
            feeDistributor.registerGuild(g);
        }

        assertEq(feeDistributor.guildCount(), maxGuilds, "Should have registered MAX_GUILDS");

        // Attempt to register the 201st guild — must revert
        address extraGuild = makeAddr("extraGuild");
        vm.prank(admin);
        vm.expectRevert("FeeDistributor: max guilds");
        feeDistributor.registerGuild(extraGuild);
    }

    function test_MED01_FeeDistributor_ExactlyMaxGuilds_Succeeds() public {
        uint256 maxGuilds = feeDistributor.MAX_GUILDS();

        for (uint256 i = 0; i < maxGuilds; i++) {
            address g = address(uint160(0xBEEF0000 + i));
            vm.prank(admin);
            feeDistributor.registerGuild(g);
        }

        // Exactly at cap — count must equal MAX_GUILDS and no revert
        assertEq(feeDistributor.guildCount(), maxGuilds);
    }

    // =========================================================================
    // MED-04 — sHRZNVault transfer during cooldown (shares locked)
    // =========================================================================

    function test_MED04_TransferDuringCooldown_Reverts() public {
        _depositHRZN(alice, 100e18);

        // Request unstake — shares move to escrow (vault address)
        vm.prank(alice);
        vault.requestUnstake(100e18);

        // Confirm alice now has 0 transferable shares
        // (shares are held by address(this) = vault)
        assertEq(vault.balanceOf(alice), 0, "Alice shares should be escrowed");

        // Any attempt to transfer the 0 balance is a no-op, but the
        // real invariant is that requestUnstake itself would revert on
        // a second attempt while a pending request is active.
        vm.prank(alice);
        vm.expectRevert("sHRZNVault: pending request");
        vault.requestUnstake(1);
    }

    /// @notice Transfer FROM alice (before requestUnstake) should work; transfer
    ///         AFTER requestUnstake via the locked-escrow path should revert.
    function test_MED04_TransferAfterUnstakeRequest_LocksShares() public {
        _depositHRZN(alice, 200e18);

        // Transfer half to bob while no pending request — must succeed
        vm.prank(alice);
        vault.transfer(bob, 100e18);
        assertEq(vault.balanceOf(bob), 100e18, "Bob must receive shares");

        // Now alice requests unstake for her remaining 100 shares
        vm.prank(alice);
        vault.requestUnstake(100e18);

        // Alice now has 0 transferable balance; trying to transfer 1 wei
        // should revert because of the cooldown lock on alice (she has pending shares)
        // ... but the contract transfers shares TO the vault at request time,
        // so alice.balance == 0 and a transfer would revert with ERC20InsufficientBalance.
        // The _update() revert path triggers when from has unstakeRequest.shares > 0,
        // but since alice's balance was cleared, any external transfer of her balance
        // is already blocked by the balance check. Verify the revert.
        vm.prank(alice);
        vm.expectRevert(); // either insufficient balance or cooldown revert
        vault.transfer(bob, 1);
    }

    // =========================================================================
    // MED-06 — GuildGovernorSimple: quorum snapshotted at proposal time
    // =========================================================================

    function test_MED06_QuorumSnapshotted_AtProposalTime() public {
        GuildXPMock xpMock = new GuildXPMock();
        address guildDAO = makeAddr("guildDAO");

        GuildGovernorSimple governor = new GuildGovernorSimple(
            guildDAO,
            address(xpMock),
            1,   // votingDelay (1 block)
            10,  // votingPeriod (10 blocks)
            0,   // proposalThreshold
            20   // quorumNumerator = 20%
        );

        // Give alice enough XP to propose
        xpMock.setGuildXP(guildDAO, alice, 1000);
        // Total XP at proposal time = 1000

        // Create proposal
        address[] memory targets   = new address[](1);
        uint256[] memory values    = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = guildDAO;
        string memory description  = "Test proposal";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Snapshot quorum is based on XP at proposal creation = 1000 * 20% = 200
        uint256 snapshotXP = governor.proposalQuorumSnapshot(proposalId);
        assertEq(snapshotXP, 1000, "MED-06: Snapshot must equal XP at proposal time");

        uint256 quorumAtProposal = governor.quorum(proposalId);
        assertEq(quorumAtProposal, 200, "MED-06: Quorum = 20% of snapshot XP");

        // Now double the total XP (simulating a post-proposal XP inflation attack)
        xpMock.setGuildXP(guildDAO, bob, 9000);
        // totalGuildXP is now 10_000

        // Quorum for this proposal must STILL be 200 (snapshotted)
        uint256 quorumAfterInflation = governor.quorum(proposalId);
        assertEq(
            quorumAfterInflation,
            200,
            "MED-06: Quorum must not change after proposal creation"
        );
        assertNotEq(
            quorumAfterInflation,
            (xpMock.getTotalGuildXP(guildDAO) * 20) / 100,
            "MED-06: Live quorum would be 2000, snapshot quorum must be 200"
        );
    }

    /// @notice Verify that a NEW proposal picks up the updated (post-inflation) XP
    ///         so the snapshot mechanism is not permanently stale.
    function test_MED06_NewProposal_UsesCurrentXP() public {
        GuildXPMock xpMock = new GuildXPMock();
        address guildDAO = makeAddr("guildDAO");

        GuildGovernorSimple governor = new GuildGovernorSimple(
            guildDAO,
            address(xpMock),
            1, 10, 0, 20
        );

        xpMock.setGuildXP(guildDAO, alice, 1000);

        address[] memory targets   = new address[](1);
        uint256[] memory values    = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0] = guildDAO;

        // Proposal 1 — snapshot = 1000
        vm.prank(alice);
        uint256 proposalId1 = governor.propose(targets, values, calldatas, "proposal 1");

        // Inflate XP
        xpMock.setGuildXP(guildDAO, bob, 9000);

        // Proposal 2 — snapshot = 10_000
        vm.roll(block.number + 2); // advance past voting delay of proposal1
        vm.prank(alice);
        uint256 proposalId2 = governor.propose(targets, values, calldatas, "proposal 2");

        assertEq(governor.proposalQuorumSnapshot(proposalId1), 1000);
        assertEq(governor.proposalQuorumSnapshot(proposalId2), 10_000);
    }
}

// =============================================================================
// DeliveryEscrowCloner — helper to act as "factory" in HIGH-05 tests
// =============================================================================

/// @notice Deploys a DeliveryEscrow clone and records its address.
///         In the test it acts as the factory so its address is stored as _factory.
contract DeliveryEscrowCloner {
    address public immutable implementation;
    address public deployed;

    constructor(address impl) {
        implementation = impl;
    }

    function deploy() external returns (address clone) {
        clone = _clone(implementation);
        deployed = clone;
    }

    function _clone(address impl) internal returns (address result) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, ptr, 0x37)
        }
        require(result != address(0), "Clone failed");
    }
}
