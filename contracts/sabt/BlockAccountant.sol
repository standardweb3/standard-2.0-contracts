// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {BlockAccountantLib, IAccountant} from "./libraries/BlockAccountantLib.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @author Hyungsuk Kang <hskang9@gmail.com>
/// @title Standard Membership Accountant to report membership points
contract BlockAccountant is AccessControl, Initializable {
    using BlockAccountantLib for BlockAccountantLib.Storage;

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    BlockAccountantLib.Storage private _accountant;

    error InvalidRole(bytes32 role, address sender);
    error NotTreasury(address sender, address treasury);
    error SPBCannotBeZero(uint32 spb_);

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address membership, address engine, address stablecoin, uint32 spb_) external initializer {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, _msgSender());
        }
        if (spb_ == 0) {
            revert SPBCannotBeZero(spb_);
        }
        _accountant.membership = membership;
        _accountant.engine = engine;
        _accountant.stablecoin = stablecoin;
        _accountant.stc1 = 10 ** IAccountant(stablecoin).decimals();
        _accountant.fb = block.number;
        _accountant.spb = spb_;
        _accountant.era = uint32(30 days / spb_);
    }

    function setStablecoin(address stablecoin) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, _msgSender());
        }
        _accountant.stablecoin = stablecoin;
    }

    // TODO: migrate point from one era to other uid for multiple membership holders
    /// @dev migrate: Migrate the membership point from one era to other uid
    /// @param fromUid_ The uid to migrate from
    /// @param toUid_ The uid to migrate to
    /// @param nthEra_ The era to migrate
    /// @param amount_ The amount of the point to migrate
    function migrate(uint32 fromUid_, uint32 toUid_, uint32 nthEra_, uint256 amount_) external {
        _accountant._migrate(fromUid_, toUid_, nthEra_, amount_);
    }

    /**
     * @dev report: Report the membership point of the member to update
     * @param uid The member uid
     * @param token The token address
     * @param amount The amount of the membership point
     * @param isAdd The flag to add or subtract the point
     */
    function report(uint32 uid, address token, uint256 amount, bool isAdd) external {
        if (!hasRole(REPORTER_ROLE, _msgSender())) {
            revert InvalidRole(REPORTER_ROLE, _msgSender());
        }
        if (_accountant._isSubscribed(uid)) {
            _accountant._report(uid, token, amount, isAdd);
        }
    }

    function subtractTP(uint32 uid, uint32 nthEra, uint64 point) external {
        if (msg.sender != _accountant.treasury) {
            revert NotTreasury(msg.sender, _accountant.treasury);
        }
        _accountant._subtractTP(uid, nthEra, point);
    }

    function getTotalPoints(uint32 nthEra) external view returns (uint256) {
        return _accountant._totalPoints(nthEra);
    }

    function getStablecoin() external view returns (address) {
        return _accountant.stablecoin;
    }

    function fb() external view returns (uint256) {
        return _accountant.fb;
    }

    function getCurrentEra() external view returns (uint32) {
        return _accountant._getEra();
    }

    function getTotalTokens(uint32 nthEra, address token) external view returns (uint256) {
        return _accountant._totalTokens(token, nthEra);
    }

    function pointOf(uint32 uid, uint32 nthEra) external view returns (uint256) {
        return _accountant._getTP(uid, nthEra);
    }

    function getSpb() external view returns (uint256) {
        return _accountant.spb;
    }

    function getTI(uint32 uid) external view returns (uint256) {
        return _accountant._getTI(uid, _accountant._getEra());
    }

    function levelOf(uint32 uid) external view returns (uint8) {
        return _accountant._getLevel(uid, _accountant._getEra());
    }

    function feeOf(uint32 uid, bool isMaker) external view returns (uint32) {
        return _accountant._getFeeRate(uid, _accountant._getEra(), isMaker);
    }
}
