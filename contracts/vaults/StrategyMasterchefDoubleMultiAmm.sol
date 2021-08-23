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

contract StrategyMasterchefDoubleMultiAmm is
    Ownable,
    ReentrancyGuard,
    Pausable
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public vaultChefAddress =
        0x471C67b06B12B1c72273fAc71EA1AD25e42664ef;
    address public masterchefAddress =
        0x67dA5f2FfaDDfF067AB9d5F025F8810634d84287;
    uint256 public pid = 7;
    address public wantAddress = 0x468dc50884962D6F81733aC0c23c04611aC219F9;
    address public token0Address = 0xBEC775Cb42AbFa4288dE81F387a9b1A3c4Bc552A;
    address public token1Address = 0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public earnedAddress = 0xBEC775Cb42AbFa4288dE81F387a9b1A3c4Bc552A;

    address public uniRouterAddress =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address public daikiRouterAddress =
        0x15527b33BEf39F5dEB8aa0360aED18ad9982E5D8;
    address public constant usdcAddress =
        0x985458E523dB3d53125813eD68c274899e9DfAb4;
    address public constant buyBackTokenAddress =
        0x6983D1E6DEf3690C4d616b13597A09e6193EA013;
    address public constant wethAddress =
        0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    address public constant daikiAddress =
        0xF315803Ba9dA293765ab163E7dB98E8d6Df6D361;
    address public constant rewardAddress =
        0x277647C08B9272070a1D09B8F29D2C3BaC2541a9;
    address public constant feeAddress =
        0x4f67E60Bab1A2d42e815805A704d9caBf3935F90;
    address public constant withdrawFeeAddress =
        0xF1c293C1A0551802e0042EC7b6DF256cc9571aDE;
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

    uint256 public withdrawFeeFactor = 10000; // 0.5% withdraw fee
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9900;

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToWETHPath = [earnedAddress, wethAddress];
    address[] public earnedToUsdcPath = [
        earnedAddress,
        wethAddress,
        usdcAddress
    ];
    address[] public earnedToToken0Path = [earnedAddress, token0Address];
    address[] public earnedToToken1Path = [earnedAddress, token1Address];
    address[] public token0ToEarnedPath = [token0Address, earnedAddress];
    address[] public token1ToEarnedPath = [token1Address, earnedAddress];

    address[] public wethToUsdcPath = [wethAddress, usdcAddress];
    address[] public wethToToken0Path = [wethAddress, token0Address];
    address[] public wethToToken1Path = [wethAddress, token1Address];

    address[] public wethToBuyBackTokenPath = [
        wethAddress,
        buyBackTokenAddress
    ];
    address[] public earnedToBuyBackTokenPath = [
        earnedAddress,
        wethAddress,
        buyBackTokenAddress
    ];
    address[] public buyBackTokenToDaikiPath = [
        buyBackTokenAddress,
        wethAddress, 
        daikiAddress
    ];

    constructor(address _wantAddress) {
        govAddress = msg.sender;

        wantAddress = _wantAddress;
        // token0Address = IUniPair(wantAddress).token0();
        // token1Address = IUniPair(wantAddress).token1();

        transferOwnership(vaultChefAddress);

        _resetAllowances();
    }

    event SetSettings(
        uint256 _controllerFee,
        uint256 _rewardRate,
        uint256 _buyBackRate,
        uint256 _withdrawFeeFactor,
        uint256 _slippageFactor,
        address _uniRouterAddress,
        address _daikiRouterAddress
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
                _safeSwap(
                    earnedAmt.div(2),
                    earnedToToken0Path,
                    address(this),
                    uniRouterAddress
                );
            }

            if (earnedAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(
                    earnedAmt.div(2),
                    earnedToToken1Path,
                    address(this),
                    uniRouterAddress
                );
            }
        }

        if (wethAmt > 0) {
            wethAmt = distributeFees(wethAmt, wethAddress);
            wethAmt = distributeRewards(wethAmt, wethAddress);
            wethAmt = buyBack(wethAmt, wethAddress);

            if (wethAddress != token0Address) {
                // Swap half earned to token0
                _safeSwap(
                    wethAmt.div(2),
                    wethToToken0Path,
                    address(this),
                    uniRouterAddress
                );
            }

            if (wethAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(
                    wethAmt.div(2),
                    wethToToken1Path,
                    address(this),
                    uniRouterAddress
                );
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
                address(this),
                uniRouterAddress
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

            // Convert to buybackTokenAddress
            _safeSwap(
                buyBackAmt,
                _earnedAddress == wethAddress
                    ? wethToBuyBackTokenPath
                    : earnedToBuyBackTokenPath,
                address(this),
                uniRouterAddress
            );

            uint256 buyBackTokenAmt = IERC20(buyBackTokenAddress).balanceOf(
                address(this)
            );

            // Buyback tokens in DaikiriSwap
            _safeSwap(
                buyBackTokenAmt,
                buyBackTokenToDaikiPath,
                buyBackAddress,
                daikiRouterAddress
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
            _safeSwap(
                token0Amt,
                token0ToEarnedPath,
                address(this),
                uniRouterAddress
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Amt > 0 && token1Address != earnedAddress) {
            // Swap all dust tokens to earned tokens
            _safeSwap(
                token1Amt,
                token1ToEarnedPath,
                address(this),
                uniRouterAddress
            );
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

        IERC20(buyBackTokenAddress).safeApprove(daikiRouterAddress, uint256(0));
        IERC20(buyBackTokenAddress).safeIncreaseAllowance(
            daikiRouterAddress,
            uint256(-1)
        );
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
        address _uniRouterAddress,
        address _daikiRouterAddress
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
        daikiRouterAddress = _daikiRouterAddress;

        emit SetSettings(
            _controllerFee,
            _rewardRate,
            _buyBackRate,
            _withdrawFeeFactor,
            _slippageFactor,
            _uniRouterAddress,
            daikiRouterAddress
        );
    }

    function _safeSwap(
        uint256 _amountIn,
        address[] memory _path,
        address _to,
        address _routerAddress
    ) internal {
        uint256[] memory amounts = IUniRouter02(_routerAddress).getAmountsOut(
            _amountIn,
            _path
        );
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IUniRouter02(_routerAddress).swapExactTokensForTokens(
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
