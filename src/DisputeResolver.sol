// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IDisputeResolver.sol";
import "./interfaces/IMissionEscrow.sol";

/**
 * @title DisputeResolver
 * @author Horizon Protocol
 * @notice Handles mission disputes with DDR (Dynamic Dispute Reserve) and LPP (Loser-Pays Penalty)
 * @dev
 * DDR: 5% of reward deposited by both parties when dispute is raised
 * LPP: 2% penalty on losing party distributed to winner + resolver
 *
 * Flow:
 * 1. Party raises dispute → DDR deposited
 * 2. Resolver assigned by ResolversDAO
 * 3. Both parties submit evidence
 * 4. Resolver makes decision
 * 5. 48h appeal period
 * 6. Finalize and distribute funds
 *
 * Security invariants:
 * - DDR rate immutable after deployment
 * - Only assigned resolver can resolve
 * - Only DAO can override
 * - No fund extraction without resolution
 */
contract DisputeResolver is IDisputeResolver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STATE
    // =============================================================================

    /// @notice USDC token for payments
    IERC20 public immutable usdc;

    /// @notice ResolversDAO address (can assign resolvers)
    address public resolversDAO;

    /// @notice Protocol DAO address (can override resolutions)
    address public protocolDAO;

    /// @notice Protocol treasury for fees
    address public protocolTreasury;

    /// @notice Resolver treasury for fees
    address public resolverTreasury;

    /// @notice DDR rate in basis points (500 = 5%)
    uint256 public constant DDR_RATE_BPS = 500;

    /// @notice LPP rate in basis points (200 = 2%)
    uint256 public constant LPP_RATE_BPS = 200;

    /// @notice Appeal period in seconds (48 hours)
    uint256 public constant APPEAL_PERIOD = 48 hours;

    /// @notice Resolver fee from DDR pool in basis points (2000 = 20%)
    uint256 public constant RESOLVER_FEE_BPS = 2000;

    /// @notice Protocol fee from DDR pool in basis points (1000 = 10%)
    uint256 public constant PROTOCOL_FEE_BPS = 1000;

    /// @notice Counter for dispute IDs
    uint256 private _disputeIdCounter;

    /// @notice Mapping from dispute ID to Dispute
    mapping(uint256 => Dispute) private _disputes;

    /// @notice Mapping from mission ID to dispute IDs
    mapping(uint256 => uint256[]) private _missionDisputes;

    /// @notice Mapping from escrow address to dispute ID
    mapping(address => uint256) private _escrowDispute;

    /// @notice DDR deposits by dispute and party
    mapping(uint256 => mapping(address => uint256)) private _ddrDeposits;

    /// @notice Split percentage for Split outcomes (0-10000 bps for performer)
    mapping(uint256 => uint256) private _splitPercentages;

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        address _usdc,
        address _resolversDAO,
        address _protocolDAO,
        address _protocolTreasury,
        address _resolverTreasury
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        resolversDAO = _resolversDAO;
        protocolDAO = _protocolDAO;
        protocolTreasury = _protocolTreasury;
        resolverTreasury = _resolverTreasury;
    }

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyResolversDAO() {
        if (msg.sender != resolversDAO) revert NotDAO();
        _;
    }

    modifier onlyProtocolDAO() {
        if (msg.sender != protocolDAO) revert NotDAO();
        _;
    }

    modifier disputeExists(uint256 disputeId) {
        if (_disputes[disputeId].disputeId == 0) revert DisputeNotFound();
        _;
    }

    // =============================================================================
    // EXTERNAL FUNCTIONS
    // =============================================================================

    /**
     * @notice Create a new dispute for a mission
     * @param escrowAddress Address of the mission escrow
     * @param missionId On-chain mission ID
     * @param evidenceHash IPFS hash of initial evidence
     * @return disputeId The ID of the created dispute
     */
    function createDispute(address escrowAddress, uint256 missionId, bytes32 evidenceHash)
        external
        nonReentrant
        returns (uint256 disputeId)
    {
        // Verify escrow exists and is in disputed state
        IMissionEscrow escrow = IMissionEscrow(escrowAddress);
        IMissionEscrow.MissionParams memory params = escrow.getParams();
        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();

        // Only poster or performer can raise dispute
        if (msg.sender != params.poster && msg.sender != runtime.performer) {
            revert NotParty();
        }

        // Must be in submitted state or already disputed
        if (
            runtime.state != IMissionEscrow.MissionState.Submitted
                && runtime.state != IMissionEscrow.MissionState.Disputed
        ) {
            revert InvalidDisputeState();
        }

        // Check no existing dispute for this escrow
        if (_escrowDispute[escrowAddress] != 0) {
            revert InvalidDisputeState();
        }

        // Calculate DDR amount
        uint256 ddrAmount = (params.rewardAmount * DDR_RATE_BPS) / 10_000;

        // Transfer DDR from initiator
        usdc.safeTransferFrom(msg.sender, address(this), ddrAmount);

        // Create dispute
        _disputeIdCounter++;
        disputeId = _disputeIdCounter;

        _disputes[disputeId] = Dispute({
            disputeId: disputeId,
            escrowAddress: escrowAddress,
            missionId: missionId,
            poster: params.poster,
            performer: runtime.performer,
            initiator: msg.sender,
            state: DisputeState.Pending,
            outcome: DisputeOutcome.None,
            resolver: address(0),
            ddrAmount: ddrAmount,
            lppAmount: (params.rewardAmount * LPP_RATE_BPS) / 10_000,
            posterEvidenceHash: msg.sender == params.poster ? evidenceHash : bytes32(0),
            performerEvidenceHash: msg.sender == runtime.performer ? evidenceHash : bytes32(0),
            resolutionHash: bytes32(0),
            createdAt: block.timestamp,
            resolvedAt: 0,
            appealDeadline: 0
        });

        // Record DDR deposit
        _ddrDeposits[disputeId][msg.sender] = ddrAmount;

        // Track dispute
        _missionDisputes[missionId].push(disputeId);
        _escrowDispute[escrowAddress] = disputeId;

        emit DisputeCreated(disputeId, escrowAddress, missionId, msg.sender, ddrAmount);
    }

    /**
     * @notice Assign a resolver to a dispute
     * @param disputeId The dispute ID
     * @param resolver Address of the resolver
     */
    function assignResolver(uint256 disputeId, address resolver)
        external
        onlyResolversDAO
        disputeExists(disputeId)
    {
        Dispute storage dispute = _disputes[disputeId];

        if (dispute.state != DisputeState.Pending) {
            revert InvalidDisputeState();
        }

        if (dispute.resolver != address(0)) {
            revert ResolverAlreadyAssigned();
        }

        dispute.resolver = resolver;
        dispute.state = DisputeState.Investigating;

        emit ResolverAssigned(disputeId, resolver);
    }

    /**
     * @notice Submit evidence for a dispute
     * @param disputeId The dispute ID
     * @param evidenceHash IPFS hash of evidence
     */
    function submitEvidence(uint256 disputeId, bytes32 evidenceHash)
        external
        nonReentrant
        disputeExists(disputeId)
    {
        Dispute storage dispute = _disputes[disputeId];

        // Only pending or investigating state
        if (dispute.state != DisputeState.Pending && dispute.state != DisputeState.Investigating) {
            revert InvalidDisputeState();
        }

        // Only parties can submit evidence
        bool isPoster = msg.sender == dispute.poster;
        bool isPerformer = msg.sender == dispute.performer;

        if (!isPoster && !isPerformer) {
            revert NotParty();
        }

        // Check if DDR already deposited by this party
        if (_ddrDeposits[disputeId][msg.sender] == 0) {
            // Deposit DDR
            usdc.safeTransferFrom(msg.sender, address(this), dispute.ddrAmount);
            _ddrDeposits[disputeId][msg.sender] = dispute.ddrAmount;
        }

        // Store evidence hash
        if (isPoster) {
            if (dispute.posterEvidenceHash != bytes32(0)) {
                revert EvidenceAlreadySubmitted();
            }
            dispute.posterEvidenceHash = evidenceHash;
        } else {
            if (dispute.performerEvidenceHash != bytes32(0)) {
                revert EvidenceAlreadySubmitted();
            }
            dispute.performerEvidenceHash = evidenceHash;
        }

        emit EvidenceSubmitted(disputeId, msg.sender, evidenceHash);
    }

    /**
     * @notice Resolve a dispute
     * @param disputeId The dispute ID
     * @param outcome The resolution outcome
     * @param resolutionHash IPFS hash of resolution details
     * @param splitPercentage Percentage for performer (0-10000 bps, only for Split)
     */
    function resolveDispute(
        uint256 disputeId,
        DisputeOutcome outcome,
        bytes32 resolutionHash,
        uint256 splitPercentage
    ) external disputeExists(disputeId) {
        Dispute storage dispute = _disputes[disputeId];

        if (msg.sender != dispute.resolver) {
            revert NotResolver();
        }

        if (dispute.state != DisputeState.Investigating) {
            revert InvalidDisputeState();
        }

        if (outcome == DisputeOutcome.None) {
            revert InvalidOutcome();
        }

        if (outcome == DisputeOutcome.Split && splitPercentage > 10_000) {
            revert InvalidOutcome();
        }

        // DDR Enforcement: The WINNER must have deposited DDR before resolution
        // This prevents deadlock if one party refuses to participate
        if (outcome == DisputeOutcome.PosterWins) {
            if (_ddrDeposits[disputeId][dispute.poster] == 0) revert InsufficientDDR();
        } else if (outcome == DisputeOutcome.PerformerWins) {
            if (_ddrDeposits[disputeId][dispute.performer] == 0) revert InsufficientDDR();
        } else {
            // For Split or Cancelled, require both parties to have deposited
            // This ensures mutual participation for complex outcomes
            if (
                _ddrDeposits[disputeId][dispute.poster] == 0
                    || _ddrDeposits[disputeId][dispute.performer] == 0
            ) {
                revert InsufficientDDR();
            }
        }

        dispute.outcome = outcome;
        dispute.resolutionHash = resolutionHash;
        dispute.state = DisputeState.Resolved;
        dispute.resolvedAt = block.timestamp;
        dispute.appealDeadline = block.timestamp + APPEAL_PERIOD;

        if (outcome == DisputeOutcome.Split) {
            _splitPercentages[disputeId] = splitPercentage;
        }

        emit DisputeResolved(disputeId, outcome, resolutionHash);
    }

    /**
     * @notice Appeal a resolution to the DAO
     * @param disputeId The dispute ID
     */
    function appealResolution(uint256 disputeId) external disputeExists(disputeId) {
        Dispute storage dispute = _disputes[disputeId];

        // Only parties can appeal
        if (msg.sender != dispute.poster && msg.sender != dispute.performer) {
            revert NotParty();
        }

        if (dispute.state != DisputeState.Resolved) {
            revert InvalidDisputeState();
        }

        if (block.timestamp > dispute.appealDeadline) {
            revert AppealPeriodEnded();
        }

        dispute.state = DisputeState.Appealed;

        emit DisputeAppealed(disputeId, msg.sender);
    }

    /**
     * @notice Finalize dispute and distribute funds
     * @param disputeId The dispute ID
     */
    function finalizeDispute(uint256 disputeId) external nonReentrant disputeExists(disputeId) {
        Dispute storage dispute = _disputes[disputeId];

        if (dispute.state == DisputeState.Resolved) {
            // Must wait for appeal period
            if (block.timestamp < dispute.appealDeadline) {
                revert AppealPeriodActive();
            }
        } else {
            // Appealed disputes are finalized by DAO override
            revert InvalidDisputeState();
        }

        dispute.state = DisputeState.Finalized;

        // Distribute funds based on outcome
        _distributeFunds(disputeId);
    }

    /**
     * @notice Override resolution (only DAO)
     * @param disputeId The dispute ID
     * @param newOutcome The new outcome
     * @param resolutionHash IPFS hash of resolution details
     * @param splitPercentage Percentage for performer (0-10000 bps, only for Split)
     */
    function overrideResolution(
        uint256 disputeId,
        DisputeOutcome newOutcome,
        bytes32 resolutionHash,
        uint256 splitPercentage
    ) external onlyProtocolDAO disputeExists(disputeId) {
        Dispute storage dispute = _disputes[disputeId];

        if (dispute.state != DisputeState.Appealed) {
            revert InvalidDisputeState();
        }

        if (newOutcome == DisputeOutcome.None) {
            revert InvalidOutcome();
        }

        dispute.outcome = newOutcome;
        dispute.resolutionHash = resolutionHash;
        dispute.state = DisputeState.Finalized;

        if (newOutcome == DisputeOutcome.Split) {
            _splitPercentages[disputeId] = splitPercentage;
        }

        // Distribute funds
        _distributeFunds(disputeId);

        emit DisputeResolved(disputeId, newOutcome, resolutionHash);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return _disputes[disputeId];
    }

    function getDisputesByMission(uint256 missionId) external view returns (uint256[] memory) {
        return _missionDisputes[missionId];
    }

    function getDDRRate() external pure returns (uint256) {
        return DDR_RATE_BPS;
    }

    function getLPPRate() external pure returns (uint256) {
        return LPP_RATE_BPS;
    }

    function getAppealPeriod() external pure returns (uint256) {
        return APPEAL_PERIOD;
    }

    function getDDRDeposit(uint256 disputeId, address party) external view returns (uint256) {
        return _ddrDeposits[disputeId][party];
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    function setResolversDAO(address _resolversDAO) external onlyOwner {
        resolversDAO = _resolversDAO;
    }

    function setProtocolDAO(address _protocolDAO) external onlyOwner {
        protocolDAO = _protocolDAO;
    }

    function setTreasuries(address _protocolTreasury, address _resolverTreasury)
        external
        onlyOwner
    {
        protocolTreasury = _protocolTreasury;
        resolverTreasury = _resolverTreasury;
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================

    /**
     * @notice Distribute funds based on dispute outcome
     * @dev Implements DDR return and LPP penalty distribution
     *      Also calls escrow.settleDispute() to distribute reward funds
     */
    function _distributeFunds(uint256 disputeId) internal {
        Dispute storage dispute = _disputes[disputeId];

        // First, settle the escrow reward distribution
        IMissionEscrow escrow = IMissionEscrow(dispute.escrowAddress);
        uint256 splitBps = _splitPercentages[disputeId];
        escrow.settleDispute(uint8(dispute.outcome), splitBps);

        // Now handle DDR distributions
        uint256 posterDDR = _ddrDeposits[disputeId][dispute.poster];
        uint256 performerDDR = _ddrDeposits[disputeId][dispute.performer];
        uint256 totalDDR = posterDDR + performerDDR;

        // Calculate fees from DDR pool
        uint256 resolverFee = (totalDDR * RESOLVER_FEE_BPS) / 10_000;
        uint256 protocolFee = (totalDDR * PROTOCOL_FEE_BPS) / 10_000;
        uint256 remainingDDR = totalDDR - resolverFee - protocolFee;

        uint256 posterPayout = 0;
        uint256 performerPayout = 0;

        if (dispute.outcome == DisputeOutcome.PosterWins) {
            // Poster wins: gets remaining DDR
            posterPayout = remainingDDR;
        } else if (dispute.outcome == DisputeOutcome.PerformerWins) {
            // Performer wins: gets remaining DDR
            performerPayout = remainingDDR;
        } else if (dispute.outcome == DisputeOutcome.Split) {
            // Split: DDR returned proportionally
            posterPayout = (remainingDDR * (10_000 - splitBps)) / 10_000;
            performerPayout = (remainingDDR * splitBps) / 10_000;
        } else if (dispute.outcome == DisputeOutcome.Cancelled) {
            // Cancelled: DDR returned proportionally to what each deposited
            if (totalDDR > 0) {
                posterPayout = (remainingDDR * posterDDR) / totalDDR;
                performerPayout = (remainingDDR * performerDDR) / totalDDR;
            }
        }

        // Transfer DDR payouts
        if (posterPayout > 0) {
            usdc.safeTransfer(dispute.poster, posterPayout);
        }
        if (performerPayout > 0) {
            usdc.safeTransfer(dispute.performer, performerPayout);
        }
        if (resolverFee > 0) {
            usdc.safeTransfer(resolverTreasury, resolverFee);
        }
        if (protocolFee > 0) {
            usdc.safeTransfer(protocolTreasury, protocolFee);
        }

        emit DisputeFinalized(
            disputeId, dispute.outcome, posterPayout, performerPayout, resolverFee, protocolFee
        );
    }
}

