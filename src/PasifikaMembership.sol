// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PasifikaTreasury.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/console.sol"; // Foundry console for logging

/**
 * @title PasifikaMembership
 * @dev Membership contract for Pasifika on Arbitrum
 * Members enjoy reduced fees (0.5% instead of 1%) across all platform services
 * Part of the 3-tier system: Guest (1% fee), Member (0.5% fee), Node Operator (0.25% fee)
 *
 * Includes the Pasifika Annual Event for profit-sharing:
 * "If we take care of our own, they will take care of us"
 * - 50% of Treasury profits are distributed equally to all members annually
 * - Pasifika Financial Year runs from Dec 27 to Dec 24 (Boxing Day to Christmas Eve)
 */
contract PasifikaMembership is AccessControl, ReentrancyGuard, Pausable {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MEMBERSHIP_MANAGER_ROLE = keccak256("MEMBERSHIP_MANAGER_ROLE");
    bytes32 public constant PROFIT_SHARING_MANAGER_ROLE = keccak256("PROFIT_SHARING_MANAGER_ROLE");

    // Treasury for collecting fees
    PasifikaTreasury public treasury;

    // Membership fee (equivalent to 0.0001 ETH)
    uint256 public membershipFee = 0.0001 ether;

    // Profit Sharing
    uint256 public constant PROFIT_SHARING_PERCENTAGE = 50; // 50% of profits
    uint256 public lastProfitSharingTimestamp;
    bool public profitSharingInProgress;
    uint256 public currentProfitSharingYear;
    uint256 public currentSharePerMember; // Store the fixed share per member for the current distribution

    // Profit Sharing Eligibility Requirements
    uint256 public requiredTransactionCount = 100; // Minimum transactions required in a year
    uint256 public requiredTransactionVolume = 1 ether; // Minimum transaction volume required in a year (1 ETH)

    // Membership status
    mapping(address => bool) public isMember;

    // Profit sharing claim status
    mapping(address => mapping(uint256 => bool)) public hasClaimed; // member -> year -> claimed

    // Transaction tracking for profit sharing eligibility
    mapping(address => mapping(uint256 => uint256)) public yearlyTransactionCount; // member -> year -> count
    mapping(address => mapping(uint256 => uint256)) public yearlyTransactionVolume; // member -> year -> volume

    // Membership details
    struct MemberInfo {
        address user;
        uint256 joinedTimestamp;
        bool active;
    }

    // Member registry
    mapping(address => MemberInfo) public memberInfo;
    address[] public members;

    // Events
    event MembershipCreated(address indexed member, uint256 fee, uint256 timestamp);
    event MembershipRevoked(address indexed member, uint256 timestamp);
    event MembershipFeeUpdated(uint256 newFee);
    event MembershipRestored(address indexed member, uint256 timestamp);
    event ProfitSharingInitiated(uint256 indexed year, uint256 totalAmount, uint256 timestamp);
    event ProfitSharingClaimed(address indexed member, uint256 indexed year, uint256 amount, uint256 timestamp);

    /**
     * @dev Constructor
     * @param _treasury Address of the PasifikaTreasury contract
     */
    constructor(address payable _treasury) {
        require(_treasury != address(0), "PasifikaMembership: zero treasury address");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MEMBERSHIP_MANAGER_ROLE, msg.sender);
        _grantRole(PROFIT_SHARING_MANAGER_ROLE, msg.sender);

        treasury = PasifikaTreasury(_treasury);
        lastProfitSharingTimestamp = block.timestamp;
    }

    /**
     * @dev Join as a member
     */
    function joinMembership() external payable nonReentrant whenNotPaused {
        require(!isMember[msg.sender], "PasifikaMembership: already a member");
        require(msg.value >= membershipFee, "PasifikaMembership: insufficient fee");

        // Create membership
        isMember[msg.sender] = true;
        memberInfo[msg.sender] = MemberInfo({ user: msg.sender, joinedTimestamp: block.timestamp, active: true });
        members.push(msg.sender);

        // Send fee to treasury
        if (msg.value > 0) {
            (bool success,) = payable(address(treasury)).call{ value: msg.value }(
                abi.encodeWithSignature("depositFees(string)", "Membership fee")
            );
            require(success, "PasifikaMembership: fee transfer failed");
        }

        emit MembershipCreated(msg.sender, membershipFee, block.timestamp);
    }

    /**
     * @dev Grant free membership (admin only)
     * @param user Address to grant membership to
     */
    function grantMembership(address user) external onlyRole(MEMBERSHIP_MANAGER_ROLE) {
        require(user != address(0), "PasifikaMembership: zero address");
        require(!isMember[user], "PasifikaMembership: already a member");

        // Create membership
        isMember[user] = true;
        memberInfo[user] = MemberInfo({ user: user, joinedTimestamp: block.timestamp, active: true });
        members.push(user);

        emit MembershipCreated(user, 0, block.timestamp);
    }

    /**
     * @dev Revoke membership (admin only)
     * @param user Address to revoke membership from
     */
    function revokeMembership(address user) external onlyRole(MEMBERSHIP_MANAGER_ROLE) {
        require(user != address(0), "PasifikaMembership: zero address");
        require(isMember[user], "PasifikaMembership: not a member");

        // Deactivate membership (don't remove from list)
        memberInfo[user].active = false;

        emit MembershipRevoked(user, block.timestamp);
    }

    /**
     * @dev Restore membership (admin only)
     * @param user Address to restore membership for
     */
    function restoreMembership(address user) external onlyRole(MEMBERSHIP_MANAGER_ROLE) {
        require(user != address(0), "PasifikaMembership: zero address");
        require(isMember[user] && !memberInfo[user].active, "PasifikaMembership: not a revoked member");

        // Reactivate membership
        memberInfo[user].active = true;

        emit MembershipRestored(user, block.timestamp);
    }

    /**
     * @dev Update membership fee (admin only)
     * @param newFee New membership fee
     */
    function updateMembershipFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        membershipFee = newFee;
        emit MembershipFeeUpdated(newFee);
    }

    /**
     * @dev Set treasury address (admin only)
     * @param _treasury New treasury address
     */
    function setTreasury(address payable _treasury) external onlyRole(ADMIN_ROLE) {
        require(_treasury != address(0), "PasifikaMembership: zero address");
        treasury = PasifikaTreasury(_treasury);
    }

    /**
     * @dev Initiate the annual profit sharing event (admin only)
     * This distributes 50% of the total profit from the treasury among members
     */
    function initiateProfitSharing() external onlyRole(PROFIT_SHARING_MANAGER_ROLE) {
        require(!profitSharingInProgress, "PasifikaMembership: profit sharing already in progress");

        // Get the current year for tracking
        uint256 year = block.timestamp / 31536000 + 1970; // Approximate year calculation

        // Get treasury balance in ETH
        uint256 treasuryBalance = address(treasury).balance;
        require(treasuryBalance > 0, "PasifikaMembership: treasury has no funds");

        // Calculate 50% of the balance for distribution
        uint256 amountToDistribute = (treasuryBalance * PROFIT_SHARING_PERCENTAGE) / 100;

        // Get count of eligible members from previous year
        uint256 eligibleMembersCount = getEligibleMembersCountForYear(year - 1);
        require(eligibleMembersCount > 0, "PasifikaMembership: no eligible members");

        // Calculate share per member
        currentSharePerMember = amountToDistribute / eligibleMembersCount;
        require(currentSharePerMember > 0, "PasifikaMembership: share too small");

        // Start profit sharing
        profitSharingInProgress = true;
        lastProfitSharingTimestamp = block.timestamp;
        currentProfitSharingYear = year;

        // Withdraw funds from treasury for distribution
        bool success = treasury.withdrawFunds(address(this), amountToDistribute);
        require(success, "PasifikaMembership: treasury transfer failed");

        emit ProfitSharingInitiated(year, amountToDistribute, block.timestamp);
    }

    /**
     * @dev Record a transaction for a member (called by PasifikaMoneyTransfer)
     * @param member Address of the member
     * @param amount Amount of the transaction
     */
    function recordTransaction(address member, uint256 amount) external {
        if (isMember[member] && memberInfo[member].active) {
            uint256 year = block.timestamp / 31536000 + 1970; // Approximate year calculation

            // Record transaction
            yearlyTransactionCount[member][year]++;
            yearlyTransactionVolume[member][year] += amount;
        }
    }

    /**
     * @dev Check if a member is eligible for profit sharing
     * @param member Address of the member
     * @param year Year to check eligibility for
     * @return Whether member is eligible for profit sharing
     */
    function isEligibleForProfitSharing(address member, uint256 year) public view returns (bool) {
        if (!isMember[member] || !memberInfo[member].active) {
            return false;
        }

        // Check if they meet the transaction requirements
        return yearlyTransactionCount[member][year] >= requiredTransactionCount
            && yearlyTransactionVolume[member][year] >= requiredTransactionVolume;
    }

    /**
     * @dev Claim profit share (members only)
     */
    function claimProfitShare() external nonReentrant {
        require(isMember[msg.sender], "PasifikaMembership: not a member");
        require(profitSharingInProgress, "PasifikaMembership: no profit sharing in progress");
        require(!hasClaimed[msg.sender][currentProfitSharingYear], "PasifikaMembership: already claimed");

        // Previous year's activity determines eligibility
        uint256 previousYear = currentProfitSharingYear - 1;

        // Check eligibility
        require(isEligibleForProfitSharing(msg.sender, previousYear), "PasifikaMembership: not eligible");

        // Mark as claimed
        hasClaimed[msg.sender][currentProfitSharingYear] = true;

        // Transfer the share to the member
        (bool success,) = payable(msg.sender).call{ value: currentSharePerMember }("");
        require(success, "PasifikaMembership: share transfer failed");

        emit ProfitSharingClaimed(msg.sender, currentProfitSharingYear, currentSharePerMember, block.timestamp);

        // Check if all eligible members have claimed
        uint256 year = currentProfitSharingYear;
        uint256 claimedCount = getClaimedCount(year);
        if (claimedCount >= getEligibleMembersCountForYear(year - 1)) {
            // All eligible members have claimed, end profit sharing
            profitSharingInProgress = false;
        }
    }

    /**
     * @dev Check if a member has claimed profit share for a specific year
     * @param member Member address
     * @param year Financial year
     * @return True if member has claimed for the specified year
     */
    function hasClaimedProfit(address member, uint256 year) external view returns (bool) {
        return hasClaimed[member][year];
    }

    /**
     * @dev Get number of members who have claimed profit sharing
     * @param year Year to check
     * @return Number of members who have claimed
     */
    function getClaimedCount(uint256 year) public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < members.length; i++) {
            if (hasClaimed[members[i]][year]) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Get count of active members
     * @return Count of active members
     */
    function getActiveMemberCount() public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < members.length; i++) {
            if (memberInfo[members[i]].active) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Alias function for getActiveMemberCount (plural version)
     * @return Count of active members
     */
    function getActiveMembersCount() public view returns (uint256) {
        return getActiveMemberCount();
    }

    /**
     * @dev Get count of eligible active members
     * @return Count of eligible active members
     */
    function getEligibleMembersCount() public view returns (uint256) {
        return getEligibleMembersCountForYear(currentProfitSharingYear - 1);
    }

    /**
     * @dev Get count of eligible active members for a specific year
     * @param year Year to check eligibility for
     * @return Count of eligible active members
     */
    function getEligibleMembersCountForYear(uint256 year) public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < members.length; i++) {
            if (memberInfo[members[i]].active && isEligibleForProfitSharing(members[i], year)) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Set transaction requirements for profit sharing eligibility (admin only)
     * @param count Minimum transaction count required
     * @param volume Minimum transaction volume required (in wei)
     */
    function setEligibilityRequirements(uint256 count, uint256 volume) external onlyRole(ADMIN_ROLE) {
        requiredTransactionCount = count;
        requiredTransactionVolume = volume;
    }

    /**
     * @dev Finalize profit sharing (admin only)
     * This would transfer any remaining tokens back to the treasury
     */
    function finalizeProfitSharing() external onlyRole(PROFIT_SHARING_MANAGER_ROLE) {
        require(profitSharingInProgress, "PasifikaMembership: no profit sharing in progress");

        // Check if at least 24 hours have passed since initiation
        require(block.timestamp >= lastProfitSharingTimestamp + 1 days, "PasifikaMembership: too early to finalize");

        // Transfer any remaining ETH back to treasury
        uint256 remainingBalance = address(this).balance;
        if (remainingBalance > 0) {
            (bool success,) = payable(address(treasury)).call{ value: remainingBalance }(
                abi.encodeWithSignature(
                    "depositFunds(bytes32,string)", keccak256("UNALLOCATED"), "Profit sharing remainder"
                )
            );
            require(success, "PasifikaMembership: ETH transfer failed");
        }

        // Reset state
        profitSharingInProgress = false;
    }

    /**
     * @dev Check if an address is a member
     * @param user Address to check
     * @return True if address is an active member
     */
    function checkMembership(address user) external view returns (bool) {
        return isMember[user];
    }

    /**
     * @dev Get membership details
     * @param user Address to get details for
     * @return Member information
     */
    function getMemberDetails(address user) external view returns (MemberInfo memory) {
        return memberInfo[user];
    }

    /**
     * @dev Get total number of members (including inactive)
     * @return Total member count
     */
    function getMemberCount() external view returns (uint256) {
        return members.length;
    }

    /**
     * @dev Get members with pagination
     * @param offset Starting index
     * @param limit Maximum number of members to return
     * @return Array of member addresses
     */
    function getMembers(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = members.length;

        if (offset >= total) {
            return new address[](0);
        }

        uint256 count = (total - offset) < limit ? (total - offset) : limit;
        address[] memory result = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = members[offset + i];
        }

        return result;
    }

    /**
     * @dev Pause contract (admin only)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract (admin only)
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Receive function for direct deposits
     * If profit sharing is in progress, simply receive the ETH.
     * Otherwise, forward it to treasury as a fee.
     */
    receive() external payable {
        // Skip forwarding during profit sharing to avoid re-entrancy
        if (profitSharingInProgress) {
            return; // Just accept the ETH during profit sharing
        }

        // Forward to treasury
        (bool success,) = payable(address(treasury)).call{ value: msg.value }(
            abi.encodeWithSignature("depositFees(string)", "Direct membership payment")
        );
        require(success, "PasifikaMembership: transfer failed");
    }
}
