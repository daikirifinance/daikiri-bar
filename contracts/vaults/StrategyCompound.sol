// SPDX-License-Identifier: MIT

pragma solidity 0.7.3;

import "../interfaces/Ownable.sol";
import "../interfaces/ReentrancyGuard.sol";
import "../interfaces/Pausable.sol";
import "../interfaces/WETH.sol";
import "../libraries/EnumerableSet.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";
import "./libs/IMasterchef.sol";
import "./libs/IStrategyDaiki.sol";
import "./libs/ISushiStake.sol";
import "./libs/IUniPair.sol";
import "./libs/IUniRouter02.sol";
import "./libs/ICToken.sol";
import "./libs/IComptroller.sol";

contract StrategyCompound is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public vaultChefAddress;
    address public comptrollerAddress;
    address public cTokenAddress;
    uint256 public pid;
    address public wantAddress;
    address public earnedAddress;

    address public uniRouterAddress;

    address public constant wethAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant usdcAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;

    address public constant rewardAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant feeAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant withdrawFeeAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant buyBackAddress =
        0x000000000000000000000000000000000000dEaD;

    address public govAddress;
    uint256 public lastEarnBlock = block.number;
    uint256 public sharesTotal = 0;

    uint256 public controllerFee = 50;
    uint256 public rewardRate = 100;
    uint256 public buyBackRate = 450;
    uint256 public constant feeMaxTotal = 1000;
    uint256 public constant feeMax = 10000; // 100 = 1%

    uint256 public withdrawFeeFactor = 10000; // 0% withdraw fee
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9900;

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToWantPath;
    address[] public earnedToWETHPath;
    address[] public earnedToUsdcPath;
    address[] public earnedToDaikiPath;
    address[] public wethToWantPath;
    address[] public wethToUsdcPath;
    address[] public wethToDaikiPath;

    constructor(
        address _vaultChefAddress,
        address _comptrollerAddress,
        address _cTokenAddress,
        address _uniRouterAddress,
        uint256 _pid,
        address _wantAddress,
        address _earnedAddress,
        address[] memory _earnedToWantPath,
        address[] memory _earnedToWETHPath,
        address[] memory _earnedToUsdcPath,
        address[] memory _earnedToDaikiPath,
        address[] memory _wethToWantPath,
        address[] memory _wethToUsdcPath,
        address[] memory _wethToDaikiPath
    ) {
        govAddress = msg.sender;
        vaultChefAddress = _vaultChefAddress;
        comptrollerAddress = _comptrollerAddress;
        cTokenAddress = _cTokenAddress;
        uniRouterAddress = _uniRouterAddress;
        pid = _pid;
        wantAddress = _wantAddress;
        earnedAddress = _earnedAddress;

        earnedToWantPath = _earnedToWantPath;
        earnedToWETHPath = _earnedToWETHPath;
        earnedToUsdcPath = _earnedToUsdcPath;
        earnedToDaikiPath = _earnedToDaikiPath;
        wethToWantPath = _wethToWantPath;
        wethToUsdcPath = _wethToUsdcPath;
        wethToDaikiPath = _wethToDaikiPath;

        transferOwnership(vaultChefAddress);

        _resetAllowances();
    }

    event SetSettings(
        uint256 _controllerFee,
        uint256 _rewardRate,
        uint256 _buyBackRate,
        uint256 _withdrawFeeFactor,
        uint256 _slippageFactor,
        address _uniRouterAddress
    );

    modifier onlyGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    function deposit(address _userAddress, uint256 _wantAmt)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        // Call must happen before transfer
        uint256 wantLockedBefore = wantLockedTotal();

        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        // Proper deposit amount for tokens with fees, or vaults with deposit fees
        uint256 sharesAdded = _farm();
        if (sharesTotal > 0) {
            sharesAdded = sharesAdded.mul(sharesTotal).div(wantLockedBefore);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        return sharesAdded;
    }

    function _farm() internal returns (uint256) {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (wantAmt == 0) return 0;

        uint256 sharesBefore = vaultSharesTotal();

        _supply(wantAmt);

        uint256 sharesAfter = vaultSharesTotal();

        return sharesAfter.sub(sharesBefore);
    }

    function withdraw(address _userAddress, uint256 _wantAmt)
        external
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        require(_wantAmt > 0, "_wantAmt is 0");
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));

        if (_wantAmt > wantAmt) {
            _removeSupply(_wantAmt.sub(wantAmt));
            wantAmt = IERC20(wantAddress).balanceOf(address(this));
        }

        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (_wantAmt > wantLockedTotal()) {
            _wantAmt = wantLockedTotal();
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(
            wantLockedTotal()
        );
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);

        // Withdraw fee
        uint256 withdrawFee = _wantAmt
            .mul(withdrawFeeFactorMax)
            .sub(withdrawFeeFactor)
            .div(withdrawFeeFactorMax);

        if (withdrawFee > 0) {
            IERC20(wantAddress).safeTransfer(withdrawFeeAddress, withdrawFee);
        }

        _wantAmt = _wantAmt.sub(withdrawFee);

        return sharesRemoved;
    }

    function earn() external nonReentrant whenNotPaused onlyGov {
        // Harvest farm tokens
        // QI = 0
        // AVAX = 1
        IComptroller(comptrollerAddress).claimReward(0, address(this));
        IComptroller(comptrollerAddress).claimReward(1, address(this));

        // Because we keep some tokens in this contract, we have to do this if earned is the same as want
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        uint256 avaxAmt = address(this).balance;

        if (earnedAmt > 0) {
            earnedAmt = distributeFees(earnedAmt, earnedAddress);
            earnedAmt = distributeRewards(earnedAmt, earnedAddress);
            earnedAmt = buyBack(earnedAmt, earnedAddress);

            if (earnedAddress != wantAddress) {
                _safeSwap(earnedAmt, earnedToWantPath, address(this));
            }
        }

        if (avaxAmt > 0) {
            IWETH(wethAddress).deposit{value: avaxAmt}();
            avaxAmt = distributeFees(avaxAmt, wethAddress);
            avaxAmt = distributeRewards(avaxAmt, wethAddress);
            avaxAmt = buyBack(avaxAmt, wethAddress);

            if (wethAddress != wantAddress) {
                _safeSwap(avaxAmt, wethToWantPath, address(this));
            }
        }

        lastEarnBlock = block.number;

        _farm();
    }

    // To pay for earn function
    function distributeFees(uint256 _earnedAmt, address _earnedAddress)
        internal
        returns (uint256)
    {
        if (controllerFee > 0) {
            uint256 fee = _earnedAmt.mul(controllerFee).div(feeMax);

            if (_earnedAddress == wethAddress) {
                IWETH(wethAddress).withdraw(fee);
                safeTransferETH(feeAddress, fee);
            } else {
                _safeSwapWETH(fee, earnedToWETHPath, feeAddress);
            }

            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    function distributeRewards(uint256 _earnedAmt, address _earnedAddress)
        internal
        returns (uint256)
    {
        if (rewardRate > 0) {
            uint256 fee = _earnedAmt.mul(rewardRate).div(feeMax);

            uint256 usdcBefore = IERC20(usdcAddress).balanceOf(address(this));

            _safeSwap(
                fee,
                _earnedAddress == wethAddress
                    ? wethToUsdcPath
                    : earnedToUsdcPath,
                address(this)
            );

            uint256 usdcAfter = IERC20(usdcAddress)
                .balanceOf(address(this))
                .sub(usdcBefore);

            IStrategyDaiki(rewardAddress).depositReward(usdcAfter);

            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    function buyBack(uint256 _earnedAmt, address _earnedAddress)
        internal
        returns (uint256)
    {
        if (buyBackRate > 0) {
            uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(feeMax);

            _safeSwap(
                buyBackAmt,
                _earnedAddress == wethAddress
                    ? wethToDaikiPath
                    : earnedToDaikiPath,
                buyBackAddress
            );

            _earnedAmt = _earnedAmt.sub(buyBackAmt);
        }

        return _earnedAmt;
    }

    function vaultSharesTotal() public view returns (uint256) {
        uint256 amount = ICToken(cTokenAddress).balanceOfUnderlying(
            address(this)
        );
        return amount;
    }

    function wantLockedTotal() public view returns (uint256) {
        return
            IERC20(wantAddress).balanceOf(address(this)).add(
                vaultSharesTotal()
            );
    }

    function _supply(uint256 _amount) internal {
        ICToken(cTokenAddress).mint(_amount);
    }

    function _removeSupply(uint256 _amount) internal {
        ICToken(cTokenAddress).redeemUnderlying(_amount);
    }

    function _resetAllowances() internal {
        IERC20(wantAddress).safeApprove(cTokenAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(cTokenAddress, uint256(-1));

        IERC20(earnedAddress).safeApprove(uniRouterAddress, uint256(0));
        IERC20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(wethAddress).safeApprove(uniRouterAddress, uint256(0));
        IERC20(wethAddress).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(usdcAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(usdcAddress).safeIncreaseAllowance(rewardAddress, uint256(-1));
    }

    function resetAllowances() external onlyGov {
        _resetAllowances();
    }

    // Emergency!!
    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
        _resetAllowances();
    }

    function setGov(address _govAddress) external onlyGov {
        govAddress = _govAddress;
    }

    function setSettings(
        uint256 _controllerFee,
        uint256 _rewardRate,
        uint256 _buyBackRate,
        uint256 _withdrawFeeFactor,
        uint256 _slippageFactor,
        address _uniRouterAddress
    ) external onlyGov {
        require(
            _controllerFee.add(_rewardRate).add(_buyBackRate) <= feeMaxTotal,
            "Max fee of 10%"
        );
        require(
            _withdrawFeeFactor >= withdrawFeeFactorLL,
            "_withdrawFeeFactor too low"
        );
        require(
            _withdrawFeeFactor <= withdrawFeeFactorMax,
            "_withdrawFeeFactor too high"
        );
        require(
            _slippageFactor <= slippageFactorUL,
            "_slippageFactor too high"
        );
        controllerFee = _controllerFee;
        rewardRate = _rewardRate;
        buyBackRate = _buyBackRate;
        withdrawFeeFactor = _withdrawFeeFactor;
        slippageFactor = _slippageFactor;
        uniRouterAddress = _uniRouterAddress;

        emit SetSettings(
            _controllerFee,
            _rewardRate,
            _buyBackRate,
            _withdrawFeeFactor,
            _slippageFactor,
            _uniRouterAddress
        );
    }

    function _safeSwap(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IUniRouter02(uniRouterAddress).getAmountsOut(
            _amountIn,
            _path
        );
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IUniRouter02(uniRouterAddress).swapExactTokensForTokens(
            _amountIn,
            amountOut.mul(slippageFactor).div(1000),
            _path,
            _to,
            block.timestamp.add(600)
        );
    }

    function _safeSwapWETH(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IUniRouter02(uniRouterAddress).getAmountsOut(
            _amountIn,
            _path
        );
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IUniRouter02(uniRouterAddress).swapExactTokensForETH(
            _amountIn,
            amountOut.mul(slippageFactor).div(1000),
            _path,
            _to,
            block.timestamp.add(600)
        );
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(
            success,
            "TransferHelper::safeTransferETH: ETH transfer failed"
        );
    }
}