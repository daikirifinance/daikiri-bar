// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.7.3;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/Ownable.sol";
import "./interfaces/ReentrancyGuard.sol";
import "./interfaces/IReferral.sol";

// Mixologist is the master of new tokens. He can make new tokens and he is a fair guy.

// Have fun reading it. Hopefully it's bug-free. God bless.
contract Mixologist is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up
        uint256 nextHarvestUntil; // When can the user harvest again
        //
        // We do some fancy math here. Basically, any point in time, the amount of $REWARD_TOKENs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accRewardTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRewardTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 stakingToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. REWARD_TOKENs to distribute per block.
        uint256 lastRewardBlock; // Last block number that REWARD_TOKENs distribution occurs.
        uint256 accRewardTokenPerShare; // Accumulated REWARD_TOKENs per share, times 1e18. See below.
        uint256 harvestInterval; // Harvest interval in seconds
    }

    // The REWARD_TOKEN TOKEN!
    IERC20 public rewardToken;
    // DAO address
    address public daoAddress;
    // REWARD_TOKEN tokens created per block.
    uint256 public rewardTokenPerBlock;
    // Max harvest interval: 14 days
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 86400; // 24 hrs

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when REWARD_TOKEN mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // REWARD_TOKEN referral contract address.
    IReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    mapping(IERC20 => bool) public poolExistence;

    /**
     * @notice Deploy Mixologist
     * @param _rewardToken The address of the reward token
     * @param _startBlock The number when $REWARD_TOKEN mining starts
     * @param _daoAddress DAO address
     * @param _rewardTokenPerBlock The number of $REWARD_TOKENs created every block
     */
    constructor(
        IERC20 _rewardToken,
        uint256 _startBlock,
        address _daoAddress,
        uint256 _rewardTokenPerBlock
    ) Ownable() {
        rewardToken = _rewardToken;
        startBlock = _startBlock;
        daoAddress = _daoAddress;
        rewardTokenPerBlock = _rewardTokenPerBlock;

        // Create Staking Pool
        poolInfo.push(
            PoolInfo({
                stakingToken: _rewardToken,
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                accRewardTokenPerShare: 0,
                harvestInterval: 7200 // 2h
            })
        );

        totalAllocPoint = 1000;
    }

    /* MODIFIERS */
    modifier nonDuplicated(IERC20 _stakingToken) {
        require(poolExistence[_stakingToken] == false, "nonDuplicated: duplicated");
        _;
    }

    /** METHODS */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _stakingToken,
        uint256 _harvestInterval
    ) external onlyOwner nonDuplicated(_stakingToken) {
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_stakingToken] = true;
        poolInfo.push(
            PoolInfo({
                stakingToken: _stakingToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accRewardTokenPerShare: 0,
                harvestInterval: _harvestInterval 
            })
        );
    }

    // Update the given pool's REWARD_TOKEN allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _harvestInterval
    ) external onlyOwner {
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "set: invalid harvest interval"
        );
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending REWARD_TOKENs on frontend.
    function pendingRewardToken(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardTokenPerShare = pool.accRewardTokenPerShare;
        uint256 lpSupply = pool.stakingToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 rewardTokenReward = multiplier
            .mul(rewardTokenPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
            accRewardTokenPerShare = accRewardTokenPerShare.add(
                rewardTokenReward.mul(1e18).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accRewardTokenPerShare).div(1e18).sub(
            user.rewardDebt
        );
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest REWARD_TOKENs
    function canHarvest(uint256 _pid, address _user)
        public
        view
        returns (bool)
    {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.stakingToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 rewardTokenReward = multiplier
        .mul(rewardTokenPerBlock)
        .mul(pool.allocPoint)
        .div(totalAllocPoint);
        // rewardToken.mint(daoAddress, rewardTokenReward.div(10));
        // rewardToken.mint(address(this), rewardTokenReward);
        pool.accRewardTokenPerShare = pool.accRewardTokenPerShare.add(
            rewardTokenReward.mul(1e18).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Mixologist for REWARD_TOKEN allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (
            _amount > 0 &&
            address(referral) != address(0) &&
            _referrer != address(0) &&
            _referrer != msg.sender
        ) {
            referral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingRewardToken(_pid);
        if (_amount > 0) {
            uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
            pool.stakingToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.stakingToken.balanceOf(address(this)).sub(balanceBefore);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardTokenPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Mixologist.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingRewardToken(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.stakingToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardTokenPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.stakingToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending REWARD_TOKENs
    function payOrLockupPendingRewardToken(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accRewardTokenPerShare).div(1e18).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                safeRewardTokenTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe rewardToken transfer function, just in case if rounding error causes pool to not have enough REWARD_TOKEN.
    function safeRewardTokenTransfer(address _to, uint256 _amount) internal {
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > rewardTokenBalance) {
            transferSuccess = rewardToken.transfer(_to, rewardTokenBalance);
        } else {
            transferSuccess = rewardToken.transfer(_to, _amount);
        }
        require(transferSuccess, "safeRewardTokenTransfer: Transfer failed");
    }

    // Update dao address by the previous dao.
    function setDaoAddress(address _daoAddress) external onlyOwner {
        daoAddress = _daoAddress;
        emit SetDaoAddress(msg.sender, _daoAddress);
    }

    function updateEmissionRate(uint256 _rewardTokenPerBlock) external onlyOwner {
        massUpdatePools();
        rewardTokenPerBlock = _rewardTokenPerBlock;
        emit UpdateEmissionRate(msg.sender, _rewardTokenPerBlock);
    }

    // Update the referral contract address by the owner
    function setReferralAddress(IReferral _referral) external onlyOwner {
        referral = _referral;
        emit SetReferralAddress(msg.sender, _referral);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        external
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(
                10000
            );

            if (referrer != address(0) && commissionAmount > 0) {
                // rewardToken.mint(referrer, commissionAmount); // TODO: change for transfer
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
        require(startBlock > block.number, "Farm already started");
        uint256 length = poolInfo.length;

        for(uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardBlock = _startBlock;
        }

        startBlock = _startBlock;
    }

    /* EVENTS */
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SetDaoAddress(address indexed user, address indexed newAddress);
    event SetReferralAddress(
        address indexed user,
        IReferral indexed newAddress
    );
    event UpdateEmissionRate(address indexed user, uint256 rewardTokenPerBlock);
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );    
}
