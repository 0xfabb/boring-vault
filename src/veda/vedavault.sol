// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;


import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {Auth, Authority} from "lib/solmate/src/auth/Auth.sol";

/**
 * @title VedaVault - Advanced Yield Amplification Strategy
 * @author vedadev
 * @notice Implements recursive staking/borrowing loops to amplify yield on HYPE tokens
 * @dev Uses stHYPE as collateral to borrow more HYPE, creating leveraged positions
 */
contract VedaVault is Auth, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    //=============================================================================
    // CONFIGURATION STRUCTURES
    //=============================================================================

    /**
     * @notice Parameters controlling the looping behavior
     * @dev All LTV values are in basis points (10000 = 100%)
     */
    struct StrategyParams {
        uint256 targetLeverageRatio;    // Desired LTV for optimal yield (e.g., 8000 = 80%)
        uint256 maxSafeLeverageRatio;   // Maximum LTV before liquidation danger
        uint256 minEfficientRatio;      // Minimum LTV to maintain profitability
        uint256 rebalanceTrigger;       // Deviation threshold for rebalancing
        uint256 maxLoopCycles;          // Gas protection - max recursion depth
        bool strategyActive;            // Master switch for strategy operations
    }

    /**
     * @notice Real-time position metrics
     * @dev Provides comprehensive view of current strategy state
     */
    struct PositionMetrics {
        uint256 totalStakedBalance;     // Sum of all stHYPE held (direct + collateral)
        uint256 totalDebtBalance;       // Total HYPE borrowed across all positions
        uint256 underlyingValue;        // Current value of staked assets in HYPE terms
        uint256 leverageRatio;          // Current debt-to-collateral ratio
        uint256 grossPositionValue;     // Total position size including leverage
        uint256 netEquityValue;         // Actual user equity (assets - debt)
    }

    //=============================================================================
    // EVENTS FOR MONITORING & ANALYTICS
    //=============================================================================

    event StrategyExecuted(uint256 cycles, uint256 finalStaked, uint256 finalBorrowed);
    event LeverageAdjusted(uint256 previousRatio, uint256 newRatio, bool isIncrease);
    event ParametersUpdated(StrategyParams previousParams, StrategyParams newParams);
    event EmergencyUnwind(uint256 assetsRecovered, uint256 debtCleared);
    event RewardsCompounded(uint256 harvestedAmount, uint256 compoundedAmount);
    event UserDeposited(address indexed depositor, uint256 amount, uint256 sharesIssued);
    event UserWithdrew(address indexed withdrawer, uint256 shares, uint256 amountReceived);
    
    //=============================================================================
    // CUSTOM ERRORS
    //=============================================================================

    error VedaVault__InvalidParameterConfiguration();
    error VedaVault__DangerousLeverageLevel();
    error VedaVault__StrategyCurrentlyDisabled();
    error VedaVault__InsufficientCollateralCoverage();
    error VedaVault__ExcessiveSlippageDetected();
    error VedaVault__MaximumLoopCyclesExceeded();
    error VedaVault__PriceOracleFailure();

    //=============================================================================
    // IMMUTABLE PROTOCOL ADDRESSES
    //=============================================================================

    /// @notice Core HYPE token for deposits and borrowing
    ERC20 public immutable baseAsset;

    /// @notice Staked HYPE token received from yield protocol
    ERC20 public immutable stakedAsset;

    /// @notice Yield-bearing staking protocol contract
    address public immutable yieldProtocol;

    /// @notice Lending market for borrowing operations
    address public immutable borrowingMarket;

    /// @notice Maximum percentage in basis points
    uint256 public constant BASIS_POINTS_SCALE = 10000;

    /// @notice High precision for internal calculations
    uint256 public constant CALCULATION_PRECISION = 1e18;

    //=============================================================================
    // STRATEGY STATE VARIABLES
    //=============================================================================

    /// @notice Current operational parameters
    StrategyParams public strategyConfig;

    /// @notice Timestamp of last reward harvest
    uint256 public lastRewardHarvest;

    /// @notice Accumulated protocol fees awaiting collection
    uint256 public pendingProtocolFees;

    /// @notice Performance fee rate in basis points (default: 1500 = 15%)
    uint256 public protocolFeeRate = 1500;

    /// @notice User ownership tracking - shares represent proportional vault ownership
    mapping(address => uint256) public userShareBalance;

    /// @notice User entry timestamp for potential time-based features
    mapping(address => uint256) public userEntryTimestamp;

    //=============================================================================
    // CONSTRUCTOR & INITIALIZATION
    //=============================================================================

    constructor(
        address _admin,
        address _accessControl,
        address _baseAsset,
        address _stakedAsset,
        address _yieldProtocol,
        address _borrowingMarket
    ) Auth(_admin, Authority(_accessControl)) {
        baseAsset = ERC20(_baseAsset);
        stakedAsset = ERC20(_stakedAsset);
        yieldProtocol = _yieldProtocol;
        borrowingMarket = _borrowingMarket;

        // Initialize with conservative but profitable parameters
        strategyConfig = StrategyParams({
            targetLeverageRatio: 7800,      // 78% LTV target
            maxSafeLeverageRatio: 8700,     // 87% maximum before danger
            minEfficientRatio: 6200,        // 62% minimum for efficiency
            rebalanceTrigger: 400,          // 4% deviation triggers rebalance
            maxLoopCycles: 6,               // Maximum 6 recursive loops
            strategyActive: true
        });

        lastRewardHarvest = block.timestamp;
    }

    //=============================================================================
    // ADMINISTRATIVE CONTROLS
    //=============================================================================

    /**
     * @notice Updates strategy operational parameters
     * @dev Validates parameter safety before applying changes
     * @param newParams New configuration to apply
     */
    function reconfigureStrategy(StrategyParams calldata newParams) external requiresAuth {
        // Validate parameter relationships and safety bounds
        if (newParams.targetLeverageRatio >= newParams.maxSafeLeverageRatio || 
            newParams.minEfficientRatio >= newParams.targetLeverageRatio ||
            newParams.maxSafeLeverageRatio > 9300 || // Hard cap at 93% for safety
            newParams.maxLoopCycles == 0) {
            revert VedaVault__InvalidParameterConfiguration();
        }

        StrategyParams memory oldParams = strategyConfig;
        strategyConfig = newParams;
        
        emit ParametersUpdated(oldParams, newParams);
    }

    /**
     * @notice Adjusts protocol fee rate
     * @dev Enforces maximum fee cap for user protection
     * @param newRate New fee rate in basis points
     */
    function adjustProtocolFees(uint256 newRate) external requiresAuth {
        require(newRate <= 2500, "Fee exceeds maximum allowed"); // 25% cap
        protocolFeeRate = newRate;
    }

    /**
     * @notice Emergency function to unwind all positions
     * @dev Only accessible by authorized accounts in crisis situations
     */
    function executeEmergencyUnwind() external requiresAuth {
        _completePositionUnwind();
        
        uint256 recoveredAssets = baseAsset.balanceOf(address(this));
        emit EmergencyUnwind(recoveredAssets, 0);
    }

    //=============================================================================
    // CORE USER FUNCTIONS
    //=============================================================================

    /**
     * @notice Deposits HYPE and executes leveraged staking strategy
     * @dev User receives shares proportional to their deposit
     * @param depositAmount Amount of HYPE tokens to deposit
     * @param minimumStaked Minimum stHYPE expected (slippage protection)
     * @return sharesIssued Number of vault shares minted to user
     */
    function enterPosition(uint256 depositAmount, uint256 minimumStaked) external nonReentrant returns (uint256 sharesIssued) {
        if (!strategyConfig.strategyActive) revert VedaVault__StrategyCurrentlyDisabled();
        require(depositAmount > 0, "Deposit amount must be positive");
        
        // Transfer user's HYPE to vault
        baseAsset.safeTransferFrom(msg.sender, address(this), depositAmount);
        
        // Issue shares 1:1 with deposit (simple share model)
        sharesIssued = depositAmount;
        
        // Capture pre-strategy state
        uint256 stakedBefore = stakedAsset.balanceOf(address(this));
        
        // Execute recursive leverage strategy
        _implementLeverageStrategy(depositAmount);
        
        // Verify adequate staking occurred
        uint256 stakedAfter = stakedAsset.balanceOf(address(this));
        uint256 netStaked = stakedAfter - stakedBefore;
        if (netStaked < minimumStaked) revert VedaVault__ExcessiveSlippageDetected();
        
        // Update user records
        userShareBalance[msg.sender] += sharesIssued;
        userEntryTimestamp[msg.sender] = block.timestamp;
        
        emit UserDeposited(msg.sender, depositAmount, sharesIssued);
    }

    /**
     * @notice Withdraws user's position by unwinding leverage
     * @dev Burns shares and returns proportional HYPE amount
     * @param sharesToBurn Number of shares to redeem
     * @param minimumOutput Minimum HYPE expected (slippage protection)
     * @return hyteReceived Actual HYPE tokens transferred to user
     */
    function exitPosition(uint256 sharesToBurn, uint256 minimumOutput) external nonReentrant returns (uint256 hyteReceived) {
        require(sharesToBurn > 0, "Shares to burn must be positive");
        
        // Validate user has sufficient shares
        uint256 userCurrentShares = userShareBalance[msg.sender];
        require(userCurrentShares >= sharesToBurn, "Insufficient share balance");
        require(userCurrentShares > 0, "No shares owned");
        
        // Calculate proportional HYPE amount (1:1 with shares)
        uint256 targetHypeAmount = sharesToBurn;
        
        // Verify vault can support withdrawal
        PositionMetrics memory metrics = getCurrentMetrics();
        require(metrics.netEquityValue > 0, "Vault has negative equity");
        require(targetHypeAmount <= metrics.netEquityValue, "Insufficient vault liquidity");
        
        // Additional user-specific validation
        uint256 userMaxWithdrawal = _calculateUserWithdrawableAmount(msg.sender);
        require(targetHypeAmount <= userMaxWithdrawal, "Exceeds user withdrawable amount");
        
        // Record pre-withdrawal HYPE balance
        uint256 hypeBefore = baseAsset.balanceOf(address(this));
        
        // Execute proportional position unwind
        _executeProportionalUnwind(targetHypeAmount);
        
        // Calculate actual HYPE received
        uint256 hypeAfter = baseAsset.balanceOf(address(this));
        hyteReceived = hypeAfter > hypeBefore ? hypeAfter - hypeBefore : 0;
        
        if (hyteReceived < minimumOutput) revert VedaVault__ExcessiveSlippageDetected();
        
        // Update user share balance
        userShareBalance[msg.sender] = userCurrentShares - sharesToBurn;
        
        // Transfer HYPE to user
        if (hyteReceived > 0) {
            baseAsset.safeTransfer(msg.sender, hyteReceived);
        }
        
        emit UserWithdrew(msg.sender, sharesToBurn, hyteReceived);
    }

    /**
     * @notice Harvests yield rewards and compounds them back into strategy
     * @dev Implements time-based harvest cooldown to prevent MEV attacks
     */
    function harvestAndReinvest() external nonReentrant {
        uint256 timeSinceLastHarvest = block.timestamp - lastRewardHarvest;
        require(timeSinceLastHarvest >= 2 hours, "Harvest cooldown active");
        
        // Claim available staking rewards
        uint256 harvestedRewards = _claimStakingRewards();
        
        if (harvestedRewards > 0) {
            // Extract protocol performance fee
            uint256 protocolFee = harvestedRewards.mulDivDown(protocolFeeRate, BASIS_POINTS_SCALE);
            pendingProtocolFees += protocolFee;
            
            uint256 compoundableRewards = harvestedRewards - protocolFee;
            
            // Reinvest net rewards through leverage strategy
            if (compoundableRewards > 0 && strategyConfig.strategyActive) {
                _implementLeverageStrategy(compoundableRewards);
            }
            
            emit RewardsCompounded(harvestedRewards, compoundableRewards);
        }
        
        lastRewardHarvest = block.timestamp;
    }

    /**
     * @notice Rebalances leverage ratio if outside target parameters
     * @dev Automatically adjusts position to maintain optimal leverage
     */
    function rebalanceLeverage() external nonReentrant {
        PositionMetrics memory metrics = getCurrentMetrics();
        
        uint256 targetRatio = strategyConfig.targetLeverageRatio;
        uint256 triggerThreshold = strategyConfig.rebalanceTrigger;
        
        // Determine if rebalancing is necessary
        bool requiresRebalance = metrics.leverageRatio > targetRatio + triggerThreshold || 
                                metrics.leverageRatio < targetRatio - triggerThreshold;
        
        if (!requiresRebalance) return;
        
        bool isLeverageIncrease = metrics.leverageRatio < targetRatio;
        uint256 previousRatio = metrics.leverageRatio;
        
        if (isLeverageIncrease) {
            _amplifyLeverage(metrics, targetRatio);
        } else {
            _reduceLeverage(metrics, targetRatio);
        }
        
        emit LeverageAdjusted(previousRatio, targetRatio, isLeverageIncrease);
    }

    //=============================================================================
    // USER BALANCE CALCULATIONS
    //=============================================================================

    /**
     * @notice Calculates user's withdrawable HYPE amount
     * @dev In this vault design, shares represent original deposit claims
     * @param user Address to check
     * @return withdrawableAmount Maximum HYPE user can withdraw
     */
    function _calculateUserWithdrawableAmount(address user) internal view returns (uint256 withdrawableAmount) {
        uint256 userShares = userShareBalance[user];
        if (userShares == 0) return 0;
        
        // Simple model: user's withdrawable amount equals their share count
        // This represents their proportional claim on vault's net equity
        return userShares;
    }

    //=============================================================================
    // LEVERAGE STRATEGY IMPLEMENTATION
    //=============================================================================

    /**
     * @notice Executes recursive leverage strategy on given HYPE amount
     * @dev Loops through stake->borrow cycles until target leverage achieved
     * @param initialAmount Starting HYPE amount for strategy
     */
    function _implementLeverageStrategy(uint256 initialAmount) internal {
        uint256 currentAmount = initialAmount;
        uint256 cycleCount = 0;
        
        while (cycleCount < strategyConfig.maxLoopCycles && currentAmount > 0) {
            // Stake HYPE to receive stHYPE
            uint256 stakedReceived = _stakeTokens(currentAmount);
            
            // Borrow HYPE against stHYPE collateral
            uint256 borrowedAmount = _borrowAgainstStaking(stakedReceived);
            
            // Economic efficiency check - exit if returns diminish
            if (borrowedAmount < initialAmount / 80) break; // Less than 1.25% of initial
            
            // Recursive efficiency check
            if (borrowedAmount < currentAmount / 8) break; // Less than 12.5% of current
            
            currentAmount = borrowedAmount;
            cycleCount++;
        }
        
        // Only revert if no progress made, not for hitting max cycles
        if (cycleCount >= strategyConfig.maxLoopCycles && currentAmount > initialAmount / 40) {
            revert VedaVault__MaximumLoopCyclesExceeded();
        }
        
        PositionMetrics memory finalMetrics = getCurrentMetrics();
        emit StrategyExecuted(cycleCount, finalMetrics.totalStakedBalance, finalMetrics.totalDebtBalance);
    }

    /**
     * @notice Stakes HYPE tokens in yield protocol
     * @dev Interacts with external staking contract
     * @param amount HYPE amount to stake
     * @return stakedReceived Amount of stHYPE tokens received
     */
    function _stakeTokens(uint256 amount) internal returns (uint256 stakedReceived) {
        if (amount == 0) return 0;
        
        // Approve staking protocol to spend HYPE
        baseAsset.safeApprove(yieldProtocol, amount);
        
        uint256 stakedBefore = stakedAsset.balanceOf(address(this));
        
        // Execute staking transaction
        (bool success,) = yieldProtocol.call(
            abi.encodeWithSignature("stake(uint256)", amount)
        );
        require(success, "Staking operation failed");
        
        uint256 stakedAfter = stakedAsset.balanceOf(address(this));
        stakedReceived = stakedAfter - stakedBefore;
    }

    /**
     * @notice Borrows HYPE using stHYPE as collateral
     * @dev Calculates safe borrow amount based on target leverage
     * @param collateralAmount stHYPE amount to deposit as collateral
     * @return borrowedAmount HYPE amount successfully borrowed
     */
    function _borrowAgainstStaking(uint256 collateralAmount) internal returns (uint256 borrowedAmount) {
        if (collateralAmount == 0) return 0;
        
        // Approve lending market to accept collateral
        stakedAsset.safeApprove(borrowingMarket, collateralAmount);
        
        // Calculate maximum safe borrow amount
        uint256 collateralValue = _getStakedAssetValue(collateralAmount);
        uint256 maxBorrowAmount = collateralValue.mulDivDown(strategyConfig.targetLeverageRatio, BASIS_POINTS_SCALE);
        
        uint256 hypeBefore = baseAsset.balanceOf(address(this));
        
        // Execute borrow transaction
        (bool success,) = borrowingMarket.call(
            abi.encodeWithSignature(
                "depositCollateralAndBorrow(address,uint256,address,uint256)",
                address(stakedAsset),
                collateralAmount,
                address(baseAsset),
                maxBorrowAmount
            )
        );
        require(success, "Borrowing operation failed");
        
        uint256 hypeAfter = baseAsset.balanceOf(address(this));
        borrowedAmount = hypeAfter - hypeBefore;
    }

    /**
     * @notice Completely unwinds all leveraged positions
     * @dev Emergency function to close all positions
     */
    function _completePositionUnwind() internal {
        PositionMetrics memory metrics = getCurrentMetrics();
        
        // Repay all outstanding debt
        if (metrics.totalDebtBalance > 0) {
            _repayBorrowedAmount(metrics.totalDebtBalance);
        }
        
        // Unstake all stHYPE holdings
        if (metrics.totalStakedBalance > 0) {
            _unstakeAllTokens();
        }
    }

    /**
     * @notice Partially unwinds position for user withdrawals
     * @dev Calculates proportional unwinding to maintain strategy balance
     * @param targetWithdrawAmount HYPE amount needed for withdrawal
     */
    function _executeProportionalUnwind(uint256 targetWithdrawAmount) internal {
        PositionMetrics memory metrics = getCurrentMetrics();
        
        // If withdrawal exceeds net equity, unwind everything
        if (targetWithdrawAmount >= metrics.netEquityValue) {
            _completePositionUnwind();
            return;
        }
        
        // Calculate proportional unwind ratio
        uint256 unwindRatio = targetWithdrawAmount.mulDivDown(CALCULATION_PRECISION, metrics.netEquityValue);
        uint256 debtToRepay = metrics.totalDebtBalance.mulDivDown(unwindRatio, CALCULATION_PRECISION);
        
        // Calculate collateral to withdraw from lending market
        uint256 lendingCollateral = _getCollateralInLending();
        uint256 collateralToWithdraw = lendingCollateral.mulDivDown(unwindRatio, CALCULATION_PRECISION);
        
        // Execute proportional unwinding steps
        if (debtToRepay > 0) {
            _repayBorrowedAmount(debtToRepay);
        }
        
        if (collateralToWithdraw > 0) {
            _withdrawLendingCollateral(collateralToWithdraw);
        }
        
        if (collateralToWithdraw > 0) {
            _unstakeSpecificAmount(collateralToWithdraw);
        }
    }

    /**
     * @notice Increases leverage to reach target ratio
     * @dev Borrows more and stakes to amplify position
     */
    function _amplifyLeverage(PositionMetrics memory metrics, uint256 targetRatio) internal {
        uint256 targetDebt = metrics.underlyingValue.mulDivDown(targetRatio, BASIS_POINTS_SCALE);
        uint256 additionalDebt = targetDebt - metrics.totalDebtBalance;
        
        if (additionalDebt > 0) {
            _borrowAdditionalAmount(additionalDebt);
            _stakeTokens(additionalDebt);
        }
    }

    /**
     * @notice Reduces leverage to reach target ratio
     * @dev Unstakes and repays debt to reduce position
     */
    function _reduceLeverage(PositionMetrics memory metrics, uint256 targetRatio) internal {
        uint256 targetDebt = metrics.underlyingValue.mulDivDown(targetRatio, BASIS_POINTS_SCALE);
        uint256 excessDebt = metrics.totalDebtBalance - targetDebt;
        
        if (excessDebt > 0) {
            uint256 collateralToUnstake = _calculateCollateralNeededForDebt(excessDebt);
            _unstakeSpecificAmount(collateralToUnstake);
            _repayBorrowedAmount(excessDebt);
        }
    }

    /**
     * @notice Claims rewards from staking protocol
     * @dev Interacts with external reward system
     * @return rewardsHarvested Amount of rewards claimed
     */
    function _claimStakingRewards() internal returns (uint256 rewardsHarvested) {
        uint256 rewardsBefore = baseAsset.balanceOf(address(this));
        
        // Attempt to claim rewards
        (bool success,) = yieldProtocol.call(
            abi.encodeWithSignature("harvestRewards()")
        );
        
        if (success) {
            uint256 rewardsAfter = baseAsset.balanceOf(address(this));
            rewardsHarvested = rewardsAfter - rewardsBefore;
        }
    }

    /**
     * @notice Repays borrowed amount to lending market
     * @dev Reduces debt position
     * @param repayAmount Amount of HYPE to repay
     */
    function _repayBorrowedAmount(uint256 repayAmount) internal {
        if (repayAmount == 0) return;
        
        baseAsset.safeApprove(borrowingMarket, repayAmount);
        
        (bool success,) = borrowingMarket.call(
            abi.encodeWithSignature("repayBorrow(address,uint256)", address(baseAsset), repayAmount)
        );
        require(success, "Debt repayment failed");
    }

    /**
     * @notice Unstakes specific amount of stHYPE
     * @dev Converts stHYPE back to HYPE
     * @param unstakeAmount Amount of stHYPE to unstake
     */
    function _unstakeSpecificAmount(uint256 unstakeAmount) internal {
        if (unstakeAmount == 0) return;
        
        (bool success,) = yieldProtocol.call(
            abi.encodeWithSignature("unstake(uint256)", unstakeAmount)
        );
        require(success, "Unstaking failed");
    }

    /**
     * @notice Unstakes all held stHYPE tokens
     * @dev Emergency function to convert all stHYPE to HYPE
     */
    function _unstakeAllTokens() internal {
        uint256 totalStaked = stakedAsset.balanceOf(address(this));
        if (totalStaked > 0) {
            _unstakeSpecificAmount(totalStaked);
        }
    }

    /**
     * @notice Borrows additional HYPE from lending market
     * @dev Used for leverage adjustments
     * @param borrowAmount Additional amount to borrow
     */
    function _borrowAdditionalAmount(uint256 borrowAmount) internal {
        if (borrowAmount == 0) return;
        
        (bool success,) = borrowingMarket.call(
            abi.encodeWithSignature("borrowMore(address,uint256)", address(baseAsset), borrowAmount)
        );
        require(success, "Additional borrowing failed");
    }

    /**
     * @notice Withdraws collateral from lending market
     * @dev Retrieves stHYPE collateral for unwinding
     * @param withdrawAmount Amount of collateral to withdraw
     */
    function _withdrawLendingCollateral(uint256 withdrawAmount) internal {
        if (withdrawAmount == 0) return;
        
        (bool success,) = borrowingMarket.call(
            abi.encodeWithSignature("withdrawCollateral(address,uint256)", address(stakedAsset), withdrawAmount)
        );
        require(success, "Collateral withdrawal failed");
    }

    //==================================================================================
    // PUBLIC VIEW FUNCTIONS
    //==================================================================================

    /**
     * @notice Returns user's HYPE balance equivalent
     * @param user User address to query
     * @return balance HYPE amount user owns
     */
    function getUserBalance(address user) external view returns (uint256 balance) {
        return userShareBalance[user]; // 1:1 mapping with original deposits
    }

    /**
     * @notice Returns user's share count
     * @param user User address to query
     * @return shares Number of vault shares owned
     */
    function getUserShares(address user) external view returns (uint256 shares) {
        return userShareBalance[user];
    }

    //=============================================================================
    // POSITION ANALYTICS & METRICS
    //=============================================================================

    /**
     * @notice Provides comprehensive position metrics
     * @dev Calculates all relevant position data for monitoring
     * @return metrics Current position metrics
     */
    function getCurrentMetrics() public view returns (PositionMetrics memory metrics) {
        // Calculate total stHYPE holdings (direct + collateral)
        uint256 directStaked = stakedAsset.balanceOf(address(this));
        uint256 lendingCollateral = _getCollateralInLending();
        
        metrics.totalStakedBalance = directStaked + lendingCollateral;
        
        // Get underlying value of all staked assets
        metrics.underlyingValue = _getStakedAssetValue(metrics.totalStakedBalance);
        
        // Get current debt position
        metrics.totalDebtBalance = _getCurrentDebtBalance();
        
        // Calculate leverage ratio
        if (metrics.underlyingValue > 0) {
            metrics.leverageRatio = metrics.totalDebtBalance.mulDivDown(BASIS_POINTS_SCALE, metrics.underlyingValue);
        }
        
        // Calculate position values
        metrics.grossPositionValue = metrics.underlyingValue;
        metrics.netEquityValue = metrics.underlyingValue > metrics.totalDebtBalance 
            ? metrics.underlyingValue - metrics.totalDebtBalance 
            : 0;
    }

    /**
     * @notice Calculates value of stHYPE in HYPE terms
     * @dev Uses staking protocol's exchange rate
     * @param stakedAmount Amount of stHYPE to value
     * @return value Equivalent HYPE value
     */
    function _getStakedAssetValue(uint256 stakedAmount) internal view returns (uint256 value) {
        if (stakedAmount == 0) return 0;
        
        // Query staking protocol for current exchange rate
        (bool success, bytes memory data) = yieldProtocol.staticcall(
            abi.encodeWithSignature("getAssetValue(uint256)", stakedAmount)
        );
        
        if (success && data.length >= 32) {
            value = abi.decode(data, (uint256));
        } else {
            revert VedaVault__PriceOracleFailure();
        }
    }

    /**
     * @notice Gets current debt balance from lending market
     * @dev Queries lending protocol for outstanding debt
     * @return debtBalance Current HYPE debt amount
     */
    function _getCurrentDebtBalance() internal view returns (uint256 debtBalance) {
        (bool success, bytes memory data) = borrowingMarket.staticcall(
            abi.encodeWithSignature("getDebtBalance(address,address)", address(this), address(baseAsset))
        );
        
        if (success && data.length >= 32) {
            debtBalance = abi.decode(data, (uint256));
        }
    }

    /**
     * @notice Gets stHYPE collateral held in lending market
     * @dev Queries amount of stHYPE deposited as collateral
     * @return collateralBalance Amount of stHYPE in lending protocol
     */
    function _getCollateralInLending() internal view returns (uint256 collateralBalance) {
        (bool success, bytes memory data) = borrowingMarket.staticcall(
            abi.encodeWithSignature("getCollateralBalance(address,address)", address(this), address(stakedAsset))
        );
        
        if (success && data.length >= 32) {
            collateralBalance = abi.decode(data, (uint256));
        }
    }

    /**
     * @notice Calculates collateral equivalent for debt amount
     * @dev Helper for leverage calculations
     * @param debtAmount HYPE debt amount
     * @return collateralAmount Required stHYPE collateral
     */
    function _calculateCollateralNeededForDebt(uint256 debtAmount) internal view returns (uint256 collateralAmount) {
        // Simplified calculation - accounts for target leverage ratio
        collateralAmount = debtAmount.mulDivDown(BASIS_POINTS_SCALE, strategyConfig.targetLeverageRatio);
    }

    /**
     * @notice Calculates strategy health as percentage (0-100)
     * @dev Higher values indicate safer positions
     * @return healthPercentage Health score from 0 to 100
     */
    function getStrategyHealth() external view returns (uint256 healthPercentage) {
        PositionMetrics memory metrics = getCurrentMetrics();
        
        if (metrics.underlyingValue == 0) return 100;
        
        // Health decreases as leverage approaches maximum safe level
        if (metrics.leverageRatio >= strategyConfig.maxSafeLeverageRatio) return 0;
        
        uint256 safetyBuffer = strategyConfig.maxSafeLeverageRatio - metrics.leverageRatio;
        healthPercentage = safetyBuffer.mulDivDown(100, strategyConfig.maxSafeLeverageRatio);
    }

    /**
     * @notice Checks if position requires rebalancing
     * @dev Compares current leverage to target parameters
     * @return needsRebalance True if rebalancing recommended
     */
    function requiresRebalancing() external view returns (bool needsRebalance) {
        PositionMetrics memory metrics = getCurrentMetrics();
        uint256 targetRatio = strategyConfig.targetLeverageRatio;
        uint256 threshold = strategyConfig.rebalanceTrigger;
        
        needsRebalance = metrics.leverageRatio > targetRatio + threshold || 
                        metrics.leverageRatio < targetRatio - threshold;
    }

    //=============================================================================
    // FEE MANAGEMENT
    //=============================================================================

    /**
     * @notice Allows authorized accounts to collect protocol fees
     * @dev Transfers accumulated fees to caller
     */
    function withdrawProtocolFees() external requiresAuth {
        uint256 feeAmount = pendingProtocolFees;
        if (feeAmount > 0) {
            pendingProtocolFees = 0;
            baseAsset.safeTransfer(msg.sender, feeAmount);
        }
    }
}



















