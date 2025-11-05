// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  KipuBankV3 — Multi-token vault -> all deposits swapped to USDC via Uniswap V2 and accounted in USD (6 decimals)
/// @notice Accepts ETH, USDC, or any ERC20 that has a direct Uniswap V2 pair with USDC. Non-USDC tokens are swapped to USDC.
/// @dev Uses OpenZeppelin AccessControl, ReentrancyGuard and SafeERC20. Chainlink feeds used to value tokens in USD (6 dec).
// === OpenZeppelin ===
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// ===== Chainlink Aggregator Interface (copiada localmente) =====
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    // supporting fee-on-transfer tokens
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// Errors
    error BankCapExceededUSD(uint256 attemptedUsd6, uint256 availableUsd6);
    error WithdrawExceedsPerTxLimitUSD(uint256 requestedUsd6, uint256 limitUsd6);
    error InsufficientBalanceToken(address token, address user, uint256 available, uint256 requested);
    error NativeTransferFailed(address to, uint256 amount);
    error TokenTransferFailed(address token, address from, address to, uint256 amount);
    error PriceFeedNotSet(address token);
    error ZeroAmount();
    error InvalidAddress();
    error UnsupportedPair(address token);

    /// Config
    uint256 public immutable bankCapUsd6;
    uint256 public immutable maxWithdrawPerTxUsd6;

    /// Accounting
    uint256 public totalDepositedUsd6;
    uint256 public depositCount;
    uint256 public withdrawCount;

    /// Balances: token => user => amount (unit = token decimals; for USDC typical 6)
    mapping(address => mapping(address => uint256)) public balances;

    /// Chainlink price feeds mapping: token => feed (token == address(0) => ETH feed)
    mapping(address => AggregatorV3Interface) public priceFeed;

    /// Uniswap router and USDC address
    IUniswapV2Router02 public immutable router;
    address public immutable USDC;

    /// Events
    event DepositToken(address indexed tokenIn, address indexed user, uint256 amountIn, uint256 usdcReceived, uint256 balanceAfter);
    event WithdrawToken(address indexed token, address indexed user, uint256 amount, uint256 balanceAfter);
    event PriceFeedSet(address indexed token, address indexed feed);
    event AdminGranted(address indexed grantedBy, address indexed newAdmin);

    /// Constructor
    /// @param _bankCapUsd6 global cap in USD (6 decimals)
    /// @param _maxWithdrawPerTxUsd6 per-tx withdraw limit in USD6
    /// @param _router UniswapV2 router address
    /// @param _usdc USDC token address
    constructor(
        uint256 _bankCapUsd6,
        uint256 _maxWithdrawPerTxUsd6,
        address _router, //address router
        address _usdc
    ) {
        if (_bankCapUsd6 == 0) revert ZeroAmount();
        if (_router == address(0) || _usdc == address(0)) revert InvalidAddress();

        bankCapUsd6 = _bankCapUsd6;
        maxWithdrawPerTxUsd6 = _maxWithdrawPerTxUsd6;

        router = IUniswapV2Router02(_router);
        USDC = _usdc;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    modifier nonZero(uint256 value) {
        if (value == 0) revert ZeroAmount();
        _;
    }

    modifier feedExists(address token) {
        if (address(priceFeed[token]) == address(0)) revert PriceFeedNotSet(token);
        _;
    }

    /// Admin functions
    function setPriceFeed(address token, address feed) external onlyRole(ADMIN_ROLE) {
        if (feed == address(0)) revert InvalidAddress();
        priceFeed[token] = AggregatorV3Interface(feed);
        emit PriceFeedSet(token, feed);
    }

    function grantAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert InvalidAddress();
        grantRole(ADMIN_ROLE, newAdmin);
        emit AdminGranted(msg.sender, newAdmin);
    }

    /// -------------- DEPOSIT ----------------
    /// deposit: all tokens except USDC are swapped to USDC and the USDC received is credited to user
    /// token == address(0) => ETH (native)
    function deposit(address token, uint256 amount) external payable nonZero(amount) nonReentrant {
        // USDC direct deposit case
        if (token == USDC) {
            // Transfer USDC from user
            IERC20(usdc()).safeTransferFrom(msg.sender, address(this), amount);

            // Ensure feed exists for USDC to compute USD6
            AggregatorV3Interface feed = priceFeed[USDC];
            if (address(feed) == address(0)) revert PriceFeedNotSet(USDC);

            uint256 amountUsd6 = _toUsd6View(USDC, amount, feed);
            uint256 newTotalUsd6 = totalDepositedUsd6 + amountUsd6;
            if (newTotalUsd6 > bankCapUsd6) revert BankCapExceededUSD(newTotalUsd6, bankCapUsd6 - totalDepositedUsd6);

            // Effects
            balances[USDC][msg.sender] += amount;
            totalDepositedUsd6 = newTotalUsd6;
            unchecked { depositCount++; }

            emit DepositToken(USDC, msg.sender, amount, amount, balances[USDC][msg.sender]);
            return;
        }

        // Non-USDC -> must swap to USDC via Uniswap V2
        if (token == address(0)) {
            // ETH path: WETH -> USDC
            uint256 ethAmount = msg.value;
            if (ethAmount != amount) revert TokenTransferFailed(token, msg.sender, address(this), amount);

            // Check that WETH-USDC pair exists
            address weth = router.WETH();
            address factory = router.factory();
            if (IUniswapV2Factory(factory).getPair(weth, USDC) == address(0)) revert UnsupportedPair(weth);

            // estimate amounts out
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = USDC;
            uint256[] memory amountsOut = router.getAmountsOut(ethAmount, path);
            uint256 expectedUsdc = amountsOut[amountsOut.length - 1];

            // check price feed for USDC exists
            AggregatorV3Interface feedUsdc = priceFeed[USDC];
            if (address(feedUsdc) == address(0)) revert PriceFeedNotSet(USDC);

            uint256 expectedUsd6 = _toUsd6View(USDC, expectedUsdc, feedUsdc);
            uint256 newTotalUsd6 = totalDepositedUsd6 + expectedUsd6;
            if (newTotalUsd6 > bankCapUsd6) revert BankCapExceededUSD(newTotalUsd6, bankCapUsd6 - totalDepositedUsd6);

            // perform swap: swapExactETHForTokensSupportingFeeOnTransferTokens
            uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
                0, // accept any (we already estimated and checked cap). For production use consider slippage param.
                path,
                address(this),
                block.timestamp + 300
            );
            uint256 afterBal = IERC20(USDC).balanceOf(address(this));
            uint256 actualReceived = afterBal - beforeBal;

            // compute actual received USD6 and final checks (should be <= expectedUsd6)
            uint256 actualUsd6 = _toUsd6View(USDC, actualReceived, feedUsdc);

            // Effects: credit user with USDC received
            balances[USDC][msg.sender] += actualReceived;
            totalDepositedUsd6 += actualUsd6;
            unchecked { depositCount++; }

            emit DepositToken(address(0), msg.sender, ethAmount, actualReceived, balances[USDC][msg.sender]);
            return;
        } else {
            // ERC20 token -> must be transferred from user then swapped
            IERC20 tokenERC = IERC20(token);
            tokenERC.safeTransferFrom(msg.sender, address(this), amount);

            // check that token-USDC pair exists
            address factory = router.factory();
            if (IUniswapV2Factory(factory).getPair(token, USDC) == address(0)) revert UnsupportedPair(token);

            // approve router
            // safe pattern: reset to 0 then set
           tokenERC.safeApprove(address(router), 0);
           tokenERC.safeApprove(address(router), amount);

            // estimate amounts out
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = USDC;
            uint256[] memory amountsOut = router.getAmountsOut(amount, path);
            uint256 expectedUsdc = amountsOut[amountsOut.length - 1];

            // check USDC feed exists
            AggregatorV3Interface feedUsdc = priceFeed[USDC];
            if (address(feedUsdc) == address(0)) revert PriceFeedNotSet(USDC);

            uint256 expectedUsd6 = _toUsd6View(USDC, expectedUsdc, feedUsdc);
            uint256 newTotalUsd6 = totalDepositedUsd6 + expectedUsd6;
            if (newTotalUsd6 > bankCapUsd6) {
                // revert and return token to user
                // Revert will unwind pre-transfers, but we've already transferFrom
                // So we should revert before performing transferFrom? We already transferred.
                // Simpler: if cap would be exceeded, refund token immediately and revert.
                tokenERC.safeTransfer(msg.sender, amount);
                revert BankCapExceededUSD(newTotalUsd6, bankCapUsd6 - totalDepositedUsd6);
            }

            // perform swap
            uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount,
                0, // accept any; production should use configurable slippage
                path,
                address(this),
                block.timestamp + 300
            );
            uint256 afterBal = IERC20(USDC).balanceOf(address(this));
            uint256 actualReceived = afterBal - beforeBal;

            // compute actual USD6 value
            uint256 actualUsd6 = _toUsd6View(USDC, actualReceived, feedUsdc);

            // Effects
            balances[USDC][msg.sender] += actualReceived;
            totalDepositedUsd6 += actualUsd6;
            unchecked { depositCount++; }

            emit DepositToken(token, msg.sender, amount, actualReceived, balances[USDC][msg.sender]);
            return;
        }
    }

    /// -------------- WITHDRAW ----------------
    /// Allows withdrawal of tokens currently stored. In this design most deposits result in USDC balances,
    /// so withdrawals will commonly be of USDC. Works similarly to V2.
    function withdraw(address token, uint256 amount) external nonZero(amount) nonReentrant {
        uint256 bal = balances[token][msg.sender];
        if (amount > bal) revert InsufficientBalanceToken(token, msg.sender, bal, amount);

        AggregatorV3Interface feed = priceFeed[token];
        if (address(feed) == address(0)) revert PriceFeedNotSet(token);

        uint256 amountUsd6 = _toUsd6(token, amount, feed);
        if (amountUsd6 > maxWithdrawPerTxUsd6) revert WithdrawExceedsPerTxLimitUSD(amountUsd6, maxWithdrawPerTxUsd6);

        // Effects
        balances[token][msg.sender] = bal - amount;
        if (totalDepositedUsd6 >= amountUsd6) totalDepositedUsd6 -= amountUsd6;
        else totalDepositedUsd6 = 0;
        unchecked { withdrawCount++; }

        // Interactions
        if (token == address(0)) {
            _safeTransferETH(msg.sender, amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit WithdrawToken(token, msg.sender, amount, balances[token][msg.sender]);
    }

    /// Balance getter
    function balanceOf(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    function totalDepositedUsd() external view returns (uint256) {
        return totalDepositedUsd6;
    }

    /// Chainlink-based conversion helpers (same logic as V2)
    function tokenAmountToUsd6(address token, uint256 amount) external view feedExists(token) returns (uint256) {
        return _toUsd6View(token, amount, priceFeed[token]);
    }

    function _toUsd6(address token, uint256 amount, AggregatorV3Interface feed) private view returns (uint256 usd6) {
        (, int256 answer, , , ) = feed.latestRoundData();
        if (answer <= 0) revert PriceFeedNotSet(token);
        uint256 price8 = uint256(answer); // 8 decimals
        uint8 tokenDecimals = _getDecimals(token);
        uint256 numerator = amount * price8;
        uint256 denom = 10 ** (uint256(tokenDecimals) + 2);
        usd6 = numerator / denom;
    }

    function _toUsd6View(address token, uint256 amount, AggregatorV3Interface feed) private view returns (uint256 usd6) {
        (, int256 answer, , , ) = feed.latestRoundData();
        if (answer <= 0) revert PriceFeedNotSet(token);
        uint256 price8 = uint256(answer);
        uint8 tokenDecimals = _getDecimals(token);
        uint256 numerator = amount * price8;
        uint256 denom = 10 ** (uint256(tokenDecimals) + 2);
        usd6 = numerator / denom;
    }

    function _safeTransferETH(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    function _getDecimals(address token) private view returns (uint8) {
        if (token == address(0)) return 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    /// receive/fallback handle ETH sent directly -> treat as deposit (converted to USDC)
    receive() external payable {
    _handleETHDeposit(msg.value);
}


function _handleETHDeposit(uint256 ethAmount) private nonReentrant {
    if (ethAmount == 0) revert ZeroAmount();

    // Check that WETH-USDC pair exists
    address weth = router.WETH();
    address factory = router.factory();
    if (IUniswapV2Factory(factory).getPair(weth, USDC) == address(0)) revert UnsupportedPair(weth);

    // Estimate USDC output
    address[] memory path = new address[](2);
    path[0] = address(0); // ETH (WETH)
    path[1] = USDC;
    uint256[] memory amountsOut = router.getAmountsOut(ethAmount, path);
    uint256 expectedUsdc = amountsOut[amountsOut.length - 1];

    // Check USDC feed exists
    AggregatorV3Interface feedUsdc = priceFeed[USDC];
    if (address(feedUsdc) == address(0)) revert PriceFeedNotSet(USDC);

    // Check bank cap
    uint256 expectedUsd6 = _toUsd6View(USDC, expectedUsdc, feedUsdc);
    uint256 newTotalUsd6 = totalDepositedUsd6 + expectedUsd6;
    if (newTotalUsd6 > bankCapUsd6) revert BankCapExceededUSD(newTotalUsd6, bankCapUsd6 - totalDepositedUsd6);

    // Perform swap
    uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
    router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
        0, // accept any (consider slippage in production)
        path,
        address(this),
        block.timestamp + 300
    );
    uint256 afterBal = IERC20(USDC).balanceOf(address(this));
    uint256 actualReceived = afterBal - beforeBal;

    // Update accounting
    balances[USDC][msg.sender] += actualReceived;
    totalDepositedUsd6 += _toUsd6View(USDC, actualReceived, feedUsdc);
    unchecked { depositCount++; }

    emit DepositToken(address(0), msg.sender, ethAmount, actualReceived, balances[USDC][msg.sender]);
}

    fallback() external payable {
        if (msg.value > 0) {
            _handleETHDeposit(msg.value); // Directly call the internal function
        }
    }
    /// helper to return usdc address (named function due to readability in code)
    function usdc() public view returns (address) {
        return USDC;
    }
}
