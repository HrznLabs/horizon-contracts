// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title HorizonAchievements
 * @author Horizon Protocol
 * @notice NFT contract for achievements and collectibles
 * @dev Supports both Soulbound (non-transferable) and Tradable NFTs
 *
 * Achievement Types:
 * - Soulbound: Cannot be transferred, represents personal achievements
 * - Tradable: Can be transferred, represents collectibles and special items
 *
 * NatSpec Events:
 * - AchievementMinted: When a new achievement is minted
 * - AchievementTypeCreated: When a new achievement type is registered
 */
contract HorizonAchievements is ERC721, ERC721URIStorage, ERC721Enumerable, AccessControl {
    using Strings for uint256;

    // =============================================================================
    // CONSTANTS
    // =============================================================================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // =============================================================================
    // ENUMS
    // =============================================================================

    enum AchievementCategory {
        Milestone, // Mission milestones (first mission, 100 missions, etc.)
        Performance, // Performance-based (speed runner, perfect rating)
        Guild, // Guild-related achievements
        Seasonal, // Limited-time seasonal achievements
        Special // Special events and promotions
    }

    // =============================================================================
    // STRUCTS
    // =============================================================================

    /// @dev Optimized storage layout for AchievementType
    /// Slot 0: name
    /// Slot 1: description
    /// Slot 2: baseTokenURI
    /// Slot 3: typeId (12) + xpReward (12) + maxSupply (8) = 32 bytes (Packed)
    /// Slot 4: currentSupply (8) + category (1) + isSoulbound (1) + isActive (1) = 11 bytes (Packed)
    struct AchievementTypeStorage {
        string name;
        string description;
        string baseTokenURI;
        uint96 typeId;
        uint96 xpReward;
        uint64 maxSupply;
        uint64 currentSupply;
        AchievementCategory category;
        bool isSoulbound;
        bool isActive;
    }

    /// @dev External facing struct for ABI compatibility
    struct AchievementType {
        uint256 typeId;
        string name;
        string description;
        AchievementCategory category;
        bool isSoulbound; // True = non-transferable
        bool isActive; // Can still be minted
        uint256 maxSupply; // 0 = unlimited
        uint256 currentSupply;
        string baseTokenURI;
        uint256 xpReward; // XP awarded when earned
    }

    /// @dev Optimized storage layout for Achievement
    /// Slot 0: originalOwner (20) + mintedAt (8) + typeId (4) = 32 bytes (Packed)
    /// Slot 1: proofHash (32)
    struct AchievementStorage {
        // tokenId is not stored as it is the key
        address originalOwner;
        uint64 mintedAt;
        uint32 typeId;
        bytes32 proofHash;
    }

    /// @dev External facing struct for ABI compatibility
    struct Achievement {
        uint256 tokenId;
        uint256 typeId;
        address originalOwner; // For soulbound verification
        uint256 mintedAt;
        bytes32 proofHash; // Hash of proof data (mission ID, etc.)
    }

    // =============================================================================
    // STATE
    // =============================================================================

    /// @notice Counter for token IDs
    uint256 private _tokenIdCounter;

    /// @notice Counter for achievement type IDs
    uint256 private _typeIdCounter;

    /// @notice Mapping from type ID to AchievementTypeStorage
    mapping(uint256 => AchievementTypeStorage) private _achievementTypes;

    /// @notice Mapping from token ID to AchievementStorage data
    mapping(uint256 => AchievementStorage) private _achievements;

    /// @notice Mapping to track which achievements a user has (type ID => user => bool)
    mapping(uint256 => mapping(address => bool)) private _userHasAchievement;

    /// @notice Mapping from user to their achievements of each type
    mapping(address => mapping(uint256 => uint256)) private _userAchievementToken;

    /// @notice Base URI for metadata
    string private _baseTokenURI;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event AchievementTypeCreated(
        uint256 indexed typeId,
        string name,
        AchievementCategory category,
        bool isSoulbound,
        uint256 maxSupply
    );

    event AchievementMinted(
        uint256 indexed tokenId,
        uint256 indexed typeId,
        address indexed recipient,
        bytes32 proofHash
    );

    event AchievementTypeUpdated(uint256 indexed typeId, bool isActive);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error AchievementTypeNotFound();
    error AchievementTypeInactive();
    error MaxSupplyReached();
    error AlreadyHasAchievement();
    error SoulboundTransferNotAllowed();
    error InvalidRecipient();
    error NotOriginalOwner();
    error ReentrancyDetected();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(string memory name, string memory symbol, string memory baseURI)
        ERC721(name, symbol)
    {
        _baseTokenURI = baseURI;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Create a new achievement type
     * @param name Name of the achievement
     * @param description Description of how to earn it
     * @param category Achievement category
     * @param _isSoulbound Whether the achievement is non-transferable
     * @param maxSupply Maximum number that can be minted (0 = unlimited)
     * @param _tokenURI Base URI for this achievement type
     * @param xpReward XP awarded when achievement is earned
     * @return typeId The ID of the created achievement type
     */
    function createAchievementType(
        string calldata name,
        string calldata description,
        AchievementCategory category,
        bool _isSoulbound,
        uint256 maxSupply,
        string calldata _tokenURI,
        uint256 xpReward
    ) external onlyRole(ADMIN_ROLE) returns (uint256 typeId) {
        _typeIdCounter++;
        typeId = _typeIdCounter;

        _achievementTypes[typeId] = AchievementTypeStorage({
            name: name,
            description: description,
            baseTokenURI: _tokenURI,
            typeId: uint96(typeId),
            xpReward: uint96(xpReward),
            maxSupply: uint64(maxSupply),
            currentSupply: 0,
            category: category,
            isSoulbound: _isSoulbound,
            isActive: true
        });

        emit AchievementTypeCreated(typeId, name, category, _isSoulbound, maxSupply);
    }

    /**
     * @notice Update achievement type active status
     * @param typeId The achievement type ID
     * @param isActive Whether the achievement is still mintable
     */
    function setAchievementTypeActive(uint256 typeId, bool isActive) external onlyRole(ADMIN_ROLE) {
        if (_achievementTypes[typeId].typeId == 0) {
            revert AchievementTypeNotFound();
        }

        _achievementTypes[typeId].isActive = isActive;

        emit AchievementTypeUpdated(typeId, isActive);
    }

    /**
     * @notice Set the base URI for metadata
     * @param baseURI The new base URI
     */
    function setBaseURI(string calldata baseURI) external onlyRole(ADMIN_ROLE) {
        _baseTokenURI = baseURI;
    }

    // =============================================================================
    // MINTING FUNCTIONS
    // =============================================================================

    /**
     * @notice Mint an achievement to a recipient
     * @param to Recipient address
     * @param typeId Achievement type ID
     * @param proofHash Hash of proof data (mission ID, etc.)
     * @return tokenId The ID of the minted token
     */
    function mintAchievement(address to, uint256 typeId, bytes32 proofHash)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert InvalidRecipient();

        AchievementTypeStorage storage achievementType = _achievementTypes[typeId];

        if (achievementType.typeId == 0) {
            revert AchievementTypeNotFound();
        }

        if (!achievementType.isActive) {
            revert AchievementTypeInactive();
        }

        if (
            achievementType.maxSupply > 0
                && achievementType.currentSupply >= achievementType.maxSupply
        ) {
            revert MaxSupplyReached();
        }

        // For soulbound achievements, check if user already has it
        if (achievementType.isSoulbound && _userHasAchievement[typeId][to]) {
            revert AlreadyHasAchievement();
        }

        // Increment counters
        _tokenIdCounter++;
        tokenId = _tokenIdCounter;
        achievementType.currentSupply++;

        // Create achievement data
        _achievements[tokenId] = AchievementStorage({
            originalOwner: to,
            mintedAt: uint64(block.timestamp),
            typeId: uint32(typeId),
            proofHash: proofHash
        });

        // Track user achievement
        _userHasAchievement[typeId][to] = true;
        _userAchievementToken[to][typeId] = tokenId;

        // Mint NFT
        _safeMint(to, tokenId);

        emit AchievementMinted(tokenId, typeId, to, proofHash);
    }

    /**
     * @notice Batch mint achievements to multiple recipients
     * @param recipients Array of recipient addresses
     * @param typeId Achievement type ID
     * @param proofHashes Array of proof hashes
     * @return tokenIds Array of minted token IDs
     */
    function batchMintAchievements(
        address[] calldata recipients,
        uint256 typeId,
        bytes32[] calldata proofHashes
    ) external onlyRole(MINTER_ROLE) returns (uint256[] memory tokenIds) {
        require(recipients.length == proofHashes.length, "Length mismatch");

        uint256 packedConfig; // [0..63] maxSupply, [64..127] originalCurrentSupply, [128] isSoulbound
        uint64 currentSupply;

        {
            AchievementTypeStorage storage achievementType = _achievementTypes[typeId];
            if (achievementType.typeId == 0) revert AchievementTypeNotFound();
            if (!achievementType.isActive) revert AchievementTypeInactive();

            packedConfig = uint256(achievementType.maxSupply)
                | (uint256(achievementType.currentSupply) << 64)
                | ((achievementType.isSoulbound ? 1 : 0) << 128);
            currentSupply = achievementType.currentSupply;
        }

        uint256 startTokenId = _tokenIdCounter;
        uint256 nextTokenId = startTokenId;

        tokenIds = new uint256[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];

            // Skip if already has achievement (for soulbound)
            // isSoulbound is bit 128
            if (((packedConfig >> 128) & 1) == 1 && _userHasAchievement[typeId][to]) {
                continue;
            }

            // Check max supply
            // maxSupply is bits 0-63
            uint64 maxSupply = uint64(packedConfig);
            if (maxSupply > 0 && currentSupply >= maxSupply) {
                revert MaxSupplyReached();
            }

            nextTokenId++;
            uint256 tokenId = nextTokenId;
            currentSupply++;

            _achievements[tokenId] = AchievementStorage({
                originalOwner: to,
                mintedAt: uint64(block.timestamp),
                typeId: uint32(typeId),
                proofHash: proofHashes[i]
            });

            _userHasAchievement[typeId][to] = true;
            _userAchievementToken[to][typeId] = tokenId;

            _safeMint(to, tokenId);

            emit AchievementMinted(tokenId, typeId, to, proofHashes[i]);

            tokenIds[i] = tokenId;
        }

        if (nextTokenId > startTokenId) {
            // Check for reentrancy
            // originalCurrentSupply is bits 64-127
            uint64 originalCurrentSupply = uint64(packedConfig >> 64);
            if (_achievementTypes[typeId].currentSupply != originalCurrentSupply) {
                revert ReentrancyDetected();
            }
            if (_tokenIdCounter != startTokenId) revert ReentrancyDetected();

            _achievementTypes[typeId].currentSupply = currentSupply;
            _tokenIdCounter = nextTokenId;
        }
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get achievement type details
     * @param typeId The achievement type ID
     * @return Achievement type data
     */
    function getAchievementType(uint256 typeId) external view returns (AchievementType memory) {
        AchievementTypeStorage storage s = _achievementTypes[typeId];
        return AchievementType({
            typeId: uint256(s.typeId),
            name: s.name,
            description: s.description,
            category: s.category,
            isSoulbound: s.isSoulbound,
            isActive: s.isActive,
            maxSupply: uint256(s.maxSupply),
            currentSupply: uint256(s.currentSupply),
            baseTokenURI: s.baseTokenURI,
            xpReward: uint256(s.xpReward)
        });
    }

    /**
     * @notice Get achievement data by token ID
     * @param tokenId The token ID
     * @return Achievement data
     */
    function getAchievement(uint256 tokenId) external view returns (Achievement memory) {
        AchievementStorage storage s = _achievements[tokenId];
        return Achievement({
            tokenId: tokenId,
            typeId: uint256(s.typeId),
            originalOwner: s.originalOwner,
            mintedAt: uint256(s.mintedAt),
            proofHash: s.proofHash
        });
    }

    /**
     * @notice Check if a user has a specific achievement type
     * @param user User address
     * @param typeId Achievement type ID
     * @return True if user has the achievement
     */
    function hasAchievement(address user, uint256 typeId) external view returns (bool) {
        return _userHasAchievement[typeId][user];
    }

    /**
     * @notice Get user's token ID for a specific achievement type
     * @param user User address
     * @param typeId Achievement type ID
     * @return Token ID (0 if not owned)
     */
    function getUserAchievementToken(address user, uint256 typeId) external view returns (uint256) {
        return _userAchievementToken[user][typeId];
    }

    /**
     * @notice Check if a token is soulbound
     * @param tokenId The token ID
     * @return True if token is soulbound
     */
    function isSoulbound(uint256 tokenId) external view returns (bool) {
        return _achievementTypes[_achievements[tokenId].typeId].isSoulbound;
    }

    /**
     * @notice Get total number of achievement types
     * @return Total count
     */
    function totalAchievementTypes() external view returns (uint256) {
        return _typeIdCounter;
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================

    function _mintAchievementInternal(address to, uint256 typeId, bytes32 proofHash)
        internal
        returns (uint256 tokenId)
    {
        AchievementTypeStorage storage achievementType = _achievementTypes[typeId];

        // Increment counters
        _tokenIdCounter++;
        tokenId = _tokenIdCounter;
        achievementType.currentSupply++;

        // Create achievement data
        _achievements[tokenId] = AchievementStorage({
            originalOwner: to,
            mintedAt: uint64(block.timestamp),
            typeId: uint32(typeId),
            proofHash: proofHash
        });

        // Track user achievement
        _userHasAchievement[typeId][to] = true;
        _userAchievementToken[to][typeId] = tokenId;

        // Mint NFT
        _safeMint(to, tokenId);

        emit AchievementMinted(tokenId, typeId, to, proofHash);
    }

    // =============================================================================
    // OVERRIDES
    // =============================================================================

    /**
     * @notice Override transfer to enforce soulbound restrictions
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // If this is a transfer (not mint/burn), check soulbound
        if (from != address(0) && to != address(0)) {
            AchievementStorage storage achievement = _achievements[tokenId];
            AchievementTypeStorage storage achievementType = _achievementTypes[achievement.typeId];

            if (achievementType.isSoulbound) {
                revert SoulboundTransferNotAllowed();
            }

            // Update tracking for tradable NFTs
            _userHasAchievement[achievement.typeId][from] = false;
            _userHasAchievement[achievement.typeId][to] = true;
            _userAchievementToken[from][achievement.typeId] = 0;
            _userAchievementToken[to][achievement.typeId] = tokenId;
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        AchievementStorage storage achievement = _achievements[tokenId];
        AchievementTypeStorage storage achievementType = _achievementTypes[achievement.typeId];

        // Use achievement type's base URI if set
        if (bytes(achievementType.baseTokenURI).length > 0) {
            return string(abi.encodePacked(achievementType.baseTokenURI, tokenId.toString()));
        }

        return string(abi.encodePacked(_baseTokenURI, tokenId.toString()));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
