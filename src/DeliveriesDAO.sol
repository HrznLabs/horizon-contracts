// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";

/**
 * @title IDeliveryMissionRegistry
 * @notice The subset of DeliveryMissionFactory that DeliveriesDAO trusts to bind an
 *         insurance policy to a real, funded delivery order (audit M4 residual / L1).
 */
interface IDeliveryMissionRegistry {
    function missions(uint256 missionId) external view returns (address escrow);
    function getMissionParams(uint256 missionId)
        external
        view
        returns (IMissionEscrow.MissionParams memory);
    function getMissionRuntime(uint256 missionId)
        external
        view
        returns (IMissionEscrow.MissionRuntime memory);
}

/**
 * @title IInsuranceProvider
 * @notice Standard interface for third-party insurance providers
 * @dev Any protocol can implement this to offer delivery insurance
 */
interface IInsuranceProvider {
    function getQuote(
        uint256 missionId,
        uint256 rewardAmount,
        uint256 coverageAmount,
        uint8 packageType,
        uint8 packageSize
    ) external view returns (uint256 premium);
    
    function activatePolicy(
        uint256 missionId,
        uint256 coverageAmount
    ) external;
    
    function processClaim(
        uint256 missionId,
        address claimant,
        bytes32 evidenceHash
    ) external;
}

/**
 * @title DeliveriesDAO
 * @notice Specialized guild for delivery missions with insurance pool
 * @dev Manages curated performers and provides insurance coverage
 *
 *      OPS NOTE (audit M4): the privileged role here is a single `Ownable` owner that can
 *      process claims and withdraw pool surplus. Transferring ownership to a multisig /
 *      the DAO timelock is an operational task and is deliberately NOT encoded here.
 *
 *      Drain bounds (audit M4 residual, issue #820). #828 added 1:1 reserve accounting, but
 *      the pool could still be emptied through the policy/claim path itself:
 *      `createInsurancePolicy` was permissionless with arbitrary `missionId` and
 *      `coverageAmount`, so anyone could insure orders that do not exist (or that they
 *      never paid for) for up to the whole pool surplus at a 1–2% premium, then claim it,
 *      and an owner-approved payout had no ceiling beyond that coverage. Now:
 *      - a policy must reference a real mission of the configured DeliveryMissionFactory,
 *        be bought by that mission's poster, while the order is Open/Accepted;
 *      - coverage ≤ the reward actually escrowed for the order, and ≤ `maxCoveragePerPolicy`;
 *      - payouts across all claims are capped per `PAYOUT_PERIOD` (`maxPayoutPerPeriod`);
 *      - the limits and the factory can be tightened instantly but only loosened after
 *        `CONFIG_DELAY`.
 *
 *      Owner outflows (PR #963 review follow-up). What the delays DO and do NOT protect:
 *      - They bound the permissionless drain (fake/over-sized policies) and rate-limit owner
 *        outflows: `closePolicy` only releases a reserve once the bound order is terminal
 *        (Completed/Cancelled) on the factory; a processed claim releases its reserve but the
 *        unpaid part is counted in `releasedThisPeriod`; immediate `withdrawFunds` is limited
 *        to surplus AND to a per-period budget (minus what was released that period — since
 *        #969 its own `maxWithdrawPerPeriod`); anything larger goes through `queueWithdraw` →
 *        `executeWithdraw` after `CONFIG_DELAY`, visible on-chain and cancellable.
 *      - They do NOT make a compromised owner key harmless: within those bounds the owner can
 *        still deny honest claims, move up to one period budget per `PAYOUT_PERIOD`, and
 *        withdraw the unreserved surplus after the delay. Full protection requires the owner
 *        to be a multisig / timelock — a pre-redeploy requirement (see script/README.md).
 *
 *      Factory binding, split budgets, claim window (issue #969, follow-up to #968):
 *      - Every policy records the factory that issued it (`InsurancePolicy.factory`), and every
 *        terminal-state read for that policy queries THAT factory, never the current
 *        `deliveryFactory`. Re-pointing the factory therefore cannot make a live order look
 *        Completed (the "queue hostile factory + queue full withdraw" drain), and after an
 *        honest migration an unrelated terminal mission with the same id on the new factory
 *        cannot close a live old policy. A colliding id can be re-insured on the new factory
 *        once the old policy is no longer active.
 *      - Claim payouts and immediate withdrawals have separate per-period budgets
 *        (`maxPayoutPerPeriod` / `maxWithdrawPerPeriod`), so a withdrawal can never consume
 *        the budget that approved claims need. Unpaid reserve releases (denials, closes) are
 *        charged to the withdrawal budget via `releasedThisPeriod`.
 *      - Windows are tumbling, anchored at the first outflow after the previous one expired.
 *        Across a window boundary each budget can therefore be spent twice within seconds: the
 *        hard bound is 2x `maxPayoutPerPeriod` of claim payouts plus 2x `maxWithdrawPerPeriod`
 *        of withdrawals+releases in any `PAYOUT_PERIOD`-long interval.
 *      - Claim grace window: a policy can only be closed `CLAIM_WINDOW` after its order was
 *        first observed terminal (`recordPolicyTerminal`, permissionless), so the holder
 *        always has that long to file. Close releases are charged to `releasedThisPeriod`.
 *      - Any tightening (`setPayoutLimits` / `setMaxWithdrawPerPeriod`) cancels EVERY queued
 *        loosening: limits, withdraw limit, delivery factory and queued withdrawal.
 *
 *      Remaining owner-trust boundary (honest statement): the owner can still deny any claim,
 *      queue a hostile factory that — after `CONFIG_DELAY` — can mint fake policies for NEW
 *      missions and have them paid within the per-period claim budget, and withdraw the
 *      unreserved surplus after the delay. What the contract guarantees is visibility: every
 *      such loosening sits on-chain for 2 days (`DeliveryFactoryQueued`, `PayoutLimitsQueued`,
 *      `WithdrawLimitQueued`, `WithdrawQueued`) and is cancelled by any tightening. That only
 *      protects users if someone watches those events and the owner is a multisig / timelock
 *      whose honest signers can tighten in time — a deployment requirement, not a code one.
 */
contract DeliveriesDAO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    IERC20 public usdc;
    
    // Insurance pool
    uint256 public insurancePoolBalance;
    uint256 public totalClaimsPaid;
    uint256 public totalPremiumsCollected;

    /// @notice Aggregate coverage backing all currently-active policies.
    /// @dev Audit M4: premiums are 1–2% of coverage while claims pay up to 100%, and the
    ///      owner could previously withdraw the entire pool including the premiums backing
    ///      live policies. This reserve is held 1:1 against outstanding coverage: it caps
    ///      `withdrawFunds` to genuine surplus and gates new policies on real solvency.
    uint256 public reservedCoverage;
    
    // Curated performers (verified, trusted)
    mapping(address => bool) public curatedPerformers;
    mapping(address => uint256) public performerRating; // 0-100 scale
    
    // Insurance fee rates (in basis points, 100 = 1%)
    uint256 public curatedInsuranceFee = 100;  // 1%
    uint256 public publicInsuranceFee = 200;   // 2%
    
    // Active insurance policies
    struct InsurancePolicy {
        uint256 missionId;
        address poster;
        uint256 coverageAmount;
        uint256 premium;
        bool active;
        bool claimed;
        uint256 createdAt;
        /// @notice Delivery factory that issued the insured mission (issue #969). All
        ///         terminal-state reads for this policy query this address.
        address factory;
        /// @notice When the order was first observed terminal (0 = not yet recorded).
        uint256 terminalAt;
    }
    
    mapping(uint256 => InsurancePolicy) public policies;
    
    // Claim history
    struct InsuranceClaim {
        uint256 missionId;
        address claimant;
        bytes32 evidenceHash;
        uint256 requestedAmount;
        uint256 paidAmount;
        bool approved;
        bool processed;
        uint256 submittedAt;
        uint256 processedAt;
    }
    
    mapping(uint256 => InsuranceClaim) public claims;
    uint256 public claimCounter;

    // ---- Drain bounds (audit M4 residual) ----------------------------------------

    /// @notice Length of the rolling window for `maxPayoutPerPeriod`.
    uint256 public constant PAYOUT_PERIOD = 1 days;

    /// @notice Delay before a loosening config change (higher caps / new factory) applies.
    uint256 public constant CONFIG_DELAY = 2 days;

    /// @notice Grace period after an order turns terminal during which the policy holder
    ///         can still file a claim and the policy cannot be closed (issue #969).
    uint256 public constant CLAIM_WINDOW = 3 days;

    /// @notice Delivery factory whose missions may be insured. Zero = no policies can be sold.
    address public deliveryFactory;

    /// @notice Max coverage a single policy may carry (USDC, 6 decimals).
    uint256 public maxCoveragePerPolicy = 1_000e6;

    /// @notice Max aggregate claim payouts per `PAYOUT_PERIOD` (USDC, 6 decimals).
    uint256 public maxPayoutPerPeriod = 5_000e6;

    /// @notice Start of the current payout window and the amount paid in it.
    uint256 public payoutPeriodStart;
    uint256 public payoutPeriodPaid;

    /// @notice Queued loosening changes and when they may be applied (0 = none queued).
    uint256 public pendingMaxCoveragePerPolicy;
    uint256 public pendingMaxPayoutPerPeriod;
    uint256 public pendingLimitsEta;
    address public pendingDeliveryFactory;
    uint256 public pendingDeliveryFactoryEta;

    /// @notice Unpaid coverage released (claim denials / partial payouts / closed policies)
    ///         in the current window.
    /// @dev Counted against the immediate `withdrawFunds` budget so deny-or-close-then-withdraw
    ///      stays bounded by `maxWithdrawPerPeriod`. Not charged against claim payouts.
    uint256 public releasedThisPeriod;

    /// @notice Max immediate `withdrawFunds` (plus unpaid releases) per `PAYOUT_PERIOD`.
    /// @dev Issue #969: separate from `maxPayoutPerPeriod` so withdrawals never starve claims.
    uint256 public maxWithdrawPerPeriod = 5_000e6;

    /// @notice Immediate withdrawals made in the current window.
    uint256 public withdrawnThisPeriod;

    /// @notice Queued (loosening) `maxWithdrawPerPeriod`; eta 0 = none queued.
    uint256 public pendingMaxWithdrawPerPeriod;
    uint256 public pendingMaxWithdrawEta;

    /// @notice Queued (delayed) surplus withdrawal; eta 0 = none queued.
    uint256 public pendingWithdrawAmount;
    address public pendingWithdrawRecipient;
    uint256 public pendingWithdrawEta;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event PerformerCurated(address indexed performer, uint256 rating);
    event PerformerRemoved(address indexed performer);
    event InsurancePolicyCreated(uint256 indexed missionId, address indexed poster, uint256 premium, uint256 coverage);
    event InsuranceClaimSubmitted(uint256 indexed claimId, uint256 indexed missionId, address indexed claimant);
    event InsuranceClaimProcessed(uint256 indexed claimId, bool approved, uint256 paidAmount);
    event FeesUpdated(uint256 curatedFee, uint256 publicFee);
    event FundsWithdrawn(address indexed recipient, uint256 amount);
    event PoolFunded(address indexed from, uint256 amount);
    event PolicyClosed(uint256 indexed missionId, uint256 coverageReleased);
    event PayoutLimitsUpdated(uint256 maxCoveragePerPolicy, uint256 maxPayoutPerPeriod);
    event PayoutLimitsQueued(uint256 maxCoveragePerPolicy, uint256 maxPayoutPerPeriod, uint256 eta);
    event DeliveryFactoryUpdated(address indexed factory);
    event DeliveryFactoryQueued(address indexed factory, uint256 eta);
    event WithdrawQueued(address indexed recipient, uint256 amount, uint256 eta);
    event WithdrawCancelled();
    event DeliveryFactoryCancelled();
    event WithdrawLimitUpdated(uint256 maxWithdrawPerPeriod);
    event WithdrawLimitQueued(uint256 maxWithdrawPerPeriod, uint256 eta);
    /// @notice The policy's order was observed terminal; it is closable from `closableAt`.
    event PolicyTerminalRecorded(uint256 indexed missionId, uint256 closableAt);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InsufficientPoolBalance();
    error PolicyNotActive();
    error ClaimAlreadyProcessed();
    error NotAuthorized();
    error InvalidFeeRate();
    /// @notice The pool cannot back this coverage on top of what is already reserved.
    error InsufficientSolvency(uint256 available, uint256 required);
    /// @notice Payout would exceed the policy's coverage.
    error ExceedsCoverage();
    /// @notice No delivery factory configured, so no order can be verified.
    error DeliveryFactoryNotSet();
    /// @notice `missionId` is not a mission of the configured delivery factory.
    error UnknownMission(uint256 missionId);
    /// @notice Only the mission's poster may insure it.
    error NotMissionPoster();
    /// @notice The order is no longer insurable (completed, cancelled or disputed).
    error MissionNotInsurable();
    /// @notice Coverage is zero, above the order's escrowed reward, or above the per-policy cap.
    error InvalidCoverage(uint256 coverage, uint256 maxAllowed);
    /// @notice Payout would breach the per-period cap.
    error PeriodPayoutCapExceeded(uint256 requested, uint256 remaining);
    error InvalidLimits();
    error NothingQueued();
    error TooEarly(uint256 eta);
    error ZeroAddress();
    /// @notice The bound order is not terminal yet, so the policy still covers it.
    error PolicyStillCovering();
    /// @notice The post-terminal claim window has not elapsed (or was never started).
    error ClaimWindowOpen(uint256 closableAt);

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    // =============================================================================
    // PERFORMER CURATION
    // =============================================================================

    /**
     * @notice Add performer to curated list
     * @param performer Address of performer to curate
     * @param rating Initial rating (0-100)
     */
    function curatePerformer(address performer, uint256 rating) external onlyOwner {
        require(rating <= 100, "Rating must be 0-100");
        curatedPerformers[performer] = true;
        performerRating[performer] = rating;
        emit PerformerCurated(performer, rating);
    }

    /**
     * @notice Remove performer from curated list
     * @param performer Address of performer to remove
     */
    function removePerformer(address performer) external onlyOwner {
        curatedPerformers[performer] = false;
        performerRating[performer] = 0;
        emit PerformerRemoved(performer);
    }

    /**
     * @notice Update performer rating
     * @param performer Address of performer
     * @param rating New rating (0-100)
     */
    function updatePerformerRating(address performer, uint256 rating) external onlyOwner {
        require(rating <= 100, "Rating must be 0-100");
        require(curatedPerformers[performer], "Performer not curated");
        performerRating[performer] = rating;
    }

    /**
     * @notice Check if performer is curated
     * @param performer Address to check
     * @return True if performer is curated
     */
    function isPerformerCurated(address performer) external view returns (bool) {
        return curatedPerformers[performer];
    }

    // =============================================================================
    // INSURANCE MANAGEMENT
    // =============================================================================

    /**
     * @notice Get insurance fee for a mission
     * @param rewardAmount Mission reward amount
     * @param curated Whether mission is curated (only curated performers)
     * @return Insurance premium in USDC
     */
    function getInsuranceFee(
        uint256 rewardAmount,
        bool curated
    ) external view returns (uint256) {
        uint256 feeRate = curated ? curatedInsuranceFee : publicInsuranceFee;
        return (rewardAmount * feeRate) / 10000;
    }

    /**
     * @notice Create insurance policy for a delivery mission
     * @param missionId Mission identifier
     * @param coverageAmount Amount to cover
     * @param curated Whether mission is curated
     */
    function createInsurancePolicy(
        uint256 missionId,
        uint256 coverageAmount,
        bool curated
    ) external nonReentrant {
        // `createdAt` is non-zero for every real policy, so this also closes the
        // missionId == 0 hole left by the old `missionId == 0` sentinel check.
        // Issue #969: after a factory migration the new factory may reuse an id of the old
        // one; that id is insurable again once the old factory's policy is settled.
        InsurancePolicy storage existing = policies[missionId];
        // slither-disable-next-line incorrect-equality
        require(
            existing.createdAt == 0 || (!existing.active && existing.factory != deliveryFactory),
            "Policy already exists"
        );

        // Audit M4 residual / L1: only a real, funded order can be insured, only by the
        // poster who funded it, and never for more than was actually escrowed.
        _checkInsurable(missionId, coverageAmount);

        uint256 feeRate = curated ? curatedInsuranceFee : publicInsuranceFee;
        uint256 premium = (coverageAmount * feeRate) / 10000;

        // Audit M4: refuse to underwrite coverage the pool cannot actually pay.
        // Reserving 1:1 means the DAO must capitalise the pool (see fundPool) rather
        // than pretend 1–2% premiums back 100% payouts. The premium counts towards the
        // pool; all state is written before the premium is pulled (CEI).
        uint256 newBalance = insurancePoolBalance + premium;
        uint256 reserved = reservedCoverage;
        uint256 newReserved = reserved + coverageAmount;
        if (newReserved > newBalance) {
            revert InsufficientSolvency(newBalance > reserved ? newBalance - reserved : 0, coverageAmount);
        }
        insurancePoolBalance = newBalance;
        totalPremiumsCollected += premium;
        reservedCoverage = newReserved;

        // Create policy
        policies[missionId] = InsurancePolicy({
            missionId: missionId,
            poster: msg.sender,
            coverageAmount: coverageAmount,
            premium: premium,
            active: true,
            claimed: false,
            createdAt: block.timestamp,
            factory: deliveryFactory,
            terminalAt: 0
        });
        
        emit InsurancePolicyCreated(missionId, msg.sender, premium, coverageAmount);

        // Interaction last.
        usdc.safeTransferFrom(msg.sender, address(this), premium);
    }

    /**
     * @notice Submit insurance claim
     * @param missionId Mission identifier
     * @param evidenceHash IPFS hash of evidence
     * @param requestedAmount Amount requested
     */
    function submitInsuranceClaim(
        uint256 missionId,
        bytes32 evidenceHash,
        uint256 requestedAmount
    ) external {
        InsurancePolicy storage policy = policies[missionId];
        
        if (!policy.active) revert PolicyNotActive();
        require(msg.sender == policy.poster, "Not policy holder");
        require(!policy.claimed, "Already claimed");
        require(requestedAmount <= policy.coverageAmount, "Exceeds coverage");
        
        uint256 claimId = claimCounter++;
        
        claims[claimId] = InsuranceClaim({
            missionId: missionId,
            claimant: msg.sender,
            evidenceHash: evidenceHash,
            requestedAmount: requestedAmount,
            paidAmount: 0,
            approved: false,
            processed: false,
            submittedAt: block.timestamp,
            processedAt: 0
        });
        
        policy.claimed = true;
        
        emit InsuranceClaimSubmitted(claimId, missionId, msg.sender);
    }

    /**
     * @notice Process insurance claim (DAO governance)
     * @param claimId Claim identifier
     * @param approved Whether claim is approved
     * @param payoutAmount Amount to pay (if approved)
     */
    function processInsuranceClaim(
        uint256 claimId,
        bool approved,
        uint256 payoutAmount
    ) external onlyOwner nonReentrant {
        InsuranceClaim storage claim = claims[claimId];

        if (claim.processed) revert ClaimAlreadyProcessed();

        claim.processed = true;
        claim.processedAt = block.timestamp;
        claim.approved = approved;

        InsurancePolicy storage policy = policies[claim.missionId];

        if (approved && payoutAmount > 0) {
            // Audit M4: a payout may never exceed the coverage that was reserved for it.
            if (payoutAmount > policy.coverageAmount) revert ExceedsCoverage();
            if (payoutAmount > insurancePoolBalance) revert InsufficientPoolBalance();
            // Audit M4 residual: bound aggregate outflow per period.
            _consumePeriodPayout(payoutAmount);

            claim.paidAmount = payoutAmount;
            insurancePoolBalance -= payoutAmount;
            totalClaimsPaid += payoutAmount;
        }

        // Audit M4: the policy is settled either way — release its reserve so the
        // capital becomes available again for new policies or withdrawal. The unpaid part
        // (all of it on a denial) is charged to `releasedThisPeriod`, so an owner cannot
        // deny-then-withdraw past the per-period budget (PR #963 review).
        uint256 released = _releasePolicy(claim.missionId);
        if (released > claim.paidAmount) {
            _rollPeriod();
            releasedThisPeriod += released - claim.paidAmount;
        }

        if (claim.paidAmount > 0) {
            // Transfer payout to claimant (interactions last)
            usdc.safeTransfer(claim.claimant, claim.paidAmount);
        }

        emit InsuranceClaimProcessed(claimId, approved, payoutAmount);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Update insurance fee rates
     * @param _curatedFee Fee for curated missions (basis points)
     * @param _publicFee Fee for public missions (basis points)
     */
    function updateFees(uint256 _curatedFee, uint256 _publicFee) external onlyOwner {
        if (_curatedFee > 1000 || _publicFee > 1000) revert InvalidFeeRate(); // Max 10%
        curatedInsuranceFee = _curatedFee;
        publicInsuranceFee = _publicFee;
        emit FeesUpdated(_curatedFee, _publicFee);
    }

    /**
     * @notice Sync the internal insurance pool balance tracker with the contract's
     *         actual USDC balance.
     * @dev The tracked `insurancePoolBalance` can drift below `balanceOf(address(this))`
     *      if USDC is sent directly to this contract outside of createInsurancePolicy()
     *      (e.g., a direct transfer from a multisig top-up). Calling sync() realigns
     *      the tracker so that the full balance is available for claim payouts and
     *      correct pool statistics are reported via getPoolStats().
     */
    function sync() external onlyOwner {
        insurancePoolBalance = usdc.balanceOf(address(this));
    }

    /**
     * @notice Capitalise the insurance pool.
     * @dev Audit M4: policies are reserved 1:1 against the pool, so the DAO must fund it
     *      with real capital before it can underwrite coverage that premiums alone
     *      (1–2% of coverage) could never pay. Permissionless — anyone may donate.
     * @param amount USDC to pull from the caller into the pool.
     */
    function fundPool(uint256 amount) external {
        require(amount > 0, "Zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        insurancePoolBalance += amount;
        emit PoolFunded(msg.sender, amount);
    }

    /**
     * @notice Record that an active policy's order is over (Completed or Cancelled), which
     *         starts its `CLAIM_WINDOW`. Permissionless: holder, keeper or owner may call it.
     * @dev Issue #969: the state is read from the factory that ISSUED the policy, never from
     *      the current `deliveryFactory`, so re-pointing the factory cannot fake a terminal
     *      order. Idempotent once recorded.
     * @param missionId Mission whose policy's order is terminal.
     */
    function recordPolicyTerminal(uint256 missionId) external {
        InsurancePolicy storage policy = policies[missionId];
        if (!policy.active) revert PolicyNotActive();
        if (policy.terminalAt != 0) return;
        IMissionEscrow.MissionState st =
            IDeliveryMissionRegistry(policy.factory).getMissionRuntime(missionId).state;
        if (st != IMissionEscrow.MissionState.Completed && st != IMissionEscrow.MissionState.Cancelled) {
            revert PolicyStillCovering();
        }
        policy.terminalAt = block.timestamp;
        emit PolicyTerminalRecorded(missionId, block.timestamp + CLAIM_WINDOW);
    }

    /**
     * @notice Close an active, unclaimed policy whose order is over and whose claim window
     *         has elapsed.
     * @dev Frees the reserved coverage so it can back new policies or be withdrawn. PR #963
     *      review: only once the bound order is terminal — while it is Open/Accepted/Submitted/
     *      Disputed the holder is still covered. Issue #969: the order must have been recorded
     *      terminal (`recordPolicyTerminal`, on the policy's own factory) at least
     *      `CLAIM_WINDOW` ago, so the holder always has time to file; the released reserve is
     *      charged to `releasedThisPeriod` (the immediate-withdraw budget).
     * @param missionId Mission whose policy should be closed.
     */
    function closePolicy(uint256 missionId) external onlyOwner {
        InsurancePolicy storage policy = policies[missionId];
        if (!policy.active) revert PolicyNotActive();
        require(!policy.claimed, "Claim pending");
        uint256 terminalAt = policy.terminalAt;
        if (terminalAt == 0) revert PolicyStillCovering();
        uint256 closableAt = terminalAt + CLAIM_WINDOW;
        if (block.timestamp < closableAt) revert ClaimWindowOpen(closableAt);
        uint256 released = _releasePolicy(missionId);
        _rollPeriod();
        releasedThisPeriod += released;
    }

    /**
     * @notice Withdraw surplus funds from the insurance pool immediately (small amounts).
     * @dev Audit M4: capped at the genuine surplus (`balance − reservedCoverage`). PR #963
     *      review: also rate-limited per `PAYOUT_PERIOD` and reduced by `releasedThisPeriod`.
     *      Issue #969: the budget is `maxWithdrawPerPeriod`, separate from the claim-payout
     *      budget, so a withdrawal never blocks an approved claim. Larger amounts: use
     *      `queueWithdraw`.
     * @param amount Amount to withdraw
     * @param recipient Address to receive funds
     */
    function withdrawFunds(uint256 amount, address recipient) external onlyOwner nonReentrant {
        require(amount <= _availableSurplus(), "Insufficient balance");
        _rollPeriod();
        uint256 used = withdrawnThisPeriod + releasedThisPeriod;
        uint256 cap = maxWithdrawPerPeriod;
        if (used + amount > cap) {
            revert PeriodPayoutCapExceeded(amount, used >= cap ? 0 : cap - used);
        }
        withdrawnThisPeriod += amount;
        _withdraw(amount, recipient);
    }

    /**
     * @notice Queue a surplus withdrawal of any size, executable after `CONFIG_DELAY`.
     * @dev Replaces any queued withdrawal. Cancelled by `cancelWithdraw` or by any tightening
     *      of the payout limits. The surplus is re-checked at execution time.
     */
    function queueWithdraw(uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        require(amount > 0, "Zero amount");
        pendingWithdrawAmount = amount;
        pendingWithdrawRecipient = recipient;
        pendingWithdrawEta = block.timestamp + CONFIG_DELAY;
        emit WithdrawQueued(recipient, amount, pendingWithdrawEta);
    }

    /// @notice Execute the queued withdrawal once its delay has elapsed.
    function executeWithdraw() external onlyOwner nonReentrant {
        uint256 eta = pendingWithdrawEta;
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        uint256 amount = pendingWithdrawAmount;
        require(amount <= _availableSurplus(), "Insufficient balance");
        address recipient = pendingWithdrawRecipient;
        _clearWithdraw();
        _withdraw(amount, recipient);
    }

    /// @notice Cancel the queued withdrawal.
    function cancelWithdraw() external onlyOwner {
        if (pendingWithdrawEta == 0) revert NothingQueued();
        _cancelWithdraw();
    }

    // =============================================================================
    // DRAIN BOUNDS CONFIG (audit M4 residual)
    // =============================================================================

    /**
     * @notice Set the delivery factory whose missions may be insured.
     * @dev First configuration applies immediately (no policy can exist before it). Any
     *      later change is queued for `CONFIG_DELAY`, because a hostile factory could report
     *      arbitrary posters and rewards.
     */
    function setDeliveryFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (deliveryFactory == address(0)) {
            deliveryFactory = factory;
            emit DeliveryFactoryUpdated(factory);
            return;
        }
        pendingDeliveryFactory = factory;
        pendingDeliveryFactoryEta = block.timestamp + CONFIG_DELAY;
        emit DeliveryFactoryQueued(factory, pendingDeliveryFactoryEta);
    }

    /// @notice Apply a queued delivery-factory change once its delay has elapsed.
    function applyDeliveryFactory() external onlyOwner {
        uint256 eta = pendingDeliveryFactoryEta;
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        deliveryFactory = pendingDeliveryFactory;
        pendingDeliveryFactory = address(0);
        pendingDeliveryFactoryEta = 0;
        emit DeliveryFactoryUpdated(deliveryFactory);
    }

    /**
     * @notice Update the per-policy coverage cap and the per-period payout cap.
     * @dev Tightening (both values ≤ current) applies immediately and cancels every queued
     *      loosening (limits, withdraw limit, delivery factory) and any queued withdrawal.
     *      Loosening is queued for `CONFIG_DELAY`. `perPolicy ≤ perPeriod` so every policy
     *      remains payable within one period.
     */
    function setPayoutLimits(uint256 perPolicy, uint256 perPeriod) external onlyOwner {
        if (perPolicy == 0 || perPolicy > perPeriod) revert InvalidLimits();
        if (perPolicy <= maxCoveragePerPolicy && perPeriod <= maxPayoutPerPeriod) {
            maxCoveragePerPolicy = perPolicy;
            maxPayoutPerPeriod = perPeriod;
            _cancelAllPending();
            emit PayoutLimitsUpdated(perPolicy, perPeriod);
            return;
        }
        pendingMaxCoveragePerPolicy = perPolicy;
        pendingMaxPayoutPerPeriod = perPeriod;
        pendingLimitsEta = block.timestamp + CONFIG_DELAY;
        emit PayoutLimitsQueued(perPolicy, perPeriod, pendingLimitsEta);
    }

    /// @notice Apply queued (loosened) payout limits once their delay has elapsed.
    function applyPayoutLimits() external onlyOwner {
        uint256 eta = pendingLimitsEta;
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        maxCoveragePerPolicy = pendingMaxCoveragePerPolicy;
        maxPayoutPerPeriod = pendingMaxPayoutPerPeriod;
        pendingLimitsEta = 0;
        emit PayoutLimitsUpdated(maxCoveragePerPolicy, maxPayoutPerPeriod);
    }

    /**
     * @notice Update the immediate-withdrawal budget per `PAYOUT_PERIOD` (issue #969).
     * @dev Same rules as `setPayoutLimits`: tightening (≤ current, 0 allowed) applies
     *      immediately and cancels every queued loosening and queued withdrawal; loosening is
     *      queued for `CONFIG_DELAY`.
     */
    function setMaxWithdrawPerPeriod(uint256 cap) external onlyOwner {
        if (cap <= maxWithdrawPerPeriod) {
            maxWithdrawPerPeriod = cap;
            _cancelAllPending();
            emit WithdrawLimitUpdated(cap);
            return;
        }
        pendingMaxWithdrawPerPeriod = cap;
        pendingMaxWithdrawEta = block.timestamp + CONFIG_DELAY;
        emit WithdrawLimitQueued(cap, pendingMaxWithdrawEta);
    }

    /// @notice Apply a queued (loosened) withdrawal budget once its delay has elapsed.
    function applyMaxWithdrawPerPeriod() external onlyOwner {
        uint256 eta = pendingMaxWithdrawEta;
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        maxWithdrawPerPeriod = pendingMaxWithdrawPerPeriod;
        pendingMaxWithdrawEta = 0;
        emit WithdrawLimitUpdated(maxWithdrawPerPeriod);
    }

    /// @notice Immediate withdrawal still available in the current period.
    function remainingPeriodWithdraw() external view returns (uint256) {
        if (block.timestamp >= payoutPeriodStart + PAYOUT_PERIOD) return maxWithdrawPerPeriod;
        uint256 used = withdrawnThisPeriod + releasedThisPeriod;
        return used >= maxWithdrawPerPeriod ? 0 : maxWithdrawPerPeriod - used;
    }

    /// @notice Claim payout still available in the current period.
    function remainingPeriodPayout() public view returns (uint256) {
        if (block.timestamp >= payoutPeriodStart + PAYOUT_PERIOD) return maxPayoutPerPeriod;
        uint256 paid = payoutPeriodPaid;
        return paid >= maxPayoutPerPeriod ? 0 : maxPayoutPerPeriod - paid;
    }

    // =============================================================================
    // INTERNAL
    // =============================================================================

    /// @dev Bind a new policy to a real, funded, still-live order of the delivery factory.
    function _checkInsurable(uint256 missionId, uint256 coverageAmount) internal view {
        address factory = deliveryFactory;
        if (factory == address(0)) revert DeliveryFactoryNotSet();
        IDeliveryMissionRegistry registry = IDeliveryMissionRegistry(factory);
        if (registry.missions(missionId) == address(0)) revert UnknownMission(missionId);

        IMissionEscrow.MissionParams memory params = registry.getMissionParams(missionId);
        if (params.poster != msg.sender) revert NotMissionPoster();

        IMissionEscrow.MissionState st = registry.getMissionRuntime(missionId).state;
        if (st != IMissionEscrow.MissionState.Open && st != IMissionEscrow.MissionState.Accepted) {
            revert MissionNotInsurable();
        }

        uint256 maxAllowed = params.rewardAmount < maxCoveragePerPolicy
            ? params.rewardAmount
            : maxCoveragePerPolicy;
        if (coverageAmount == 0 || coverageAmount > maxAllowed) {
            revert InvalidCoverage(coverageAmount, maxAllowed);
        }
    }

    /// @dev Start a new window (resetting all counters) if the current one expired.
    function _rollPeriod() internal {
        if (block.timestamp >= payoutPeriodStart + PAYOUT_PERIOD) {
            payoutPeriodStart = block.timestamp;
            payoutPeriodPaid = 0;
            releasedThisPeriod = 0;
            withdrawnThisPeriod = 0;
        }
    }

    /// @dev Roll the payout window if it expired, then charge `amount` against it.
    function _consumePeriodPayout(uint256 amount) internal {
        _rollPeriod();
        uint256 paid = payoutPeriodPaid + amount;
        if (paid > maxPayoutPerPeriod) {
            revert PeriodPayoutCapExceeded(amount, remainingPeriodPayout());
        }
        payoutPeriodPaid = paid;
    }

    /// @notice Pool capital not reserved against outstanding coverage.
    function _availableSurplus() internal view returns (uint256) {
        uint256 balance = insurancePoolBalance;
        uint256 reserved = reservedCoverage;
        return balance > reserved ? balance - reserved : 0;
    }

    function _withdraw(uint256 amount, address recipient) internal {
        insurancePoolBalance -= amount;
        usdc.safeTransfer(recipient, amount);
        emit FundsWithdrawn(recipient, amount);
    }

    function _clearWithdraw() internal {
        pendingWithdrawAmount = 0;
        pendingWithdrawRecipient = address(0);
        pendingWithdrawEta = 0;
    }

    function _cancelWithdraw() internal {
        _clearWithdraw();
        emit WithdrawCancelled();
    }

    /// @dev Any tightening cancels every queued loosening (issue #969).
    function _cancelAllPending() internal {
        pendingLimitsEta = 0;
        pendingMaxWithdrawEta = 0;
        if (pendingDeliveryFactoryEta != 0) {
            pendingDeliveryFactory = address(0);
            pendingDeliveryFactoryEta = 0;
            emit DeliveryFactoryCancelled();
        }
        if (pendingWithdrawEta != 0) _cancelWithdraw();
    }

    /// @notice Deactivate a policy and release its reserved coverage (idempotent).
    /// @return coverage The coverage released (0 if the policy was already inactive).
    function _releasePolicy(uint256 missionId) internal returns (uint256 coverage) {
        InsurancePolicy storage policy = policies[missionId];
        if (!policy.active) return 0;

        policy.active = false;
        coverage = policy.coverageAmount;
        // Defensive: never underflow even if `sync()` or an upgrade skewed the tracker.
        reservedCoverage = reservedCoverage > coverage ? reservedCoverage - coverage : 0;

        emit PolicyClosed(missionId, coverage);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get insurance policy details
     * @param missionId Mission identifier
     * @return Insurance policy
     */
    function getPolicy(uint256 missionId) external view returns (InsurancePolicy memory) {
        return policies[missionId];
    }

    /**
     * @notice Get claim details
     * @param claimId Claim identifier
     * @return Insurance claim
     */
    function getClaim(uint256 claimId) external view returns (InsuranceClaim memory) {
        return claims[claimId];
    }

    /**
     * @notice Pool capital that is NOT reserved against outstanding coverage.
     * @dev This is the maximum `withdrawFunds` will release, and the headroom available
     *      for underwriting new policies.
     */
    function availableSurplus() external view returns (uint256) {
        return _availableSurplus();
    }

    /**
     * @notice Get insurance pool statistics
     * @return poolBalance Current pool balance
     * @return totalClaims Total claims paid
     * @return totalPremiums Total premiums collected
     */
    function getPoolStats() external view returns (
        uint256 poolBalance,
        uint256 totalClaims,
        uint256 totalPremiums
    ) {
        return (insurancePoolBalance, totalClaimsPaid, totalPremiumsCollected);
    }
}
