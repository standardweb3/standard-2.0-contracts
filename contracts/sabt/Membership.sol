// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MembershipLib} from "./libraries/MembershipLib.sol";

/// @author Hyungsuk Kang <hskang9@gmail.com>
/// @title Standard Membership registration and subscription
contract Membership is AccessControl {
    using MembershipLib for MembershipLib.Member;

    bytes32 public constant PROMOTER_ROLE = keccak256("PROMOTER_ROLE");

    MembershipLib.Member private _membership;

    error InvalidMeta(uint16 metaId_, address sender);
    error InvalidRole(bytes32 role, address sender);

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address sabt_, address foundation_) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        _membership.sabt = sabt_;
        _membership.foundation = foundation_;
    }

    /// @dev setFees: Set fees for registration and subscription and token address
    /// @param feeToken_ The address of the token to pay the fee
    /// @param regFee_ The registration fee per block in one token
    /// @param subFee_ The subscription fee per block in one token
    /// @param metaId_ The meta id of the token to pay the fee
    /// @param quotas_ The number of tokens to be issued for registration
    function setMembership(
        uint16 metaId_,
        address feeToken_,
        uint32 regFee_,
        uint32 subFee_,
        uint32 quotas_
    ) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (metaId_ == 0) {
            revert InvalidMeta(metaId_, msg.sender);
        }
        _membership._setMembership(
            metaId_,
            feeToken_,
            regFee_,
            subFee_,
            quotas_
        );
    }

    function setFoundation(address foundation_) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        _membership.foundation = foundation_;
    }

    function setQuota(uint16 metaId_, uint32 quota_) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        _membership._setQuota(metaId_, quota_);
    }

    function setFees(
        uint16 metaId_,
        address feeToken_,
        uint256 regFee_,
        uint256 subFee_
    ) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        _membership._setFees(metaId_, feeToken_, regFee_, subFee_);
    }

    /// @dev register: Register as a member
    function register(
        uint16 metaId_,
        address feeToken_
    ) external returns (uint32 uid) {
        // check if metaId is valid
        if (metaId_ == 0 || _membership.metas[metaId_].metaId != metaId_) {
            revert InvalidMeta(metaId_, msg.sender);
        }
        return _membership._register(metaId_, feeToken_);
    }

    /**  @dev subscribe: Subscribe to the membership until certain block height
    * @param uid_ The uid of the ABT to subscribe with
    * @param blocks_ The number of blocks to remain subscribed
    * @param feeToken_ The address of the token to pay the fee
    */ 
    function subscribe(
        uint32 uid_,
        uint64 blocks_,
        address feeToken_
    ) external {
        _membership._subscribe(uid_, blocks_, feeToken_);
    }

    function offerBonus(
        uint32 uid_,
        address holder_,
        uint256 blocks_
    ) external {
        if (!hasRole(PROMOTER_ROLE, msg.sender)) {
            revert InvalidRole(PROMOTER_ROLE, msg.sender);
        }
        _membership._offerBonus(uid_, holder_, blocks_);
    }

    /// @dev unsubscribe: Unsubscribe from the membership
    /// @param uid_ The id of the ABT to unsubscribe with
    function unsubscribe(uint32 uid_) external {
        _membership._unsubscribe(uid_);
    }

    function balanceOf(
        address who,
        uint32 uid_
    ) external view returns (uint256) {
        return _membership._balanceOf(who, uid_);
    }

    function getMeta(
        uint16 metaId_
    ) external view returns (MembershipLib.Meta memory) {
        return _membership.metas[metaId_];
    }

    function isSubscribed(uint32 uid_) external view returns (bool) {
        return _membership._isSubscribed(uid_);
    }

    function isReportable(
        address sender,
        uint32 uid_
    ) external view returns (bool) {
        return
            _membership._balanceOf(sender, uid_) > 0 &&
            _membership._isSubscribed(uid_);
    }
}
