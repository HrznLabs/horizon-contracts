// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
 */
contract DeliveriesDAO is Ownable {
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
    ) external {
        // `createdAt` is non-zero for every real policy, so this also closes the
        // missionId == 0 hole left by the old `missionId == 0` sentinel check.
        // slither-disable-next-line incorrect-equality
        require(policies[missionId].createdAt == 0, "Policy already exists");

        uint256 feeRate = curated ? curatedInsuranceFee : publicInsuranceFee;
        uint256 premium = (coverageAmount * feeRate) / 10000;

        // Transfer premium from poster
        usdc.safeTransferFrom(msg.sender, address(this), premium);

        // Update pool balance
        insurancePoolBalance += premium;
        totalPremiumsCollected += premium;

        // Audit M4: refuse to underwrite coverage the pool cannot actually pay.
        // Reserving 1:1 means the DAO must capitalise the pool (see fundPool) rather
        // than pretend 1–2% premiums back 100% payouts.
        uint256 newReserved = reservedCoverage + coverageAmount;
        if (newReserved > insurancePoolBalance) {
            revert InsufficientSolvency(_availableSurplus(), coverageAmount);
        }
        reservedCoverage = newReserved;

        // Create policy
        policies[missionId] = InsurancePolicy({
            missionId: missionId,
            poster: msg.sender,
            coverageAmount: coverageAmount,
            premium: premium,
            active: true,
            claimed: false,
            createdAt: block.timestamp
        });
        
        emit InsurancePolicyCreated(missionId, msg.sender, premium, coverageAmount);
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
    ) external onlyOwner {
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

            claim.paidAmount = payoutAmount;
            insurancePoolBalance -= payoutAmount;
            totalClaimsPaid += payoutAmount;
        }

        // Audit M4: the policy is settled either way — release its reserve so the
        // capital becomes available again for new policies or withdrawal.
        _releasePolicy(claim.missionId);

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
     * @notice Close an active policy that will never be claimed (delivery completed).
     * @dev Frees the reserved coverage so it can back new policies or be withdrawn.
     * @param missionId Mission whose policy should be closed.
     */
    function closePolicy(uint256 missionId) external onlyOwner {
        InsurancePolicy storage policy = policies[missionId];
        if (!policy.active) revert PolicyNotActive();
        require(!policy.claimed, "Claim pending");
        _releasePolicy(missionId);
    }

    /**
     * @notice Withdraw surplus funds from insurance pool
     * @dev Audit M4: capped at the genuine surplus (`balance − reservedCoverage`) so the
     *      owner can no longer drain capital backing live policies.
     * @param amount Amount to withdraw
     * @param recipient Address to receive funds
     */
    function withdrawFunds(uint256 amount, address recipient) external onlyOwner {
        require(amount <= _availableSurplus(), "Insufficient balance");
        insurancePoolBalance -= amount;
        usdc.safeTransfer(recipient, amount);
        emit FundsWithdrawn(recipient, amount);
    }

    // =============================================================================
    // INTERNAL
    // =============================================================================

    /// @notice Pool capital not reserved against outstanding coverage.
    function _availableSurplus() internal view returns (uint256) {
        uint256 balance = insurancePoolBalance;
        uint256 reserved = reservedCoverage;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice Deactivate a policy and release its reserved coverage (idempotent).
    function _releasePolicy(uint256 missionId) internal {
        InsurancePolicy storage policy = policies[missionId];
        if (!policy.active) return;

        policy.active = false;
        uint256 coverage = policy.coverageAmount;
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
