// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SimpleFierceSwap
 * @author Your Platform
 * @notice Simple contract to swap ERC20 ↔ USDT with correct decimal handling
 * 
 * @dev USDT uses 6 decimals, FIERCE token uses 18 decimals
 *      All USDT amounts in the contract are stored with 6 decimals
 */
contract SimpleFierceSwap is Ownable, ReentrancyGuard {
    // ==================== CONSTANTS ====================
    uint256 public constant PERCENT_DECIMALS = 10000; // 10000 = 100%
    uint256 public constant USDT_DECIMALS = 6;
    uint256 public constant TOKEN_DECIMALS = 18;
    
    // ==================== CONFIGURATION ====================
    uint256 public priceDecimals = 4; // Price decimals (4 = 0.0000)
    uint256 public fixedPrice = 35; // Price in 4 decimals (35 = 0.0035)
    uint256 public swapFeePercent = 250; // 2.5% fee
    
    // ==================== TOKENS ====================
    IERC20 public immutable usdtToken;
    IERC20 public immutable fierceToken;
    address public immutable treasuryAddress; // Where fees go
    
    // ==================== RESERVES ====================
    uint256 public usdtReserve; // USDT available to pay (in 6 decimals)
    uint256 public tokenReserve; // Tokens available (in 18 decimals)
    
    // ==================== CONTROLS ====================
    bool public systemActive = true;
    
    // ==================== EVENTS ====================
    event TokensSwappedForUSDT(
        address indexed user,
        uint256 tokenAmount,
        uint256 usdtReceived,
        uint256 fee,
        uint256 priceUsed
    );
    
    event USDTSwappedForTokens(
        address indexed user,
        uint256 usdtAmount,
        uint256 tokensReceived,
        uint256 fee,
        uint256 priceUsed
    );
    
    event PriceUpdated(uint256 newPrice, uint256 decimals);
    event FeeUpdated(uint256 newFee);
    event ReservesUpdated(uint256 usdtAmount, uint256 tokenAmount);
    event SystemToggled(bool active);
    event TreasuryChanged(address newTreasury);
    event TokensDeposited(address indexed from, uint256 amount);
    event USDTDeposited(address indexed from, uint256 amount);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event USDTWithdrawn(address indexed to, uint256 amount);
    
    // ==================== CONSTRUCTOR ====================
    constructor(
        address _usdtAddress,
        address _fierceTokenAddress,
        address _initialOwner,
        address _treasuryAddress
    ) Ownable(_initialOwner) {
        require(_usdtAddress != address(0), "Invalid USDT");
        require(_fierceTokenAddress != address(0), "Invalid Fierce");
        require(_treasuryAddress != address(0), "Invalid Treasury");
        
        usdtToken = IERC20(_usdtAddress);
        fierceToken = IERC20(_fierceTokenAddress);
        treasuryAddress = _treasuryAddress;
    }
    
    // ============================================================
    //              MAIN FUNCTIONS (Backend only - onlyOwner)
    // ============================================================
    
    /**
     * @dev Swaps ERC20 tokens for USDT at fixed price
     * @param seller Address of the user selling tokens (must have approved tokens to this contract)
     * @param tokenAmount Amount of tokens to sell (in 18 decimals)
     */
    function swapTokensForUSDT(address seller, uint256 tokenAmount) external onlyOwner nonReentrant {
        require(systemActive, "System is paused");
        require(seller != address(0), "Invalid seller");
        require(tokenAmount > 0, "Amount must be > 0");
        require(fixedPrice > 0, "Price not set");
        
        // 1. Calculate USDT at fixed price
        // Formula: USDT = (tokens * price) / 10^priceDecimals
        uint256 usdtAmount = (tokenAmount * fixedPrice) / (10 ** priceDecimals);
        
        // 2. Convert to 6 decimals (USDT standard)
        // token has 18 decimals, priceDecimals can be variable
        // Adjustment = 10^(18 - priceDecimals - 6)
        uint256 adjustment = 10 ** (TOKEN_DECIMALS - priceDecimals - USDT_DECIMALS);
        uint256 usdtAmount6Decimals = usdtAmount / adjustment;
        
        require(usdtAmount6Decimals > 0, "USDT amount too small");
        
        // 3. Apply swap fee
        uint256 fee = (usdtAmount6Decimals * swapFeePercent) / PERCENT_DECIMALS;
        uint256 usdtAfterFee = usdtAmount6Decimals - fee;
        
        // 4. Check USDT reserve (both in 6 decimals)
        require(usdtAfterFee <= usdtReserve, "Insufficient USDT in reserve");
        
        // 5. Transfer tokens from seller to contract
        require(
            fierceToken.transferFrom(seller, address(this), tokenAmount),
            "Token transfer failed"
        );
        
        // 6. Update reserves
        tokenReserve += tokenAmount;
        usdtReserve -= usdtAfterFee;
        
        // 7. Send fee to treasury (in USDT, 6 decimals)
        if (fee > 0) {
            require(
                usdtToken.transfer(treasuryAddress, fee),
                "Fee transfer failed"
            );
        }
        
        // 8. Send USDT to seller (6 decimals)
        require(
            usdtToken.transfer(seller, usdtAfterFee),
            "USDT transfer failed"
        );
        
        emit TokensSwappedForUSDT(
            seller,
            tokenAmount,
            usdtAfterFee,
            fee,
            fixedPrice
        );
    }
    
    /**
     * @dev Swaps USDT for ERC20 tokens at fixed price
     * @param buyer Address of the user buying tokens (must have approved USDT to this contract)
     * @param usdtAmount Amount of USDT to spend (in 6 decimals)
     */
    function swapUSDTForTokens(address buyer, uint256 usdtAmount) external onlyOwner nonReentrant {
        require(systemActive, "System is paused");
        require(buyer != address(0), "Invalid buyer");
        require(usdtAmount > 0, "Amount must be > 0");
        require(fixedPrice > 0, "Price not set");
        
        // 1. Calculate tokens at fixed price (in 18 decimals)
        // Formula: tokens = (usdtAmount * 10^priceDecimals * 10^(18-6)) / price
        // Simplified: tokens = (usdtAmount * 10^(priceDecimals + 12)) / price
        uint256 tokenAmount = (usdtAmount * (10 ** (priceDecimals + TOKEN_DECIMALS - USDT_DECIMALS))) / fixedPrice;
        require(tokenAmount > 0, "Token amount too small");
        
        // 2. Apply swap fee (deducted from tokens received)
        uint256 fee = (tokenAmount * swapFeePercent) / PERCENT_DECIMALS;
        uint256 tokensAfterFee = tokenAmount - fee;
        
        // 3. Check token reserve
        require(tokensAfterFee <= tokenReserve, "Insufficient tokens in reserve");
        
        // 4. Transfer USDT from buyer to contract (6 decimals)
        require(
            usdtToken.transferFrom(buyer, address(this), usdtAmount),
            "USDT transfer failed"
        );
        
        // 5. Update reserves
        usdtReserve += usdtAmount;
        tokenReserve -= tokensAfterFee;
        
        // 6. Send fee to treasury (in tokens, 18 decimals)
        if (fee > 0) {
            require(
                fierceToken.transfer(treasuryAddress, fee),
                "Fee transfer failed"
            );
        }
        
        // 7. Send tokens to buyer (18 decimals)
        require(
            fierceToken.transfer(buyer, tokensAfterFee),
            "Token transfer failed"
        );
        
        emit USDTSwappedForTokens(
            buyer,
            usdtAmount,
            tokensAfterFee,
            fee,
            fixedPrice
        );
    }
    
    // ============================================================
    //              QUERY FUNCTIONS (View)
    // ============================================================
    
    /**
     * @dev Gets the current price
     */
    function getCurrentPrice() public view returns (uint256) {
        return fixedPrice;
    }
    
    /**
     * @dev Gets the price as string for display
     */
    function getPriceString() external view returns (string memory) {
        uint256 price = fixedPrice;
        uint256 integerPart = price / (10 ** priceDecimals);
        uint256 decimalPart = price % (10 ** priceDecimals);
        
        string memory decimalStr = uint2str(decimalPart);
        while (bytes(decimalStr).length < priceDecimals) {
            decimalStr = string(abi.encodePacked("0", decimalStr));
        }
        
        return string(abi.encodePacked(
            uint2str(integerPart),
            ".",
            decimalStr
        ));
    }
    
    /**
     * @dev Gets system information (only necessary data)
     */
    function getSystemInfo() external view returns (
        uint256 price,
        uint256 priceDec,
        uint256 usdtAvailable,
        uint256 tokenAvailable,
        uint256 feePercent,
        bool active
    ) {
        return (
            fixedPrice,
            priceDecimals,
            usdtReserve,
            tokenReserve,
            swapFeePercent,
            systemActive
        );
    }
    
    /**
     * @dev Estimates how much USDT you would receive when selling tokens
     * @param tokenAmount Amount of tokens to sell (in 18 decimals)
     * @return usdtAmount Total USDT before fee (in 6 decimals)
     * @return fee Fee amount (in 6 decimals)
     * @return usdtAfterFee USDT after fee (in 6 decimals)
     */
    function estimateSwap(uint256 tokenAmount) external view returns (
        uint256 usdtAmount,
        uint256 fee,
        uint256 usdtAfterFee
    ) {
        // Calculate USDT in 18 decimals then convert to 6 decimals
        uint256 usdtAmount18Dec = (tokenAmount * fixedPrice) / (10 ** priceDecimals);
        uint256 adjustment = 10 ** (TOKEN_DECIMALS - priceDecimals - USDT_DECIMALS);
        usdtAmount = usdtAmount18Dec / adjustment;
        
        fee = (usdtAmount * swapFeePercent) / PERCENT_DECIMALS;
        usdtAfterFee = usdtAmount - fee;
    }
    
    /**
     * @dev Calculates how many tokens you need to get X USDT
     * @param usdtAmount Amount of USDT desired (in 6 decimals)
     * @return tokenAmount Tokens needed (in 18 decimals)
     */
    function estimateTokensForUSDT(uint256 usdtAmount) external view returns (uint256 tokenAmount) {
        // Adjust for fee
        uint256 usdtBeforeFee = (usdtAmount * PERCENT_DECIMALS) / (PERCENT_DECIMALS - swapFeePercent);
        tokenAmount = (usdtBeforeFee * (10 ** (priceDecimals + TOKEN_DECIMALS - USDT_DECIMALS))) / fixedPrice;
        return tokenAmount;
    }
    
    /**
     * @dev Estimates how many tokens you would receive when spending USDT
     * @param usdtAmount Amount of USDT to spend (in 6 decimals)
     * @return tokenAmount Total tokens before fee (in 18 decimals)
     * @return fee Fee amount (in 18 decimals)
     * @return tokensAfterFee Tokens after fee (in 18 decimals)
     */
    function estimateUSDTForTokens(uint256 usdtAmount) external view returns (
        uint256 tokenAmount,
        uint256 fee,
        uint256 tokensAfterFee
    ) {
        tokenAmount = (usdtAmount * (10 ** (priceDecimals + TOKEN_DECIMALS - USDT_DECIMALS))) / fixedPrice;
        fee = (tokenAmount * swapFeePercent) / PERCENT_DECIMALS;
        tokensAfterFee = tokenAmount - fee;
    }
    
    // ============================================================
    //              ADMINISTRATIVE FUNCTIONS (Owner)
    // ============================================================
    
    /**
     * @dev Deposits USDT to reserve and auto-syncs reserves
     * @param amount Amount of USDT to deposit (in 6 decimals)
     */
    function depositUSDT(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(
            usdtToken.transferFrom(msg.sender, address(this), amount),
            "USDT transfer failed"
        );
        
        // Update reserves
        usdtReserve += amount;
        
        emit USDTDeposited(msg.sender, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Deposits tokens to reserve and auto-syncs reserves
     * @param amount Amount of tokens to deposit (in 18 decimals)
     */
    function depositTokens(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(
            fierceToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
        
        // Update reserves
        tokenReserve += amount;
        
        emit TokensDeposited(msg.sender, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Deposits USDT and auto-syncs reserves in one transaction
     * @param amount Amount of USDT to deposit (in 6 decimals)
     */
    function depositUSDTAndSync(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(
            usdtToken.transferFrom(msg.sender, address(this), amount),
            "USDT transfer failed"
        );
        
        // Update reserves
        usdtReserve += amount;
        
        emit USDTDeposited(msg.sender, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Deposits tokens and auto-syncs reserves in one transaction
     * @param amount Amount of tokens to deposit (in 18 decimals)
     */
    function depositTokensAndSync(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(
            fierceToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
        
        // Update reserves
        tokenReserve += amount;
        
        emit TokensDeposited(msg.sender, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Updates the fixed price
     * @param newPrice New price (eg: 35 = 0.0035)
     * @param newDecimals New decimals (eg: 4 = 0.0000)
     */
    function updatePrice(uint256 newPrice, uint256 newDecimals) external onlyOwner {
        require(newPrice > 0, "Price must be > 0");
        require(newDecimals >= 0 && newDecimals <= 18, "Invalid decimals");
        
        fixedPrice = newPrice;
        priceDecimals = newDecimals;
        
        emit PriceUpdated(newPrice, newDecimals);
    }
    
    /**
     * @dev Updates swap fee
     * @param newFee New fee (eg: 100 = 1%, 200 = 2%)
     */
    function updateSwapFee(uint256 newFee) external onlyOwner {
        require(newFee <= 1000, "Max fee 10%");
        
        swapFeePercent = newFee;
        
        emit FeeUpdated(newFee);
    }
    
    /**
     * @dev Activates or deactivates the system
     */
    function toggleSystem(bool active) external onlyOwner {
        systemActive = active;
        emit SystemToggled(active);
    }
    
    /**
     * @dev Withdraws USDT from reserve (emergency)
     * @param amount Amount of USDT to withdraw (in 6 decimals)
     */
    function withdrawUSDT(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0 && amount <= usdtReserve, "Invalid amount");
        
        usdtReserve -= amount;
        
        require(
            usdtToken.transfer(treasuryAddress, amount),
            "USDT transfer failed"
        );
        
        emit USDTWithdrawn(treasuryAddress, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Withdraws tokens from reserve (emergency)
     * @param amount Amount of tokens to withdraw (in 18 decimals)
     */
    function withdrawTokens(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0 && amount <= tokenReserve, "Invalid amount");
        
        tokenReserve -= amount;
        
        require(
            fierceToken.transfer(treasuryAddress, amount),
            "Token transfer failed"
        );
        
        emit TokensWithdrawn(treasuryAddress, amount);
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Syncs reserves with real balances (manual sync)
     */
    function syncReserves() external onlyOwner {
        uint256 realUSDT = usdtToken.balanceOf(address(this));
        uint256 realTokens = fierceToken.balanceOf(address(this));
        
        usdtReserve = realUSDT;
        tokenReserve = realTokens;
        
        emit ReservesUpdated(usdtReserve, tokenReserve);
    }
    
    /**
     * @dev Emergency withdrawal of non-system tokens
     * @notice Tokens are split 50/50 between owner and treasury
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(usdtToken) && token != address(fierceToken),
                "Cannot withdraw system tokens");
        require(amount > 0, "Amount must be > 0");
        
        uint256 ownerAmount = amount / 2;
        uint256 treasuryAmount = amount - ownerAmount;
        
        // Send half to owner
        require(
            IERC20(token).transfer(msg.sender, ownerAmount),
            "Owner transfer failed"
        );
        
        // Send half to treasury
        require(
            IERC20(token).transfer(treasuryAddress, treasuryAmount),
            "Treasury transfer failed"
        );
    }
    
    // ============================================================
    //              INTERNAL FUNCTIONS
    // ============================================================
    
    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}