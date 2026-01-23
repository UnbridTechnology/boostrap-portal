// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BootstrapPortal is Ownable, ReentrancyGuard {
    // ==================== CONSTANTS ====================
    uint256 public constant PRICE_DECIMALS = 1e6; // 6 decimals for price
    uint256 public constant PERCENT_DECIMALS = 10000; // 10000 = 100%

    // ==================== STATE VARIABLES ====================
    IERC20 public immutable usdtToken;
    IERC20 public immutable fierceToken;

    // Pool state
    uint256 public usdtReserve;
    uint256 public tokenReserve;
    uint256 public virtualBurnedTokens;

    // Fee configuration
    uint256 public swapFeePercent = 300; // 3% default

    // ==================== EVENTS ====================
    event PoolInitialized(uint256 usdtAmount, uint256 tokenAmount);
    event ProductPurchased(address indexed buyer, uint256 usdtAmount, uint256 burnPercent, uint256 tokensBurnedVirtual, uint256 priceBefore, uint256 priceAfter);
    event TokensBought(address indexed buyer, uint256 usdtAmount, uint256 tokensReceived, uint256 priceBefore, uint256 priceAfter);
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 usdtReceived, uint256 priceBefore, uint256 priceAfter);
    event CashbackSent(address indexed recipient, uint256 tokenAmount, uint256 priceBefore, uint256 priceAfter);
    event SwapFeeUpdated(uint256 newFeePercent);
    event ReservesSynced(uint256 usdtBalance, uint256 tokenBalance);

    // ==================== CONSTRUCTOR ====================
    constructor(
        address _usdtAddress,
        address _fierceTokenAddress,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_fierceTokenAddress != address(0), "Invalid token address");
        
        usdtToken = IERC20(_usdtAddress);
        fierceToken = IERC20(_fierceTokenAddress);
    }
    
    // ==================== CRITICAL FUNCTION: INITIALIZE POOL ====================
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
            fierceToken.transferFrom(msg.sender, address(this), initialTokens),
            "Token transfer failed"
        );

        // Initialize reserves
        usdtReserve = initialUsdt;
        tokenReserve = initialTokens;
        virtualBurnedTokens = 0;
        
        emit PoolInitialized(initialUsdt, initialTokens);
    }
    
    // ==================== PRICE FUNCTIONS ====================
    function getCurrentPrice() public view returns (uint256) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0) return 0;
        return (usdtReserve * PRICE_DECIMALS) / effectiveTokens;
    }

    function getEffectiveTokens() public view returns (uint256) {
        // Prevent underflow
        return tokenReserve > virtualBurnedTokens ? tokenReserve - virtualBurnedTokens : 0;
    }

    function syncReserves() external onlyOwner {
        usdtReserve = usdtToken.balanceOf(address(this));
        tokenReserve = fierceToken.balanceOf(address(this));
        
        emit ReservesSynced(usdtReserve, tokenReserve);
    }

    function setSwapFeePercent(uint256 newPercent) external onlyOwner {
        require(newPercent <= 1000, "Max fee is 10%");
        swapFeePercent = newPercent;
        emit SwapFeeUpdated(newPercent);
    }
    
    // ==================== PRODUCT PURCHASE ====================
    function processProductPurchase(
        address buyer,
        uint256 usdtAmount,
        uint256 burnPercent
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        require(buyer != address(0), "Invalid buyer");
        require(usdtAmount > 0, "Amount must be > 0");
        require(burnPercent <= 5000, "Burn percent cannot exceed 50%");
        
        uint256 priceBefore = getCurrentPrice();

        // 1. Transfer USDT from buyer
        require(
            usdtToken.transferFrom(buyer, address(this), usdtAmount),
            "USDT transfer failed"
        );

        // 2. Update reserves (USDT increases)
        usdtReserve += usdtAmount;

        // 3. Calculate and apply virtual burn
        uint256 tokensBurnedVirtual;
        if (priceBefore > 0) {
            // tokensBurned = (usdtAmount * burnPercent) / (priceBefore * 10000)
            tokensBurnedVirtual = (usdtAmount * PRICE_DECIMALS * burnPercent) / 
                                  (priceBefore * PERCENT_DECIMALS);
        } else {
            // First transaction: use initial price assumption
            // Assuming we want initial price of 0.001 USDT per token
            uint256 assumedInitialPrice = 1 * PRICE_DECIMALS / 1000; // 0.001 USDT
            tokensBurnedVirtual = (usdtAmount * PRICE_DECIMALS * burnPercent) / 
                                  (assumedInitialPrice * PERCENT_DECIMALS);
        }

        virtualBurnedTokens += tokensBurnedVirtual;

        // 4. Get new price
        newPrice = getCurrentPrice();

        emit ProductPurchased(buyer, usdtAmount, burnPercent, tokensBurnedVirtual, priceBefore, newPrice);
        
        return newPrice;
    }
    
    // ==================== TOKEN BUY (CORRECTED AMM FORMULA) ====================
    function processTokenBuy(
        address buyer,
        uint256 usdtAmount
    ) external onlyOwner nonReentrant returns (uint256 tokensToBuy, uint256 newPrice) {
        require(buyer != address(0), "Invalid buyer");
        require(usdtAmount > 0, "USDT amount must be > 0");
        
        uint256 effectiveTokens = getEffectiveTokens();
        require(effectiveTokens > 0, "No effective tokens in pool");
        
        uint256 priceBefore = getCurrentPrice();

        // 1. Transfer USDT from buyer
        require(
            usdtToken.transferFrom(buyer, address(this), usdtAmount),
            "USDT transfer failed"
        );

        // 2. Calculate tokens to send using correct AMM formula:
        // tokens_out = effectiveTokens - (effectiveTokens * usdtReserve) / (usdtReserve + usdtAmount)
        // This maintains constant product: (effectiveTokens - tokens_out) * (usdtReserve + usdtAmount) = effectiveTokens * usdtReserve
        
        // Apply fee (fee stays in contract)
        uint256 usdtAfterFee = usdtAmount;
        if (swapFeePercent > 0) {
            uint256 fee = (usdtAmount * swapFeePercent) / PERCENT_DECIMALS;
            // Fee remains in contract and increases usdtReserve
            usdtAfterFee = usdtAmount - fee;
        }

        // CORRECT AMM FORMULA for buying tokens:
        tokensToBuy = effectiveTokens - 
                     (effectiveTokens * usdtReserve) / 
                     (usdtReserve + usdtAfterFee);

        require(tokensToBuy > 0, "Insufficient output amount");
        require(tokensToBuy <= tokenReserve, "Insufficient tokens in pool");

        // 3. Update reserves
        usdtReserve += usdtAmount;      // All USDT stays in pool (including fee)
        tokenReserve -= tokensToBuy;    // Remove tokens from pool

        // 4. Send tokens to buyer
        require(
            fierceToken.transfer(buyer, tokensToBuy),
            "Token transfer failed"
        );

        // 5. Get new price
        newPrice = getCurrentPrice();

        emit TokensBought(buyer, usdtAmount, tokensToBuy, priceBefore, newPrice);
        
        return (tokensToBuy, newPrice);
    }

    // ==================== TOKEN SALE (CORRECTED AMM FORMULA) ====================
    function processTokenSell(
        address seller,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant returns (uint256 usdtToSend) {
        require(seller != address(0), "Invalid seller");
        require(tokenAmount > 0, "Token amount must be > 0");
        
        uint256 priceBefore = getCurrentPrice();
        uint256 effectiveTokens = getEffectiveTokens();

        // 1. Transfer tokens to contract
        require(
            fierceToken.transferFrom(seller, address(this), tokenAmount),
            "Token transfer failed"
        );

        // 2. Calculate USDT to send using correct AMM formula:
        // usdt_out = usdtReserve - (usdtReserve * effectiveTokens) / (effectiveTokens + tokenAmount)
        
        // CORRECT AMM FORMULA for selling tokens:
        usdtToSend = usdtReserve - 
                    (usdtReserve * effectiveTokens) / 
                    (effectiveTokens + tokenAmount);

        require(usdtToSend > 0, "Insufficient output amount");

        // Apply fee (deducted from seller's payout)
        uint256 fee = 0;
        if (swapFeePercent > 0) {
            fee = (usdtToSend * swapFeePercent) / PERCENT_DECIMALS;
            usdtToSend -= fee;
            // Fee stays in contract (already accounted in usdtReserve)
        }

        require(usdtToSend <= usdtReserve, "Insufficient USDT in pool");

        // 3. Update reserves
        tokenReserve += tokenAmount;    // Add tokens to pool
        usdtReserve -= usdtToSend;      // Remove USDT from pool (fee remains)

        // 4. Send USDT to seller
        require(
            usdtToken.transfer(seller, usdtToSend),
            "USDT transfer failed"
        );

        emit TokensSold(seller, tokenAmount, usdtToSend, priceBefore, getCurrentPrice());
        
        return usdtToSend;
    }
    
    // ==================== ENVISION CASHBACK ====================
    /**
     * @notice Sends tokens as cashback to users (e.g., prediction platform losers)
     * @dev This INCREASES the token price because it reduces effective supply
     * IMPORTANT: This is BETTER than minting new tokens because:
     * 1. No inflation
     * 2. Increases token value for holders
     * 3. Rewards come from existing supply
     */
    function envisionCashback(
        address recipient,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        require(recipient != address(0), "Invalid recipient");
        require(tokenAmount > 0, "Amount must be > 0");
        require(tokenAmount <= tokenReserve, "Insufficient tokens in pool");
        
        uint256 priceBefore = getCurrentPrice();

        // 1. Update reserves (remove tokens from pool)
        tokenReserve -= tokenAmount;
        // NOTE: virtualBurnedTokens remains the same
        
        // 2. Send tokens to recipient
        require(
            fierceToken.transfer(recipient, tokenAmount),
            "Token transfer failed"
        );

        // 3. Get new price (will be HIGHER due to fewer tokens)
        newPrice = getCurrentPrice();
        
        emit CashbackSent(recipient, tokenAmount, priceBefore, newPrice);
        
        return newPrice;
    }
    
    // ==================== INFO FUNCTIONS ====================
    function getPoolInfo() external view returns (
        uint256 currentPrice,
        uint256 currentUsdtReserve,
        uint256 currentTokenReserve,
        uint256 currentVirtualBurned,
        uint256 effectiveTokens,
        uint256 realUsdtBalance,
        uint256 realTokenBalance,
        uint256 kValue
    ) {
        currentPrice = getCurrentPrice();
        currentUsdtReserve = usdtReserve;
        currentTokenReserve = tokenReserve;
        currentVirtualBurned = virtualBurnedTokens;
        effectiveTokens = getEffectiveTokens();
        
        // Real balances (verification)
        realUsdtBalance = usdtToken.balanceOf(address(this));
        realTokenBalance = fierceToken.balanceOf(address(this));
        
        // Constant product k = usdtReserve * effectiveTokens
        kValue = usdtReserve * effectiveTokens;
    }
    
    // ==================== EMERGENCY FUNCTIONS ====================
    /**
     * @notice Adjust virtual burned tokens (for corrections if needed)
     */
    function adjustVirtualBurned(uint256 newVirtualBurned) external onlyOwner {
        require(newVirtualBurned <= tokenReserve, "Cannot burn more than total tokens");
        virtualBurnedTokens = newVirtualBurned;
    }
    
    /**
     * @notice Withdraw tokens accidentally sent to contract (excluding pool tokens)
     */
    function rescueTokens(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(tokenAddress != address(usdtToken) && tokenAddress != address(fierceToken),
                "Cannot withdraw pool tokens");
        
        IERC20(tokenAddress).transfer(msg.sender, amount);
    }
    
    /**
     * @notice Estimate tokens received for a USDT amount (view function)
     */
    function estimateTokensForUSDT(uint256 usdtAmount) external view returns (uint256 tokensOut) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0 || usdtReserve == 0) return 0;
        
        // Apply fee
        uint256 usdtAfterFee = usdtAmount;
        if (swapFeePercent > 0) {
            uint256 fee = (usdtAmount * swapFeePercent) / PERCENT_DECIMALS;
            usdtAfterFee = usdtAmount - fee;
        }
        
        tokensOut = effectiveTokens - 
                   (effectiveTokens * usdtReserve) / 
                   (usdtReserve + usdtAfterFee);
        
        return tokensOut;
    }
    
    /**
     * @notice Estimate USDT received for selling tokens (view function)
     */
    function estimateUSDTForTokens(uint256 tokenAmount) external view returns (uint256 usdtOut) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0) return 0;
        
        usdtOut = usdtReserve - 
                 (usdtReserve * effectiveTokens) / 
                 (effectiveTokens + tokenAmount);
        
        // Apply fee
        if (swapFeePercent > 0) {
            uint256 fee = (usdtOut * swapFeePercent) / PERCENT_DECIMALS;
            usdtOut -= fee;
        }
        
        return usdtOut;
    }
}