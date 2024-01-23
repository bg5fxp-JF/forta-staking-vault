// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IFortaStaking, DELEGATOR_SCANNER_POOL_SUBJECT} from "./interfaces/IFortaStaking.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {FortaStakingUtils} from "./utils/FortaStakingUtils.sol";
import {OperatorFeeUtils, FEE_BASIS_POINTS_DENOMINATOR} from "./utils/OperatorFeeUtils.sol";
import {RedemptionReceiver} from "./RedemptionReceiver.sol";
import {InactiveSharesDistributor} from "./InactiveSharesDistributor.sol";

contract FortaStakingVault is AccessControl, ERC4626, ERC1155Holder {
    using Clones for address;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    mapping(uint256 => uint256) public assetsPerSubject;

    mapping(uint256 => uint256) private subjectIndex;
    uint256[] public subjects;

    mapping(uint256 => uint256) private subjectInactiveSharesDistributorIndex;
    mapping(uint256 => uint256) private subjectDeadline;
    mapping(address => uint256) private distributorSubject;
    address[] public inactiveSharesDistributors;

    address public feeTreasury;
    uint256 public feeInBasisPoints; // e.g. 300 = 3%

    IRewardsDistributor private immutable _rewardsDistributor;

    IFortaStaking private immutable _staking;
    IERC20 private immutable _token;
    address private immutable _receiverImplementation;
    address private immutable _distributorImplementation;
    uint256 private _totalAssets;

    error NotOperator();
    error InvalidTreasury();
    error InvalidFee();
    error PendingUndelegation();
    error InvalidUndelegation();

    constructor(
        address asset_,
        address fortaStaking,
        address redemptionReceiverImplementation,
        address inactiveSharesDistributorImplementation,
        uint256 operatorFeeInBasisPoints,
        address operatorFeeTreasury,
        address rewardsDistributor_
    )
        ERC20("FORT Staking Vault", "vFORT")
        ERC4626(IERC20(asset_))
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _staking = IFortaStaking(fortaStaking);
        _token = IERC20(asset_);
        _receiverImplementation = redemptionReceiverImplementation;
        _distributorImplementation = inactiveSharesDistributorImplementation;
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor_);
        feeInBasisPoints = operatorFeeInBasisPoints;
        feeTreasury = operatorFeeTreasury;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Holder, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _updatePoolsAssets() private {
        for (uint256 i = 0; i < subjects.length; ++i) {
            _updatePoolAssets(subjects[i]);
        }
    }

    function _updatePoolAssets(uint256 subject) private {
        uint256 activeId = FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject);
        uint256 inactiveId = FortaStakingUtils.activeToInactive(activeId);

        uint256 assets = _staking.activeSharesToStake(activeId, _staking.balanceOf(address(this), activeId));

        if (subjectDeadline[subject] != 0) {
            assets += _staking.inactiveSharesToStake(
                inactiveId,
                IERC20(inactiveSharesDistributors[subjectInactiveSharesDistributorIndex[subject]]).balanceOf(
                    address(this)
                )
            );
        }

        if (assetsPerSubject[subject] != assets) {
            _totalAssets = _totalAssets - assetsPerSubject[subject] + assets;
            assetsPerSubject[subject] = assets;
        }
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    //// Called by OZ-Defender when RewardDistributor emits Rewarded event ////
    function claimRewards(uint256 subjectId, uint256 epochNumber) public {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epochNumber;
        _rewardsDistributor.claimRewards(DELEGATOR_SCANNER_POOL_SUBJECT, subjectId, epochs);
    }

    //// Operator functions ////

    function _validateIsOperator() private view {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotOperator();
        }
    }

    function delegate(uint256 subject, uint256 assets) public {
        _validateIsOperator();

        if (assetsPerSubject[subject] == 0) {
            subjectIndex[subject] = subjects.length;
            subjects.push(subject);
        }
        _token.approve(address(_staking), assets);
        uint256 balanceBefore = _token.balanceOf(address(this));
        _staking.deposit(DELEGATOR_SCANNER_POOL_SUBJECT, subject, assets);
        uint256 balanceAfter = _token.balanceOf(address(this));
        // get the exact amount delivered to the pool
        assetsPerSubject[subject] += (balanceBefore - balanceAfter);
    }

    function initiateUndelegate(uint256 subject, uint256 shares) public returns (uint256, address) {
        _validateIsOperator();
        if (subjectDeadline[subject] != 0) {
            // can generate extra delays for users
            revert PendingUndelegation();
        }

        InactiveSharesDistributor distributor = InactiveSharesDistributor(_distributorImplementation.clone());
        _staking.safeTransferFrom(
            address(this),
            address(distributor),
            FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject),
            shares,
            ""
        );
        distributor.initialize(_staking, subject, shares);

        subjectInactiveSharesDistributorIndex[subject] = inactiveSharesDistributors.length;
        inactiveSharesDistributors.push(address(distributor));
        distributorSubject[address(distributor)] = subject;
        uint256 deadline = distributor.initiateUndelegate();
        subjectDeadline[subject] = deadline;
        return (deadline, address(distributor));
    }

    function undelegate(uint256 subject) public {
        _updatePoolAssets(subject);
        if (
            (subjectDeadline[subject] == 0) || (subjectDeadline[subject] > block.timestamp)
                || _staking.isFrozen(DELEGATOR_SCANNER_POOL_SUBJECT, subject)
        ) {
            revert InvalidUndelegation();
        }

        uint256 distributorIndex = subjectInactiveSharesDistributorIndex[subject];
        InactiveSharesDistributor distributor = InactiveSharesDistributor(inactiveSharesDistributors[distributorIndex]);

        uint256 beforeWithdrawBalance = _token.balanceOf(address(this));
        distributor.undelegate();
        uint256 afterWithdrawBalance = _token.balanceOf(address(this));

        // remove inactiveSharesDistributors
        address lastDistributor = inactiveSharesDistributors[inactiveSharesDistributors.length - 1];
        inactiveSharesDistributors[distributorIndex] = lastDistributor;
        subjectInactiveSharesDistributorIndex[distributorSubject[lastDistributor]] = distributorIndex;
        inactiveSharesDistributors.pop();
        delete subjectDeadline[subject];
        delete distributorSubject[address(distributor)];
        delete subjectInactiveSharesDistributorIndex[subject];

        assetsPerSubject[subject] -= (afterWithdrawBalance - beforeWithdrawBalance);

        if (assetsPerSubject[subject] == 0) {
            uint256 index = subjectIndex[subject];
            subjects[index] = subjects[subjects.length - 1];
            subjectIndex[subjects[index]] = index;
            subjects.pop();
            delete subjectIndex[subject];
        }
    }

    //// User operations ////

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _updatePoolsAssets();

        uint256 beforeDepositBalance = _token.balanceOf(address(this));
        uint256 shares = super.deposit(assets, receiver);
        uint256 afterDepositBalance = _token.balanceOf(address(this));

        _totalAssets += afterDepositBalance - beforeDepositBalance;

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _updatePoolsAssets();

        if (msg.sender != owner) {
            // caller needs to be allowed
            _spendAllowance(owner, msg.sender, shares);
        }
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        // user redemption contract
        RedemptionReceiver redemptionReceiver = RedemptionReceiver(createAndGetRedemptionReceiver(owner));

        {
            // Active shares redemption
            uint256 newUndelegations;
            uint256[] memory tempSharesToUndelegate = new uint256[](subjects.length);
            uint256[] memory tempSubjectsToUndelegateFrom = new uint256[](subjects.length);

            for (uint256 i = 0; i < subjects.length; ++i) {
                uint256 subject = subjects[i];
                uint256 subjectShares = _staking.sharesOf(DELEGATOR_SCANNER_POOL_SUBJECT, subject, address(this));
                uint256 sharesToUndelegateInSubject = Math.mulDiv(shares, subjectShares, totalSupply());
                if (sharesToUndelegateInSubject != 0) {
                    _staking.safeTransferFrom(
                        address(this),
                        address(redemptionReceiver),
                        FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject),
                        sharesToUndelegateInSubject,
                        ""
                    );
                    _updatePoolAssets(subject);
                    tempSharesToUndelegate[newUndelegations] = sharesToUndelegateInSubject;
                    tempSubjectsToUndelegateFrom[newUndelegations] = subject;
                    ++newUndelegations;
                }
            }
            uint256[] memory sharesToUndelegate = new uint256[](newUndelegations);
            uint256[] memory subjectsToUndelegateFrom = new uint256[](newUndelegations);
            for (uint256 i = 0; i < newUndelegations; ++i) {
                sharesToUndelegate[i] = tempSharesToUndelegate[i];
                subjectsToUndelegateFrom[i] = tempSubjectsToUndelegateFrom[i];
            }
            redemptionReceiver.addUndelegations(subjectsToUndelegateFrom, sharesToUndelegate);
        }

        {
            // Inactive shares redemption
            uint256 newUndelegations;
            address[] memory tempDistributors = new address[](inactiveSharesDistributors.length);

            for (uint256 i = 0; i < inactiveSharesDistributors.length; ++i) {
                InactiveSharesDistributor distributor = InactiveSharesDistributor(inactiveSharesDistributors[i]);
                uint256 vaultShares = distributor.balanceOf(address(this));
                uint256 sharesToUndelegateInDistributor = Math.mulDiv(shares, vaultShares, totalSupply());
                if (sharesToUndelegateInDistributor != 0) {
                    distributor.transfer(address(redemptionReceiver), sharesToUndelegateInDistributor);
                    _updatePoolAssets(distributorSubject[address(distributor)]);
                    tempDistributors[newUndelegations] = address(distributor);
                    ++newUndelegations;
                }
            }
            address[] memory distributorsToUndelegateFrom = new address[](newUndelegations);
            for (uint256 i = 0; i < newUndelegations; ++i) {
                distributorsToUndelegateFrom[i] = tempDistributors[i];
            }
            redemptionReceiver.addDistributors(distributorsToUndelegateFrom);
        }

        // send portion of assets in the pool
        uint256 vaultBalance = _token.balanceOf(address(this));
        uint256 vaultBalanceToRedeem = Math.mulDiv(shares, vaultBalance, totalSupply());

        uint256 userAmountToRedeem =
            OperatorFeeUtils.deductAndTransferFee(vaultBalanceToRedeem, feeInBasisPoints, feeTreasury, _token);

        _token.transfer(receiver, userAmountToRedeem);
        _totalAssets -= vaultBalanceToRedeem;
        _burn(owner, shares);

        return vaultBalanceToRedeem;
    }

    function claimRedeem(address receiver) public returns (uint256) {
        RedemptionReceiver redemptionReceiver = RedemptionReceiver(getRedemptionReceiver(msg.sender));
        return redemptionReceiver.claim(receiver, feeInBasisPoints, feeTreasury);
    }

    function getSalt(address user) private pure returns (bytes32) {
        return keccak256(abi.encode(user));
    }

    function getRedemptionReceiver(address user) public view returns (address) {
        return _receiverImplementation.predictDeterministicAddress(getSalt(user), address(this));
    }

    function createAndGetRedemptionReceiver(address user) private returns (address) {
        address receiver = getRedemptionReceiver(user);
        if (receiver.code.length == 0) {
            // create and initialize a new contract
            _receiverImplementation.cloneDeterministic(getSalt(user));
            RedemptionReceiver(receiver).initialize(address(this), _staking);
        }
        return receiver;
    }

    function updateFeeTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) {
            revert InvalidTreasury();
        }
        feeTreasury = treasury_;
    }

    function updateFeeBasisPoints(uint256 feeBasisPoints_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBasisPoints_ >= FEE_BASIS_POINTS_DENOMINATOR) {
            revert InvalidFee();
        }
        feeInBasisPoints = feeBasisPoints_;
    }
}
