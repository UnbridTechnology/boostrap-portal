// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BootstrapPortal is Ownable, ReentrancyGuard {
    // ==================== CONSTANTS ====================
    uint256 public constant PERCENT_DECIMALS = 10000; // 10000 = 100%
    
    // ==================== CONFIGURABLE VARIABLES ====================
    uint256 public usdtDecimals = 6;      // USDT decimals (default 6)
    uint256 public tokenDecimals = 18;    // Token decimals (default 18)
    uint256 public priceDecimals = 6;     // Output price decimals (default 6)
    uint256 public precisionMultiplier = 1e12; // For high precision calculations
    
    // ==================== STATE VARIABLES ====================
    IERC20 public immutable usdtToken;
    IERC20 public immutable fierceToken;
    address public immutable treasuryAddress;

    // Pool state
    uint256 public usdtReserve;
    uint256 public tokenReserve;
    uint256 public virtualBurnedTokens;

    // Fee configuration
    uint256 public swapFeePercent = 100; // 1% default

    // ==================== EVENTS ====================
    event PoolInitialized(uint256 usdtAmount, uint256 tokenAmount);
    event LiquidityAdded(address indexed provider, uint256 usdtAmount, uint256 tokenAmount, uint256 newPrice);
    event ServicePurchased(address indexed buyer, address indexed userAddress, uint256 usdtAmount, uint256 burnPercent, uint256 tokensBurnedVirtual, uint256 priceBefore, uint256 priceAfter);
    event TokensBought(address indexed buyer, uint256 usdtAmount, uint256 tokensReceived, uint256 priceBefore, uint256 priceAfter);
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 usdtReceived, uint256 priceBefore, uint256 priceAfter);
    event CashbackSent(address indexed recipient, uint256 tokenAmount, uint256 priceBefore, uint256 priceAfter);
    event SwapFeeUpdated(uint256 newFeePercent);
    event ReservesSynced(uint256 usdtBalance, uint256 tokenBalance);
    event DecimalsConfigUpdated(uint256 usdtDecimals, uint256 tokenDecimals, uint256 priceDecimals);

    // ==================== CONSTRUCTOR ====================
    constructor(
        address _usdtAddress,
        address _fierceTokenAddress,
        address _initialOwner,
        address _treasuryAddress
    ) Ownable(_initialOwner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_fierceTokenAddress != address(0), "Invalid token address");
        require(_treasuryAddress != address(0), "Invalid treasury address");
        
        usdtToken = IERC20(_usdtAddress);
        fierceToken = IERC20(_fierceTokenAddress);
        treasuryAddress = _treasuryAddress;
    }
    
    // ==================== CONFIGURATION FUNCTIONS ====================
    /**
     * @notice Update decimals configuration (in case of different tokens)
     * @dev Can be called by owner to adjust precision without redeploying
     */
    function updateDecimalsConfig(
        uint256 _usdtDecimals,
        uint256 _tokenDecimals,
        uint256 _priceDecimals
    ) external onlyOwner {
        require(_usdtDecimals > 0 && _usdtDecimals <= 18, "Invalid USDT decimals");
        require(_tokenDecimals > 0 && _tokenDecimals <= 18, "Invalid token decimals");
        require(_priceDecimals > 0 && _priceDecimals <= 18, "Invalid price decimals");
        
        usdtDecimals = _usdtDecimals;
        tokenDecimals = _tokenDecimals;
        priceDecimals = _priceDecimals;
        
        emit DecimalsConfigUpdated(_usdtDecimals, _tokenDecimals, _priceDecimals);
    }
    
    /**
     * @notice Update precision multiplier for more accurate calculations
     */
    function updatePrecisionMultiplier(uint256 newMultiplier) external onlyOwner {
        require(newMultiplier >= 1e6 && newMultiplier <= 1e18, "Multiplier out of range");
        precisionMultiplier = newMultiplier;
    }
    
    // ==================== PRICE FUNCTIONS (CORREGIDAS) ====================
function getCurrentPrice() public view returns (uint256) {
    uint256 effectiveTokens = getEffectiveTokens();
    if (effectiveTokens == 0) return 0;
    
    // Convertir USDT a la misma base decimal que los tokens (18)
    uint256 usdtInTokenDecimals = usdtReserve * (10 ** (tokenDecimals - usdtDecimals));
    
    // Calcular precio: (USDT_en_18decimals * 10^priceDecimals) / tokens_en_18decimals
    uint256 price = (usdtInTokenDecimals * (10 ** priceDecimals)) / effectiveTokens;
    
    return price; // Retorna 3397 para 0.003397 USDT
}
    
    /**
     * @notice Get price in human readable format (as uint with priceDecimals)
     */
    function getPriceHuman() external view returns (uint256) {
        return getCurrentPrice();
    }
    
    /**
     * @notice Get price as string for display (e.g., "0.0034")
     */
    function getPriceAsString() external view returns (string memory) {
        uint256 price = getCurrentPrice();
        uint256 integerPart = price / (10 ** priceDecimals);
        uint256 decimalPart = price % (10 ** priceDecimals);
        
        // Padding decimal part with leading zeros
        string memory decimalStr = Strings.toString(decimalPart);
        while (bytes(decimalStr).length < priceDecimals) {
            decimalStr = string(abi.encodePacked("0", decimalStr));
        }
        
        return string(abi.encodePacked(
            Strings.toString(integerPart),
            ".",
            decimalStr
        ));
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
    
    // ==================== INITIALIZE POOL ====================
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
    
    // ==================== ADD LIQUIDITY ====================
    function addLiquidity(
        uint256 usdtAmount,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        require(usdtReserve > 0 && tokenReserve > 0, "Pool not initialized");
        require(usdtAmount > 0 && tokenAmount > 0, "Amounts must be > 0");

        // Transfer tokens to the contract
        require(
            usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
            "USDT transfer failed"
        );
        require(
            fierceToken.transferFrom(msg.sender, address(this), tokenAmount),
            "Token transfer failed"
        );

        // Update reserves
        usdtReserve += usdtAmount;
        tokenReserve += tokenAmount;
        
        newPrice = getCurrentPrice();
        
        emit LiquidityAdded(msg.sender, usdtAmount, tokenAmount, newPrice);
        
        return newPrice;
    }
    
    // ==================== SERVICE PURCHASE ====================
    function processServicePurchase(
        address buyer,
        address userAddress,
        uint256 usdtAmount,
        uint256 burnPercent
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
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

        // 3. Calculate and apply virtual burn (CORREGIDO con manejo de decimales)
        uint256 tokensBurnedVirtual;
        if (priceBefore > 0) {
            // Ajuste por decimales: escalar para mantener precisión
            uint256 scaledAmount = usdtAmount * precisionMultiplier;
            tokensBurnedVirtual = (scaledAmount * PRICE_DECIMALS_SAFE() * burnPercent) / 
                                  (priceBefore * PERCENT_DECIMALS * precisionMultiplier);
        } else {
            // First transaction: use initial price assumption
            uint256 assumedInitialPrice = 1 * (10 ** priceDecimals) / 1000; // 0.001 USDT
            uint256 scaledAmount = usdtAmount * precisionMultiplier;
            tokensBurnedVirtual = (scaledAmount * PRICE_DECIMALS_SAFE() * burnPercent) / 
                                  (assumedInitialPrice * PERCENT_DECIMALS * precisionMultiplier);
        }

        virtualBurnedTokens += tokensBurnedVirtual;

        // 4. Get new price
        newPrice = getCurrentPrice();

        emit ServicePurchased(buyer, userAddress, usdtAmount, burnPercent, tokensBurnedVirtual, priceBefore, newPrice);
        
        return newPrice;
    }
    
    // ==================== TOKEN BUY (CORREGIDO) ====================
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

        // 2. Apply fee
        uint256 usdtAfterFee = usdtAmount;
        if (swapFeePercent > 0) {
            uint256 fee = (usdtAmount * swapFeePercent) / PERCENT_DECIMALS;
            usdtAfterFee = usdtAmount - fee;
        }

        // 3. CORRECT AMM FORMULA con manejo de precisión
        // Usando multiplicador de precisión para evitar overflow
        uint256 numerator = effectiveTokens * usdtReserve * precisionMultiplier;
        uint256 denominator = (usdtReserve + usdtAfterFee) * precisionMultiplier;
        tokensToBuy = effectiveTokens - (numerator / denominator);

        require(tokensToBuy > 0, "Insufficient output amount");
        require(tokensToBuy <= tokenReserve, "Insufficient tokens in pool");

        // 4. Update reserves
        usdtReserve += usdtAmount;
        tokenReserve -= tokensToBuy;

        // 5. Send tokens to buyer
        require(
            fierceToken.transfer(buyer, tokensToBuy),
            "Token transfer failed"
        );

        // 6. Get new price
        newPrice = getCurrentPrice();

        emit TokensBought(buyer, usdtAmount, tokensToBuy, priceBefore, newPrice);
        
        return (tokensToBuy, newPrice);
    }

    // ==================== TOKEN SALE (CORREGIDO) ====================
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

        // 2. Calculate USDT to send usando fórmula corregida
        uint256 numerator = usdtReserve * effectiveTokens * precisionMultiplier;
        uint256 denominator = (effectiveTokens + tokenAmount) * precisionMultiplier;
        usdtToSend = usdtReserve - (numerator / denominator);

        require(usdtToSend > 0, "Insufficient output amount");

        // 3. Apply fee
        uint256 fee = 0;
        if (swapFeePercent > 0) {
            fee = (usdtToSend * swapFeePercent) / PERCENT_DECIMALS;
            usdtToSend -= fee;
        }

        require(usdtToSend <= usdtReserve, "Insufficient USDT in pool");

        // 4. Update reserves
        tokenReserve += tokenAmount;
        usdtReserve -= usdtToSend;

        // 5. Send USDT to seller
        require(
            usdtToken.transfer(seller, usdtToSend),
            "USDT transfer failed"
        );

        emit TokensSold(seller, tokenAmount, usdtToSend, priceBefore, getCurrentPrice());
        
        return usdtToSend;
    }
    
    // ==================== ENVISION CASHBACK ====================
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
    
    // ==================== INFO FUNCTIONS MEJORADAS ====================
    function getPoolInfo() external view returns (
        uint256 currentPrice,
        uint256 currentUsdtReserve,
        uint256 currentTokenReserve,
        uint256 currentVirtualBurned,
        uint256 effectiveTokens,
        uint256 realUsdtBalance,
        uint256 realTokenBalance,
        uint256 kValue,
        uint256 priceHuman
    ) {
        currentPrice = getCurrentPrice();
        currentUsdtReserve = usdtReserve;
        currentTokenReserve = tokenReserve;
        currentVirtualBurned = virtualBurnedTokens;
        effectiveTokens = getEffectiveTokens();
        
        // Real balances
        realUsdtBalance = usdtToken.balanceOf(address(this));
        realTokenBalance = fierceToken.balanceOf(address(this));
        
        // Constant product k = usdtReserve * effectiveTokens
        kValue = usdtReserve * effectiveTokens;
        
        // Price in human readable format (with priceDecimals)
        priceHuman = currentPrice;
    }
    
    /**
     * @notice Get detailed pool info incluyendo valores formateados
     */
    function getDetailedPoolInfo() external view returns (
        uint256 price,
        uint256 usdtInPool,
        uint256 tokensInPool,
        uint256 usdtInPoolHuman,
        uint256 tokensInPoolHuman,
        uint256 priceHuman
    ) {
        price = getCurrentPrice();
        usdtInPool = usdtReserve;
        tokensInPool = tokenReserve;
        
        // Valores en formato humano (sin decimales del token)
        usdtInPoolHuman = usdtReserve / (10 ** usdtDecimals);
        tokensInPoolHuman = tokenReserve / (10 ** tokenDecimals);
        priceHuman = price;
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    function PRICE_DECIMALS_SAFE() internal view returns (uint256) {
        return 10 ** priceDecimals;
    }
    
    // ==================== LIQUIDITY WITHDRAWAL ====================
    function withdrawFierceTokens(
        uint256 amount
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        require(amount > 0, "Amount must be > 0");
        require(amount <= tokenReserve, "Insufficient tokens in pool");
        
        tokenReserve -= amount;
        
        require(
            fierceToken.transfer(treasuryAddress, amount),
            "Token transfer failed"
        );

        newPrice = getCurrentPrice();
        emit ReservesSynced(usdtReserve, tokenReserve);
        
        return newPrice;
    }

    function withdrawUSDT(
        uint256 amount
    ) external onlyOwner nonReentrant returns (uint256 newPrice) {
        require(amount > 0, "Amount must be > 0");
        require(amount <= usdtReserve, "Insufficient USDT in pool");
        
        usdtReserve -= amount;
        
        require(
            usdtToken.transfer(treasuryAddress, amount),
            "USDT transfer failed"
        );

        newPrice = getCurrentPrice();
        emit ReservesSynced(usdtReserve, tokenReserve);
        
        return newPrice;
    }

    // ==================== EMERGENCY FUNCTIONS ====================
    function adjustVirtualBurned(uint256 newVirtualBurned) external onlyOwner {
        require(newVirtualBurned <= tokenReserve, "Cannot burn more than total tokens");
        virtualBurnedTokens = newVirtualBurned;
    }
    
    function rescueTokens(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(tokenAddress != address(usdtToken) && tokenAddress != address(fierceToken),
                "Cannot withdraw pool tokens");
        
        IERC20(tokenAddress).transfer(msg.sender, amount);
    }
    
    // ==================== ESTIMATE FUNCTIONS CORREGIDAS ====================
    function estimateTokensForUSDT(uint256 usdtAmount) external view returns (uint256 tokensOut) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0 || usdtReserve == 0) return 0;
        
        uint256 usdtAfterFee = usdtAmount;
        if (swapFeePercent > 0) {
            uint256 fee = (usdtAmount * swapFeePercent) / PERCENT_DECIMALS;
            usdtAfterFee = usdtAmount - fee;
        }
        
        // Fórmula corregida con precisión
        uint256 numerator = effectiveTokens * usdtReserve * precisionMultiplier;
        uint256 denominator = (usdtReserve + usdtAfterFee) * precisionMultiplier;
        tokensOut = effectiveTokens - (numerator / denominator);
        
        return tokensOut;
    }
    
    function estimateUSDTForTokens(uint256 tokenAmount) external view returns (uint256 usdtOut) {
        uint256 effectiveTokens = getEffectiveTokens();
        if (effectiveTokens == 0) return 0;
        
        uint256 numerator = usdtReserve * effectiveTokens * precisionMultiplier;
        uint256 denominator = (effectiveTokens + tokenAmount) * precisionMultiplier;
        usdtOut = usdtReserve - (numerator / denominator);
        
        if (swapFeePercent > 0) {
            uint256 fee = (usdtOut * swapFeePercent) / PERCENT_DECIMALS;
            usdtOut -= fee;
        }
        
        return usdtOut;
    }
}

// ==================== LIBRERÍA STRINGS (agregar al final) ====================
library Strings {
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}