// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract BootstrapPortal is Ownable, ReentrancyGuard {
    // ==================== CONSTANTS ====================
    uint256 public constant PRICE_DECIMALS = 1e6; // 6 decimals for price
    uint256 public constant PERCENT_DECIMALS = 10000; // 10000 = 100%

    // ==================== STATE VARIABLES ====================
    IERC20 public immutable usdtToken;
    IERC20 public immutable gameToken;

    // Pool state (updated in each transaction)
    uint256 public usdtReserve;
    uint256 public tokenReserve;
    uint256 public virtualBurnedTokens;

    // Fee configuration
    uint256 public swapFeePercent = 0; // Configurable swap fee (e.g., 300 = 3%)

    // ==================== CONSTRUCTOR ====================
    constructor(
        address _usdtAddress,
        address _fierceTokenAddress,
        address _initialOwner
    ) Ownable(_initialOwner) {
        usdtToken = IERC20(_usdtAddress);
        gameToken = IERC20(_fierceTokenAddress);
    }
    
    // ==================== CRITICAL FUNCTION: INITIALIZE POOL ====================
    /**
     * @notice Initializes the pool with liquidity
     * @dev Can only be called once
     */
    function initializePool(
        uint256 initialUsdt,
        uint256 initialTokens
    ) external onlyOwner {
        require(usdtReserve == 0 && tokenReserve == 0, "Pool already initialized");
        require(initialUsdt > 0 && initialTokens > 0, "Amounts must be > 0");

        // Transfer tokens to the contract
        require(
            usdtToken.transferFrom(msg.sender, address(this), initialUsdt),
            "USDT transfer failed"
        );
        require(
            gameToken.transferFrom(msg.sender, address(this), initialTokens),
            "Token transfer failed"
        );

        // Initialize reserves
        usdtReserve = initialUsdt;
        tokenReserve = initialTokens;
        virtualBurnedTokens = 0;
    }
    
    // ==================== PRICE ====================
    /**
     * @notice Calculates the current price based on tokens IN THE POOL
     */
    function getCurrentPrice() public view returns (uint256) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0) return 0;

        return (usdtReserve * PRICE_DECIMALS) / effectiveTokens;
    }

    /**
     * @notice Effective tokens = Tokens in pool - Virtual burned
     */
    function getEffectiveTokens() public view returns (uint256) {
        return tokenReserve - virtualBurnedTokens;
    }

    /**
     * @notice Syncs reserves with real balances (useful for audits)
     */
    function syncReserves() external {
        usdtReserve = usdtToken.balanceOf(address(this));
        tokenReserve = gameToken.balanceOf(address(this));
    }

    /**
     * @notice Sets the swap fee percentage
     * @param newPercent New fee percentage (e.g., 300 = 3%)
     */
    function setSwapFeePercent(uint256 newPercent) external onlyOwner {
        require(newPercent <= 1000, "Max fee is 10%");
        swapFeePercent = newPercent;
    }
    
    // ==================== PRODUCT PURCHASE ====================
    function processProductPurchase(
        address buyer,
        uint256 usdtAmount,
        uint256 burnPercent
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        // Validations...

        // 1. Transfer USDT
        require(
            usdtToken.transferFrom(buyer, address(this), usdtAmount),
            "USDT transfer failed"
        );

        // 2. Update reserves (USDT increases)
        usdtReserve += usdtAmount;

        // 3. Calculate and apply virtual burn
        uint256 priceBefore = getCurrentPrice();
        uint256 tokensBurnedVirtual;

        if (priceBefore > 0) {
            tokensBurnedVirtual = (usdtAmount * PRICE_DECIMALS * burnPercent) /
                                  (priceBefore * PERCENT_DECIMALS);
        } else {
            // Special case first transaction
            tokensBurnedVirtual = (usdtAmount * burnPercent) / PERCENT_DECIMALS;
        }

        virtualBurnedTokens += tokensBurnedVirtual;

        // 4. Get new price
        newPrice = getCurrentPrice();

        return newPrice;
    }
    
    // ==================== TOKEN SALE ====================
    function processTokenSell(
        address seller,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant returns (uint256 usdtToSend) {
        // Validations...

        // 1. Transfer tokens to the contract
        require(
            gameToken.transferFrom(seller, address(this), tokenAmount),
            "Token transfer failed"
        );

        // 2. Calculate USDT to send (AMM)
        uint256 effectiveTokens = getEffectiveTokens();
        usdtToSend = (usdtReserve * tokenAmount) / (effectiveTokens + tokenAmount);

        // 3. Apply swap fee (deducted from seller's payout, fee stays in contract)
        if (swapFeePercent > 0) {
            uint256 fee = (usdtToSend * swapFeePercent) / PERCENT_DECIMALS;
            usdtToSend -= fee;
        }

        // 4. Validate funds
        require(usdtToSend <= usdtReserve, "Insufficient USDT");

        // 5. Update reserves
        tokenReserve += tokenAmount;  // Increases tokens in pool
        usdtReserve -= usdtToSend;    // Decreases USDT in pool (fee stays in contract)

        // 6. Send USDT to seller
        require(
            usdtToken.transfer(seller, usdtToSend),
            "USDT transfer failed"
        );

        return usdtToSend;
    }
    
    // ==================== INFO FUNCTIONS ====================
    function getPoolInfo() external view returns (
        uint256 currentPrice,
        uint256 currentUsdtReserve,
        uint256 currentTokenReserve,
        uint256 currentVirtualBurned,
        uint256 effectiveTokens,
        uint256 realUsdtBalance,
        uint256 realTokenBalance
    ) {
        currentPrice = getCurrentPrice();
        currentUsdtReserve = usdtReserve;
        currentTokenReserve = tokenReserve;
        currentVirtualBurned = virtualBurnedTokens;
        effectiveTokens = getEffectiveTokens();

        // Real balances (for verification)
        realUsdtBalance = usdtToken.balanceOf(address(this));
        realTokenBalance = gameToken.balanceOf(address(this));
    }
}