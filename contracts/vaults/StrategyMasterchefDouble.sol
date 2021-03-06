// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../interfaces/Ownable.sol";
import "../interfaces/ReentrancyGuard.sol";
import "../interfaces/Pausable.sol";
import "../interfaces/WETH.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";

import "./libs/ISushiStake.sol";
import "./libs/IStrategyDaiki.sol";
import "./libs/IUniPair.sol";
import "./libs/IUniRouter02.sol";

contract StrategyMasterchefDouble is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public vaultChefAddress =
        0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public masterchefAddress;
    uint256 public pid;
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public earnedAddress;

    address public uniRouterAddress;
    address public constant usdcAddress =
        0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant wethAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant daikiAddress =
        0xF315803Ba9dA293765ab163E7dB98E8d6Df6D361;
    address public constant rewardAddress =
        0xE768c11Ce3250f65B57c08e0AfEFda1Df81f8f5c;
    address public constant feeAddress =
        0xE768c11Ce3250f65B57c08e0AfEFda1Df81f8f5c;
    address public constant withdrawFeeAddress =
        0xD12Bc198269A14475BaF42Fa38967F0075E9DF1e;
    address public govAddress;

    uint256 public lastEarnBlock = block.number;
    uint256 public sharesTotal = 0;

    address public constant buyBackAddress =
        0x000000000000000000000000000000000000dEaD;
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

    address[] public earnedToWETHPath;
    address[] public earnedToUsdcPath;
    address[] public earnedToDaikiPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    address[] public wethToUsdcPath;
    address[] public wethToDaikiPath;
    address[] public wethToToken0Path;
    address[] public wethToToken1Path;

    constructor(
        address _masterchefAddress,
        address _uniRouterAddress,
        uint256 _pid,
        address _wantAddress,
        address _earnedAddress,
        address[] memory _earnedToWETHPath,
        address[] memory _earnedToUsdcPath,
        address[] memory _earnedToDaikiPath,
        address[] memory _wethToUsdcPath,
        address[] memory _wethToDaikiPath,
        address[] memory _earnedToToken0Path,
        address[] memory _earnedToToken1Path,
        address[] memory _wethToToken0Path,
        address[] memory _wethToToken1Path,
        address[] memory _token0ToEarnedPath,
        address[] memory _token1ToEarnedPath
    ) {
        govAddress = msg.sender;
        masterchefAddress = _masterchefAddress;
        uniRouterAddress = _uniRouterAddress;

        wantAddress = _wantAddress;
        token0Address = IUniPair(wantAddress).token0();
        token1Address = IUniPair(wantAddress).token1();

        pid = _pid;
        earnedAddress = _earnedAddress;

        earnedToWETHPath = _earnedToWETHPath;
        earnedToUsdcPath = _earnedToUsdcPath;
        earnedToDaikiPath = _earnedToDaikiPath;
        wethToUsdcPath = _wethToUsdcPath;
        wethToDaikiPath = _wethToDaikiPath;
        earnedToToken0Path = _earnedToToken0Path;
        earnedToToken1Path = _earnedToToken1Path;
        wethToToken0Path = _wethToToken0Path;
        wethToToken1Path = _wethToToken1Path;
        token0ToEarnedPath = _token0ToEarnedPath;
        token1ToEarnedPath = _token1ToEarnedPath;

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
        ISushiStake(masterchefAddress).deposit(pid, wantAmt, address(this));
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

        // Check if strategy has tokens from panic
        if (_wantAmt > wantAmt) {
            ISushiStake(masterchefAddress).withdraw(
                pid,
                _wantAmt.sub(wantAmt),
                address(this)
            );
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
            .mul(withdrawFeeFactorMax.sub(withdrawFeeFactor))
            .div(withdrawFeeFactorMax);
        if (withdrawFee > 0) {
            IERC20(wantAddress).safeTransfer(withdrawFeeAddress, withdrawFee);
        }

        _wantAmt = _wantAmt.sub(withdrawFee);

        IERC20(wantAddress).safeTransfer(vaultChefAddress, _wantAmt);

        return sharesRemoved;
    }

    function earn() external nonReentrant whenNotPaused onlyGov {
        // Harvest farm tokens
        ISushiStake(masterchefAddress).harvest(pid, address(this));

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        uint256 wethAmt = IERC20(wethAddress).balanceOf(address(this));

        if (earnedAmt > 0) {
            earnedAmt = distributeFees(earnedAmt, earnedAddress);
            earnedAmt = distributeRewards(earnedAmt, earnedAddress);
            earnedAmt = buyBack(earnedAmt, earnedAddress);

            if (earnedAddress != token0Address) {
                // Swap half earned to token0
                _safeSwap(earnedAmt.div(2), earnedToToken0Path, address(this));
            }

            if (earnedAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(earnedAmt.div(2), earnedToToken1Path, address(this));
            }
        }

        if (wethAmt > 0) {
            wethAmt = distributeFees(wethAmt, wethAddress);
            wethAmt = distributeRewards(wethAmt, wethAddress);
            wethAmt = buyBack(wethAmt, wethAddress);

            if (wethAddress != token0Address) {
                // Swap half earned to token0
                _safeSwap(wethAmt.div(2), wethToToken0Path, address(this));
            }

            if (wethAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(wethAmt.div(2), wethToToken1Path, address(this));
            }
        }

        if (earnedAmt > 0 || wethAmt > 0) {
            // Get want tokens, ie. add liquidity
            uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
            uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
            if (token0Amt > 0 && token1Amt > 0) {
                IUniRouter02(uniRouterAddress).addLiquidity(
                    token0Address,
                    token1Address,
                    token0Amt,
                    token1Amt,
                    0,
                    0,
                    address(this),
                    block.timestamp.add(600)
                );
            }

            lastEarnBlock = block.number;

            _farm();
        }
    }

    // To pay for earn function
    function distributeFees(uint256 _earnedAmt, address _earnedAddress)
        internal
        returns (uint256)
    {
        if (controllerFee > 0) {
            uint256 fee = _earnedAmt.mul(controllerFee).div(feeMax);

            if (_earnedAddress == wethAddress) {
                IERC20(wethAddress).safeTransfer(feeAddress, fee);
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

    function convertDustToEarned() external nonReentrant whenNotPaused {
        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Amt > 0 && token0Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            _safeSwap(token0Amt, token0ToEarnedPath, address(this));
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Amt > 0 && token1Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            _safeSwap(token1Amt, token1ToEarnedPath, address(this));
        }
    }

    function vaultSharesTotal() public view returns (uint256) {
        (uint256 amount, ) = ISushiStake(masterchefAddress).userInfo(
            pid,
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

    function _resetAllowances() internal {
        IERC20(wantAddress).safeApprove(masterchefAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            masterchefAddress,
            uint256(-1)
        );

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

        IERC20(token0Address).safeApprove(uniRouterAddress, uint256(0));
        IERC20(token0Address).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(token1Address).safeApprove(uniRouterAddress, uint256(0));
        IERC20(token1Address).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(usdcAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(usdcAddress).safeIncreaseAllowance(rewardAddress, uint256(-1));
    }

    function resetAllowances() external onlyGov {
        _resetAllowances();
    }

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

    // function safeTransferETH(address to, uint256 value) internal {
    //     (bool success, ) = to.call{value: value}(new bytes(0));
    //     require(
    //         success,
    //         "TransferHelper::safeTransferETH: ETH transfer failed"
    //     );
    // }
}
