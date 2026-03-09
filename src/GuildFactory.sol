// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GuildDAO} from "./GuildDAO.sol";

/**
 * @title GuildFactory
 * @notice Factory for deploying GuildDAO clones
 * @dev Uses minimal proxy pattern (EIP-1167) for gas-efficient deployment
 */
contract GuildFactory is Ownable {
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Implementation contract for GuildDAO clones
    address public immutable guildImplementation;

    /// @notice Current guild counter
    uint256 public guildCount;

    /// @notice Mapping from guild ID to guild address
    mapping(uint256 => address) public guilds;

    /// @notice Mapping from guild address to existence
    mapping(address => bool) public isGuild;

    /// @notice Mapping from MetaDAO address to existence
    mapping(address => bool) public isMetaDAO;

    /// @notice Mapping from SubDAO to its parent MetaDAO
    mapping(address => address) public subDAOToMetaDAO;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event GuildCreated(
        uint256 indexed id,
        address indexed guild,
        address indexed admin,
        string name
    );

    event MetaDAOCreated(
        uint256 indexed id,
        address indexed metaDAO,
        address indexed admin,
        string name
    );

    event SubDAOCreated(
        uint256 indexed id,
        address indexed subDAO,
        address indexed metaDAO,
        string name
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error GuildNotFound();
    error InvalidName();
    error InvalidMetaDAO();
    error InvalidFee();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor() Ownable(msg.sender) {
        // Deploy the implementation contract
        guildImplementation = address(new GuildDAO());
    }

    // =============================================================================
    // GUILD CREATION
    // =============================================================================

    /**
     * @notice Create a new guild
     * @param name Guild name
     * @param treasury Treasury address for the guild
     * @param guildFeeBps Fee in basis points (max 1000 = 10%)
     * @return guildId The ID of the created guild
     * @return guild The address of the created guild
     */
    function createGuild(
        string calldata name,
        address treasury,
        uint16 guildFeeBps
    ) external returns (uint256 guildId, address guild) {
        if (bytes(name).length == 0 || bytes(name).length > 100) {
            revert InvalidName();
        }

        // Increment guild counter
        guildId = ++guildCount;

        // Deploy guild clone
        guild = guildImplementation.clone();

        // Initialize guild
        GuildDAO(guild).initialize(
            name,
            msg.sender, // Creator becomes admin
            treasury,
            guildFeeBps
        );

        // Store mappings
        guilds[guildId] = guild;
        isGuild[guild] = true;

        emit GuildCreated(guildId, guild, msg.sender, name);
    }

    /**
     * @notice Create a new MetaDAO (can have SubDAOs)
     * @param name MetaDAO name
     * @param treasury Treasury address
     * @param guildFeeBps Fee in basis points
     * @return guildId The ID of the created MetaDAO
     * @return metaDAO The address of the created MetaDAO
     */
    function createMetaDAO(
        string calldata name,
        address treasury,
        uint16 guildFeeBps
    ) external returns (uint256 guildId, address metaDAO) {
        if (bytes(name).length == 0 || bytes(name).length > 100) {
            revert InvalidName();
        }

        guildId = ++guildCount;
        metaDAO = guildImplementation.clone();

        GuildDAO(metaDAO).initializeAsMetaDAO(
            name,
            msg.sender,
            treasury,
            guildFeeBps
        );

        guilds[guildId] = metaDAO;
        isGuild[metaDAO] = true;
        isMetaDAO[metaDAO] = true;

        emit MetaDAOCreated(guildId, metaDAO, msg.sender, name);
    }

    /**
     * @notice Create a new SubDAO under a MetaDAO
     * @param name SubDAO name
     * @param treasury Treasury address
     * @param subDAOFeeBps SubDAO's own fee in basis points
     * @param parentMetaDAO Parent MetaDAO address
     * @param metaDAOFeeBps Fee to pay parent MetaDAO (max 100 = 1%)
     * @return guildId The ID of the created SubDAO
     * @return subDAO The address of the created SubDAO
     */
    function createSubDAO(
        string calldata name,
        address treasury,
        uint16 subDAOFeeBps,
        address parentMetaDAO,
        uint16 metaDAOFeeBps
    ) external returns (uint256 guildId, address subDAO) {
        if (bytes(name).length == 0 || bytes(name).length > 100) {
            revert InvalidName();
        }
        if (!isMetaDAO[parentMetaDAO]) {
            revert InvalidMetaDAO();
        }
        if (metaDAOFeeBps > 100) {
            revert InvalidFee();
        }

        guildId = ++guildCount;
        subDAO = guildImplementation.clone();

        GuildDAO(subDAO).initializeAsSubDAO(
            name,
            msg.sender,
            treasury,
            subDAOFeeBps,
            parentMetaDAO,
            metaDAOFeeBps
        );

        guilds[guildId] = subDAO;
        isGuild[subDAO] = true;
        subDAOToMetaDAO[subDAO] = parentMetaDAO;

        // Note: SubDAO must be registered with MetaDAO manually by MetaDAO admin
        // This is because GuildFactory doesn't have ADMIN_ROLE on the MetaDAO
        // Call: GuildDAO(parentMetaDAO).registerSubDAO(subDAO) as MetaDAO admin

        emit SubDAOCreated(guildId, subDAO, parentMetaDAO, name);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get guild address by ID
     * @param guildId The guild ID
     * @return guild The guild contract address
     */
    function getGuild(uint256 guildId) external view returns (address guild) {
        guild = guilds[guildId];
        if (guild == address(0)) revert GuildNotFound();
    }

    /**
     * @notice Check if address is a valid guild
     * @param guild Address to check
     * @return True if valid guild
     */
    function isValidGuild(address guild) external view returns (bool) {
        return isGuild[guild];
    }
}


