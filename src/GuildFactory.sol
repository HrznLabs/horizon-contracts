// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { GuildDAO } from "./GuildDAO.sol";

/**
 * @title GuildFactory
 * @notice Factory for deploying GuildDAO clones
 * @dev Uses minimal proxy pattern (EIP-1167) for gas-efficient deployment
 */
contract GuildFactory is Ownable, ReentrancyGuard {
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Implementation contract for GuildDAO clones
    address public immutable guildImplementation;

    /// @notice Current guild counter
    uint96 public guildCount;

    /// @notice Mapping from guild ID to guild address
    mapping(uint256 => address) public guilds;

    /// @notice Mapping from guild address to existence
    mapping(address => bool) public isGuild;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event GuildCreated(
        uint256 indexed id, address indexed guild, address indexed admin, string name
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error GuildNotFound();
    error InvalidName();

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
    function createGuild(string calldata name, address treasury, uint16 guildFeeBps)
        external
        nonReentrant
        returns (uint256 guildId, address guild)
    {
        if (bytes(name).length == 0 || bytes(name).length > 100) {
            revert InvalidName();
        }

        // Increment guild counter
        guildId = ++guildCount;

        // Deploy guild clone
        guild = guildImplementation.clone();

        // Initialize guild
        GuildDAO(guild)
            .initialize(
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

