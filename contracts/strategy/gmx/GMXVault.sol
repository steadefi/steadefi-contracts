// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWNT } from  "../../interfaces/tokens/IWNT.sol";
import { IGMXVault } from  "../../interfaces/strategy/gmx/IGMXVault.sol";
import { IGMXVaultEvents } from  "../../interfaces/strategy/gmx/IGMXVaultEvents.sol";
import { ILendingVault } from  "../../interfaces/lending/ILendingVault.sol";
import { IChainlinkOracle } from  "../../interfaces/oracles/IChainlinkOracle.sol";
import { IGMXOracle } from  "../../interfaces/oracles/IGMXOracle.sol";
import { IExchangeRouter } from "../../interfaces/protocols/gmx/IExchangeRouter.sol";
import { ISwap } from "../../interfaces/swap/ISwap.sol";
import { Errors } from  "../../utils/Errors.sol";
import { GMXTypes } from  "./GMXTypes.sol";
import { GMXDeposit } from  "./GMXDeposit.sol";
import { GMXWithdraw } from  "./GMXWithdraw.sol";
import { GMXRebalance } from  "./GMXRebalance.sol";
import { GMXCompound } from  "./GMXCompound.sol";
import { GMXEmergency } from  "./GMXEmergency.sol";
import { GMXReader } from  "./GMXReader.sol";
import { GMXChecks } from "./GMXChecks.sol";

/**
  * @title GMXVault
  * @author Steadefi
  * @notice Main point of interaction with a Steadefi leveraged strategy vault
*/
contract GMXVault is ERC20, AccessManaged, ReentrancyGuard, IGMXVault, IGMXVaultEvents {

  using SafeERC20 for IERC20;

  /* ==================== STATE VARIABLES ==================== */

  // GMXTypes.Store
  GMXTypes.Store internal _store;

  /* ======================= MODIFIERS ======================= */

  // Allow only vault modifier
  modifier onlyVault() {
    _onlyVault();
    _;
  }

  // Allow only vault's callback contract
  modifier onlyCallback() {
    _onlyCallback();
    _;
  }

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @notice Initialize and configure vault's store, token approvals and whitelists
    * @param _name Name of vault
    * @param _symbol Symbol for vault token
    * @param _accessManager Address of access manager
    * @param store_ GMXTypes.Store
  */
  constructor (
    string memory _name,
    string memory _symbol,
    address _accessManager,
    GMXTypes.Store memory store_
  ) ERC20(_name, _symbol) AccessManaged(_accessManager) {
    _store.status = GMXTypes.Status.Open;
    _store.shouldEmergencyPause = false;

    _store.lpAmt = uint256(0);

    _store.lastFeeCollected = block.timestamp;
    _store.keeper = payable(address(store_.keeper));

    _store.leverage = uint256(store_.leverage);
    _store.delta = store_.delta;
    _store.feePerSecond = uint256(store_.feePerSecond);
    _store.treasury = address(store_.treasury);

    _store.debtRatioStepThreshold = uint256(store_.debtRatioStepThreshold);
    _store.debtRatioUpperLimit = uint256(store_.debtRatioUpperLimit);
    _store.debtRatioLowerLimit = uint256(store_.debtRatioLowerLimit);
    _store.deltaUpperLimit = int256(store_.deltaUpperLimit);
    _store.deltaLowerLimit = int256(store_.deltaLowerLimit);
    _store.minVaultSlippage = uint256(store_.minVaultSlippage);
    _store.liquiditySlippage = uint256(store_.liquiditySlippage);
    _store.swapSlippage = uint256(store_.swapSlippage);
    _store.callbackGasLimit = uint256(store_.callbackGasLimit);
    _store.minAssetValue = uint256(store_.minAssetValue);
    _store.maxAssetValue = uint256(store_.maxAssetValue);

    _store.tokenA = IERC20(store_.tokenA);
    _store.tokenB = IERC20(store_.tokenB);
    _store.lpToken = IERC20(store_.lpToken);
    _store.WNT = IWNT(store_.WNT);
    _store.rewardToken = IERC20(store_.rewardToken);

    // Note that for Delta Long, tokenALendingVault can be address(0)
    _store.tokenALendingVault = ILendingVault(store_.tokenALendingVault);
    // Note that for Delta Short, tokenBLendingVault can be address(0)
    _store.tokenBLendingVault = ILendingVault(store_.tokenBLendingVault);

    _store.vault = IGMXVault(address(this));
    _store.callback = store_.callback;

    _store.chainlinkOracle = IChainlinkOracle(store_.chainlinkOracle);
    _store.gmxOracle = IGMXOracle(store_.gmxOracle);

    _store.exchangeRouter = IExchangeRouter(store_.exchangeRouter);
    _store.router = store_.router;
    _store.depositVault = store_.depositVault;
    _store.withdrawalVault = store_.withdrawalVault;
    _store.roleStore = store_.roleStore;

    _store.swapRouter = ISwap(store_.swapRouter);

    // Set token approvals for this vault
    _store.tokenA.approve(address(_store.router), type(uint256).max);
    _store.tokenB.approve(address(_store.router), type(uint256).max);
    _store.lpToken.approve(address(_store.router), type(uint256).max);

    _store.tokenA.approve(address(_store.depositVault), type(uint256).max);
    _store.tokenB.approve(address(_store.depositVault), type(uint256).max);

    _store.lpToken.approve(address(_store.withdrawalVault), type(uint256).max);

    _store.tokenA.approve(address(_store.tokenALendingVault), type(uint256).max);
    _store.tokenB.approve(address(_store.tokenBLendingVault), type(uint256).max);
  }

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice View vault store data
    * @return GMXTypes.Store
  */
  function store() public view returns (GMXTypes.Store memory) {
    return _store;
  }

  /**
    * @notice Returns the value of each strategy vault share token; equityValue / totalSupply()
    * @return svTokenValue  USD value of each share token in 1e18
  */
  function svTokenValue() public view returns (uint256) {
    return GMXReader.svTokenValue(_store);
  }

  /**
    * @notice Amount of share pending for minting as a form of management fee
    * @return pendingFee in 1e18
  */
  function pendingFee() public view returns (uint256) {
    return GMXReader.pendingFee(_store);
  }

  /**
    * @notice Conversion of equity value to svToken shares
    * @param value Equity value change after deposit in 1e18
    * @param currentEquity Current equity value of vault in 1e18
    * @return sharesAmt in 1e18
  */
  function valueToShares(uint256 value, uint256 currentEquity) public view returns (uint256) {
    return GMXReader.valueToShares(_store, value, currentEquity);
  }

  /**
    * @notice Convert token amount to USD value using price from oracle
    * @param token Token address
    * @param amt Amount in token decimals
    @ @return tokenValue USD value in 1e18
  */
  function convertToUsdValue(address token, uint256 amt) public view returns (uint256) {
    return GMXReader.convertToUsdValue(_store, token, amt);
  }

  /**
    * @notice Return token weights (%) in LP
    @ @return tokenAWeight in 1e18; e.g. 50% = 5e17
    @ @return tokenBWeight in 1e18; e.g. 50% = 5e17
  */
  function tokenWeights() public view returns (uint256, uint256) {
    return GMXReader.tokenWeights(_store);
  }

  /**
    * @notice Returns the total USD value of tokenA & tokenB assets held by the vault
    * @notice Asset = Debt + Equity
    * @return assetValue USD value of total assets in 1e18
  */
  function assetValue() public view returns (uint256) {
    return GMXReader.assetValue(_store);
  }

  /**
    * @notice Returns the USD value of tokenA & tokenB debt held by the vault
    * @notice Asset = Debt + Equity
    * @return tokenADebtValue USD value of tokenA debt in 1e18
    * @return tokenBDebtValue USD value of tokenB debt in 1e18
  */
  function debtValue() public view returns (uint256, uint256) {
    return GMXReader.debtValue(_store);
  }

  /**
    * @notice Returns the USD value of tokenA & tokenB equity held by the vault;
    * @notice Asset = Debt + Equity
    * @return equityValue USD value of total equity in 1e18
  */
  function equityValue() public view returns (uint256) {
    return GMXReader.equityValue(_store);
  }

  /**
    * @notice Returns the amt of tokenA & tokenB assets held by vault
    * @return tokenAAssetAmt in tokenA decimals
    * @return tokenBAssetAmt in tokenB decimals
  */
  function assetAmt() public view returns (uint256, uint256) {
    return GMXReader.assetAmt(_store);
  }

  /**
    * @notice Returns the amt of tokenA & tokenB debt held by vault
    * @return tokenADebtAmt in tokenA decimals
    * @return tokenBDebtAmt in tokenB decimals
  */
  function debtAmt() public view returns (uint256, uint256) {
    return GMXReader.debtAmt(_store);
  }

  /**
    * @notice Returns the amt of LP tokens held by vault
    * @return lpAmt in 1e18
  */
  function lpAmt() public view returns (uint256) {
    return GMXReader.lpAmt(_store);
  }

  /**
    * @notice Returns the current leverage (asset / equity)
    * @return leverage Current leverage in 1e18
  */
  function leverage() public view returns (uint256) {
    return GMXReader.leverage(_store);
  }

  /**
    * @notice Returns the current delta (tokenA equityValue / vault equityValue)
    * @notice Delta refers to the position exposure of this vault's strategy to the
    * underlying volatile asset. Delta can be a negative value
    * @return delta in 1e18 (0 = Neutral, > 0 = Long, < 0 = Short)
  */
  function delta() public view returns (int256) {
    return GMXReader.delta(_store);
  }

  /**
    * @notice Returns the debt ratio (tokenA and tokenB debtValue) / (total assetValue)
    * @notice When assetValue is 0, we assume the debt ratio to also be 0
    * @return debtRatio % in 1e18
  */
  function debtRatio() public view returns (uint256) {
    return GMXReader.debtRatio(_store);
  }

  /**
    * @notice Additional capacity vault that can be deposited to vault based on available lending liquidity
    @ @return additionalCapacity USD value in 1e18
  */
  function additionalCapacity() public view returns (uint256) {
    return GMXReader.additionalCapacity(_store);
  }

  /**
    * @notice Total capacity of vault; additionalCapacity + equityValue
    @ @return capacity USD value in 1e18
  */
  function capacity() public view returns (uint256) {
    return GMXReader.capacity(_store);
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Deposit asset into vault and mint strategy vault share tokens to user
    * @param dp GMXTypes.DepositParams
  */
  function deposit(GMXTypes.DepositParams memory dp) external payable nonReentrant {
    GMXDeposit.deposit(_store, dp, false);
  }

  /**
    * @notice Deposit native asset (e.g. ETH) into vault and mint strategy vault share tokens to user
    * @notice This function is only function if vault accepts native token
    * @param dp GMXTypes.DepositParams
  */
  function depositNative(GMXTypes.DepositParams memory dp) external payable nonReentrant {
    GMXDeposit.deposit(_store, dp, true);
  }

  /**
    * @notice Withdraws asset from vault and burns strategy vault share tokens from user
    * @param wp GMXTypes.WithdrawParams
  */
  function withdraw(GMXTypes.WithdrawParams memory wp) external payable nonReentrant {
    GMXWithdraw.withdraw(_store, wp);
  }

  /**
    * @notice Emergency withdraw function, enabled only when vault status is Closed, burns
    svToken from user while withdrawing assets from vault to user
    * @param shareAmt Amount of vault token shares to withdraw in 1e18
  */
  function emergencyWithdraw(uint256 shareAmt) external nonReentrant {
    GMXEmergency.emergencyWithdraw(_store, shareAmt);
  }

  /* ================== INTERNAL FUNCTIONS =================== */

  /**
    * @notice Allow only vault
  */
  function _onlyVault() internal view {
    if (msg.sender != address(_store.vault)) revert Errors.OnlyVaultAllowed();
  }

  /**
    * @notice Allow only vault callback contract
  */
  function _onlyCallback() internal view {
    if (msg.sender != address(_store.callback)) revert Errors.OnlyCallbackAllowed();
  }

  /* ================= RESTRICTED FUNCTIONS ================== */

  /**
    * @notice Post deposit operations if adding liquidity is successful to GMX
    * @dev Should be called only after deposit() / depositNative() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param lpAmtReceived Amount of LP tokens received
  */
  function processDeposit(uint256 lpAmtReceived) external nonReentrant restricted {
    GMXDeposit.processDeposit(_store, lpAmtReceived);
  }

  /**
    * @notice Post deposit operations if adding liquidity has been cancelled by GMX
    * @dev To be called only after deposit()/depositNative() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processDepositCancellation() external nonReentrant restricted {
    GMXDeposit.processDepositCancellation(_store);
  }

  /**
    * @notice Post deposit operations if after deposit checks failed by GMXChecks.afterDepositChecks()
    * @dev Should be called by approved Keeper after error event is picked up
    * @param executionFee Execution fee passed in to remove liquidity
  */
  function processDepositFailure(
    uint256 executionFee
  ) external payable nonReentrant restricted {
    GMXDeposit.processDepositFailure(_store, executionFee);
  }

  /**
    * @notice Post deposit failure operations
    * @dev To be called after processDepositFailure()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param tokenAReceived Amount of tokenA received
    * @param tokenBReceived Amount of tokenB received
  */
  function processDepositFailureLiquidityWithdrawal(
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) external nonReentrant restricted {
    GMXDeposit.processDepositFailureLiquidityWithdrawal(_store, tokenAReceived, tokenBReceived);
  }

  /**
    * @notice Post withdraw operations if removing liquidity is successful from GMX
    * @dev Should be called only after withdraw() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param tokenAReceived Amount of tokenA received
    * @param tokenBReceived Amount of tokenB received
  */
  function processWithdraw(
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) external nonReentrant restricted {
    GMXWithdraw.processWithdraw(_store, tokenAReceived, tokenBReceived);
  }

  /**
    * @notice Post withdraw operations if removing liquidity has been cancelled by GMX
    * @dev To be called only after withdraw() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processWithdrawCancellation() external nonReentrant restricted {
    GMXWithdraw.processWithdrawCancellation(_store);
  }

  /**
    * @notice Post withdraw operations if after withdraw checks failed by GMXChecks.afterWithdrawChecks()
    * @dev Should be called by approved Keeper after error event is picked up
    * @param executionFee Execution fee passed in for adding liquidity
  */
  function processWithdrawFailure(
    uint256 executionFee
  ) external payable nonReentrant restricted {
    GMXWithdraw.processWithdrawFailure(_store, executionFee);
  }

  /**
    * @notice Post withdraw failure operations
    * @dev To be called after processWithdrawFailure()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param lpAmtReceived Amount of LP tokens received
  */
  function processWithdrawFailureLiquidityAdded(
    uint256 lpAmtReceived
  ) external nonReentrant restricted {
    GMXWithdraw.processWithdrawFailureLiquidityAdded(_store, lpAmtReceived);
  }

  /**
    * @notice Rebalance vault's delta and/or debt ratio by adding liquidity
    * @dev Should be called by approved Keeper
    * @param rap GMXTypes.RebalanceAddParams
  */
  function rebalanceAdd(
    GMXTypes.RebalanceAddParams memory rap
  ) external payable nonReentrant restricted {
    GMXRebalance.rebalanceAdd(_store, rap);
  }

  /**
    * @notice Post rebalance add operations if adding liquidity is successful to GMX
    * @dev To be called after rebalanceAdd()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param lpAmtReceived Amount of LP tokens received
  */
  function processRebalanceAdd(uint256 lpAmtReceived) external nonReentrant restricted {
    GMXRebalance.processRebalanceAdd(_store, lpAmtReceived);
  }

  /**
    * @notice Post rebalance add operations if adding liquidity has been cancelled by GMX
    * @dev To be called only after rebalanceAdd() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processRebalanceAddCancellation() external nonReentrant restricted {
    GMXRebalance.processRebalanceAddCancellation(_store);
  }

  /**
    * @notice Rebalance vault's delta and/or debt ratio by removing liquidity
    * @dev Should be called by approved Keeper
    * @param rrp GMXTypes.RebalanceRemoveParams
  */
  function rebalanceRemove(
    GMXTypes.RebalanceRemoveParams memory rrp
  ) external payable nonReentrant restricted {
    GMXRebalance.rebalanceRemove(_store, rrp);
  }

  /**
    * @notice Post rebalance remove operations if removing liquidity is successful to GMX
    * @dev To be called after rebalanceRemove()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param tokenAReceived Amount of tokenA received
    * @param tokenBReceived Amount of tokenB received
  */
  function processRebalanceRemove(
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) external nonReentrant restricted {
    GMXRebalance.processRebalanceRemove(_store, tokenAReceived, tokenBReceived);
  }

  /**
    * @notice Post rebalance remove operations if removing liquidity has been cancelled by GMX
    * @dev To be called only after rebalanceRemove() is called
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processRebalanceRemoveCancellation() external nonReentrant restricted {
    GMXRebalance.processRebalanceRemoveCancellation(_store);
  }

  /**
    * @notice Set vault status to Open from Rebalance_Open status
    * @dev To be called when it is not possible to rebalance further due to lack of lending liquidity
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function rebalanceClose() external restricted {
    GMXRebalance.rebalanceClose(_store);
  }

  /**
    * @notice Compounds ERC20 token rewards and convert to more LP
    * @dev Assumes that reward tokens are already in vault
    * @dev Always assume that we will do a swap
    * @dev Should be called by approved Keeper
    * @param cp GMXTypes.CompoundParams
  */
  function compound(
    GMXTypes.CompoundParams memory cp
  ) external payable nonReentrant restricted {
    GMXCompound.compound(_store, cp);
  }

  /**
    * @notice Post compound operations if adding liquidity is successful to GMX
    * @dev To be called after processCompound()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param lpAmtReceived Amount of LP tokens received
  */
  function processCompound(uint256 lpAmtReceived) external nonReentrant restricted {
    GMXCompound.processCompound(_store, lpAmtReceived);
  }

  /**
    * @notice Post compound operations if adding liquidity has been cancelled by GMX
    * @dev To be called after processCompound()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processCompoundCancellation() external nonReentrant restricted {
    GMXCompound.processCompoundCancellation(_store);
  }

  /**
    * @notice Compound LP tokens if vault has excess LP balance
    * @dev Assumes that LP tokens are already in vault and in excess of tracked lpAmt
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function compoundLP() external restricted {
    GMXCompound.compoundLP(_store);
  }

  /**
    * @notice Set vault status to Paused
    * @dev To be called only in an emergency situation. Paused will be queued if vault is
    * in any status besides Open
    * @dev Cannot be called if vault status is already in Paused, Resume, Repaid or Closed
    * @dev Should be called by approved Keeper
  */
  function emergencyPause() external nonReentrant restricted {
    GMXEmergency.emergencyPause(_store);
  }

  /**
    * @notice Withdraws LP for all underlying assets to vault, repays all debt owed by vault
    * and set vault status to Repaid
    * @dev To be called only in an emergency situation and when vault status is Paused
    * @dev Can only be called if vault status is Paused
    * @dev Should be called by approved Keeper
  */
  function emergencyRepay() external payable nonReentrant restricted {
    GMXEmergency.emergencyRepay(_store);
  }

  /**
    * @notice Post emergency repay operations to swap if needed and repay debt
    * @dev To be called after emergencyRepay()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param tokenAReceived Amount of tokenA received
    * @param tokenBReceived Amount of tokenB received
  */
  function processEmergencyRepay(
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) external nonReentrant restricted {
    GMXEmergency.processEmergencyRepay(_store, tokenAReceived, tokenBReceived);
  }

  /**
    * @notice Re-borrow assets to vault's strategy based on value of assets in vault and
    * set status of vault back to Paused
    * @dev Can only be called if vault status is Repaid
    * @dev Should be called by approved Keeper
  */
  function emergencyBorrow() external nonReentrant restricted {
    GMXEmergency.emergencyBorrow(_store);
  }

  /**
    * @notice Re-add all assets for liquidity for LP in anticipation of vault resuming
    * @dev Can only be called if vault status is Paused
    * @dev Should be called by approved Owner (Timelock + MultiSig)
  */
  function emergencyResume() external payable nonReentrant restricted {
    GMXEmergency.emergencyResume(_store);
  }

  /**
    * @notice Post emergency resume operations if re-adding liquidity is successful
    * @dev To be called after emergencyResume()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
    * @param lpAmtReceived Amount of LP tokens received
  */
  function processEmergencyResume(uint256 lpAmtReceived) external nonReentrant restricted {
    GMXEmergency.processEmergencyResume(_store, lpAmtReceived);
  }

  /**
    * @notice Post emergency resume operations if re-adding liquidity has been cancelled by GMX
    * @dev To be called after emergencyResume()
    * @dev Should be called by approved vault's Keeper from event emitted from GMX callback
  */
  function processEmergencyResumeCancellation() external nonReentrant restricted {
    GMXEmergency.processEmergencyResumeCancellation(_store);
  }

  /**
    * @notice Permanently shut down vault, allowing emergency withdrawals and sets vault
    * status to Closed
    * @dev Can only be called if vault status is Repaid
    * @dev Note that this is a one-way irreversible action
    * @dev Should be called by approved Owner (Timelock + MultiSig)
  */
  function emergencyClose() external nonReentrant restricted {
    GMXEmergency.emergencyClose(_store);
  }

    /**
    * @notice Emergency update of vault status
    * @dev Can only be called if emergency pause is triggered but vault status is not Paused
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param status GMXTypes.Status
  */
  function emergencyStatusChange(GMXTypes.Status status) external restricted {
    GMXEmergency.emergencyStatusChange(_store, status);
  }

  /**
    * @notice Update keeper address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param keeper Keeper address
  */
  function updateKeeper(address keeper) external restricted {
    _store.keeper = payable(keeper);
    emit KeeperUpdated(keeper);
  }

  /**
    * @notice Update treasury address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param treasury Treasury address
  */
  function updateTreasury(address treasury) external restricted {
    _store.treasury = treasury;
    emit TreasuryUpdated(treasury);
  }

  /**
    * @notice Update swap router address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param swapRouter Swap router address
  */
  function updateSwapRouter(address swapRouter) external restricted {
    _store.swapRouter = ISwap(swapRouter);
    emit SwapRouterUpdated(swapRouter);
  }

  /**
    * @notice Update reward token address
    * @dev Should only be called when reward token has changed
    * @param rewardToken Reward token address
  */
  function updateRewardToken(address rewardToken) external restricted {
    _store.rewardToken = IERC20(rewardToken);
    emit RewardTokenUpdated(rewardToken);
  }

  /**
    * @notice Update lending vaults addresses
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @dev tokenALendingVault can be address(0) for Delta Long
    * @dev tokenBLendingVault can be address(0) for Delta Short
    * @dev We allow tokenLendingVaults to be address(0) to reduce the borrowers array length
    * in the lending vaults itself to reduce gas costs for all borrow/repay in the lending vault
    * @param newTokenALendingVault TokenA lending vault address
    * @param newTokenBLendingVault TokenB lending vault address
  */
  function updateLendingVaults(
    address newTokenALendingVault,
    address newTokenBLendingVault
  ) external restricted {
    _store.tokenALendingVault = ILendingVault(newTokenALendingVault);
    _store.tokenBLendingVault = ILendingVault(newTokenBLendingVault);

    _store.tokenA.approve(address(_store.tokenALendingVault), type(uint256).max);
    _store.tokenB.approve(address(_store.tokenBLendingVault), type(uint256).max);

    emit LendingVaultsUpdated(newTokenALendingVault, newTokenBLendingVault);
  }

  /**
    * @notice Update callback address
    * @dev Should only be called once on vault initialization
    * @param callback Callback address
  */
  function updateCallback(address callback) external restricted {
    _store.callback = callback;
    emit CallbackUpdated(callback);
  }

  /**
    * @notice Update management fee per second
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param feePerSecond Fee per second in 1e18
  */
  function updateFeePerSecond(uint256 feePerSecond) external restricted {
    _store.vault.mintFee();
    _store.feePerSecond = feePerSecond;
    emit FeePerSecondUpdated(feePerSecond);
  }

  /**
    * @notice Update strategy leverage, parameter limits and guard checks
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param newLeverage Strategy's leverage in 1e18
    * @param debtRatioStepThreshold Threshold change for debt ratio allowed in 1e4
    * @param debtRatioUpperLimit Upper limit of debt ratio in 1e18
    * @param debtRatioLowerLimit Lower limit of debt ratio in 1e18
    * @param deltaUpperLimit Upper limit of delta in 1e18
    * @param deltaLowerLimit Lower limit of delta in 1e18
  */
  function updateParameterLimits(
    uint256 newLeverage,
    uint256 debtRatioStepThreshold,
    uint256 debtRatioUpperLimit,
    uint256 debtRatioLowerLimit,
    int256 deltaUpperLimit,
    int256 deltaLowerLimit
  ) external restricted {
    _store.leverage = newLeverage;
    _store.debtRatioStepThreshold = debtRatioStepThreshold;
    _store.debtRatioUpperLimit = debtRatioUpperLimit;
    _store.debtRatioLowerLimit = debtRatioLowerLimit;
    _store.deltaUpperLimit = deltaUpperLimit;
    _store.deltaLowerLimit = deltaLowerLimit;

    emit ParameterLimitsUpdated(
      newLeverage,
      debtRatioStepThreshold,
      debtRatioUpperLimit,
      debtRatioLowerLimit,
      deltaUpperLimit,
      deltaLowerLimit
    );
  }

  /**
    * @notice Update minimum vault slippage
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param minVaultSlippage Minimum slippage value in 1e4
  */
  function updateMinVaultSlippage(uint256 minVaultSlippage) external restricted {
    _store.minVaultSlippage = minVaultSlippage;
    emit MinVaultSlippageUpdated(minVaultSlippage);
  }

  /**
    * @notice Update vault's liquidity slippage
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param liquiditySlippage Minimum slippage value in 1e4
  */
  function updateLiquiditySlippage(uint256 liquiditySlippage) external restricted {
    _store.liquiditySlippage = liquiditySlippage;
    emit LiquiditySlippageUpdated(liquiditySlippage);
  }

  /**
    * @notice Update vault's swap slippage
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param swapSlippage Minimum slippage value in 1e4
  */
  function updateSwapSlippage(uint256 swapSlippage) external restricted {
    _store.swapSlippage = swapSlippage;
    emit SwapSlippageUpdated(swapSlippage);
  }

  /**
    * @notice Update callback gas limit
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param callbackGasLimit Minimum slippage value in 1e4
  */
  function updateCallbackGasLimit(uint256 callbackGasLimit) external restricted {
    _store.callbackGasLimit = callbackGasLimit;
    emit CallbackGasLimitUpdated(callbackGasLimit);
  }

  /**
    * @notice Update Chainlink oracle contract address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of chainlink oracle
  */
  function updateChainlinkOracle(address addr) external restricted {
    _store.chainlinkOracle = IChainlinkOracle(addr);
    emit ChainlinkOracleUpdated(addr);
  }

  /**
    * @notice Update GMX oracle contract address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of GMX oracle
  */
  function updateGMXOracle(address addr) external restricted {
    _store.gmxOracle = IGMXOracle(addr);
    emit GMXOracleUpdated(addr);
  }

  /**
    * @notice Update GMX exchange router contract address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of exchange router
  */
  function updateGMXExchangeRouter(address addr) external restricted {
    _store.exchangeRouter = IExchangeRouter(addr);
    emit GMXExchangeRouterUpdated(addr);
  }

  /**
    * @notice Update GMX router contract address and approve it for token transfers
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of router
  */
  function updateGMXRouter(address addr) external restricted {
    _store.router = addr;

    _store.tokenA.approve(address(_store.router), type(uint256).max);
    _store.tokenB.approve(address(_store.router), type(uint256).max);
    _store.lpToken.approve(address(_store.router), type(uint256).max);

    emit GMXRouterUpdated(addr);
  }

  /**
    * @notice Update GMX deposit vault contract address and approve it for token transfers
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of deposit vault
  */
  function updateGMXDepositVault(address addr) external restricted {
    _store.depositVault = addr;

    _store.tokenA.approve(address(_store.depositVault), type(uint256).max);
    _store.tokenB.approve(address(_store.depositVault), type(uint256).max);

    emit GMXDepositVaultUpdated(addr);
  }

  /**
    * @notice Update GMX withdrawal vault contract address and approve it for token transfers
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of withdrawal vault
  */
  function updateGMXWithdrawalVault(address addr) external restricted {
    _store.withdrawalVault = addr;

    _store.lpToken.approve(address(_store.router), type(uint256).max);

    emit GMXWithdrawalVaultUpdated(addr);
  }

  /**
    * @notice Update GMX role store contract address
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param addr Address of role store
  */
  function updateGMXRoleStore(address addr) external restricted {
    _store.roleStore = addr;

    emit GMXRoleStoreUpdated(addr);
  }

  /**
    * @notice Update minimum asset value per vault deposit/withdrawal
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param value Minimum value
  */
  function updateMinAssetValue(uint256 value) external restricted {
    _store.minAssetValue = value;

    emit MinAssetValueUpdated(value);
  }

  /**
    * @notice Update maximum asset value per vault deposit/withdrawal
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param value Maximum value
  */
  function updateMaxAssetValue(uint256 value) external restricted {
    _store.maxAssetValue = value;

    emit MaxAssetValueUpdated(value);
  }

  /**
    * @notice Call an yet to be unknown function signature in an external contract
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @dev Contract address should NOT vault NOR any assets managed by this vault
    * @param target External contract address
    * @param signature Function signature string
    * @param args Encoded function arguments in bytes
  */
  function externalCall(
    address target,
    string memory signature,
    bytes memory args
  ) external nonReentrant restricted returns (bytes memory) {
    if (
      target == address(this) ||
      target == address(_store.tokenA) ||
      target == address(_store.tokenB) ||
      target == address(_store.lpToken) ||
      target == address(_store.WNT)
    ) revert Errors.AddressNotAllowed();

    // Construct the full call data
    bytes memory callData = abi.encodePacked(
      bytes4(keccak256(bytes(signature))),
      args
    );

    // Perform the call
    (bool success, bytes memory returnData) = target.call(callData);

    if (!success) revert Errors.ExternalCallFailed();

    return returnData;
  }

  /**
    * @notice Mint vault token shares as management fees to protocol treasury
  */
  function mintFee() public onlyVault {
    GMXChecks.beforeMintFeeChecks(_store);

    _mint(_store.treasury, GMXReader.pendingFee(_store));
    _store.lastFeeCollected = block.timestamp;

    emit FeeMinted(GMXReader.pendingFee(_store));
  }

  /**
    * @notice Mints vault token shares to user
    * @dev Should only be called by vault
    * @param to Receiver of the minted vault tokens
    * @param amt Amount of minted vault tokens
  */
  function mint(address to, uint256 amt) external onlyVault {
    _mint(to, amt);
  }

  /**
    * @notice Burns vault token shares from user
    * @dev Should only be called by vault
    * @param to Address's vault tokens to burn
    * @param amt Amount of vault tokens to burn
  */
  function burn(address to, uint256 amt) external onlyVault {
    _burn(to, amt);
  }

  /* ================== CALLBACK FUNCTIONS =================== */

  /**
    * @notice Emit a callback event
    * @dev Should only be called by vault's callback contract
    * @param callbackType GMXTypes.CallbackType
    * @param depositKey bytes32 deposit key from GMX
    * @param withdrawKey bytes32 withdraw key from GMX
    * @param lpAmtReceived LP amount received in uint256
    * @param tokenAReceived LP amount received in uint256
    * @param tokenBReceived LP amount received in uint256
  */
  function emitProcessEvent(
    GMXTypes.CallbackType callbackType,
    bytes32 depositKey,
    bytes32 withdrawKey,
    uint256 lpAmtReceived,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) external onlyCallback {
    if (callbackType == GMXTypes.CallbackType.ProcessDeposit)
      emit ProcessDeposit(depositKey, lpAmtReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessRebalanceAdd)
      emit ProcessRebalanceAdd(depositKey, lpAmtReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessCompound)
      emit ProcessCompound(depositKey, lpAmtReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessWithdrawFailureLiquidityAdded)
      emit ProcessWithdrawFailureLiquidityAdded(depositKey, lpAmtReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessEmergencyResume)
      emit ProcessEmergencyResume(depositKey, lpAmtReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessDepositCancellation)
      emit ProcessDepositCancellation(depositKey);
    if (callbackType == GMXTypes.CallbackType.ProcessRebalanceAddCancellation)
      emit ProcessRebalanceAddCancellation(depositKey);
    if (callbackType == GMXTypes.CallbackType.ProcessCompoundCancellation)
      emit ProcessCompoundCancellation(depositKey);
    if (callbackType == GMXTypes.CallbackType.ProcessEmergencyResumeCancellation)
      emit ProcessEmergencyResumeCancellation(depositKey);
    if (callbackType == GMXTypes.CallbackType.ProcessWithdraw)
      emit ProcessWithdraw(withdrawKey, tokenAReceived, tokenBReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessRebalanceRemove)
      emit ProcessRebalanceRemove(withdrawKey, tokenAReceived, tokenBReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessDepositFailureLiquidityWithdrawal)
      emit ProcessDepositFailureLiquidityWithdrawal(withdrawKey, tokenAReceived, tokenBReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessEmergencyRepay)
      emit ProcessEmergencyRepay(withdrawKey, tokenAReceived, tokenBReceived);
    if (callbackType == GMXTypes.CallbackType.ProcessWithdrawCancellation)
      emit ProcessWithdrawCancellation(withdrawKey);
    if (callbackType == GMXTypes.CallbackType.ProcessRebalanceRemoveCancellation)
      emit ProcessRebalanceRemoveCancellation(withdrawKey);
  }

  /* ================== FALLBACK FUNCTIONS =================== */

  /**
    * @notice Fallback function to receive native token sent to this contract
    * @dev To send any additional WNT received from GMX to keeper for additional callback calls
  */
  receive() external payable {
    if (msg.sender == _store.depositVault || msg.sender == _store.withdrawalVault) {
      uint256 _balance = address(this).balance;
      (bool success, ) = _store.keeper.call{value: _balance}("");
      if (!success) {
        _store.WNT.deposit{value: _balance}();
        IERC20(address(_store.WNT)).safeTransfer(_store.keeper, _balance);
      }
    }
  }
}
