// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWNT } from  "../../interfaces/tokens/IWNT.sol";
import { ILRTVault } from  "../../interfaces/strategy/lrt/ILRTVault.sol";
import { ILRTVaultEvents } from  "../../interfaces/strategy/lrt/ILRTVaultEvents.sol";
import { ILendingVault } from  "../../interfaces/lending/ILendingVault.sol";
import { IChainlinkOracle } from  "../../interfaces/oracles/IChainlinkOracle.sol";
import { ISwap } from "../../interfaces/swap/ISwap.sol";
import { Errors } from  "../../utils/Errors.sol";
import { LRTTypes } from  "./LRTTypes.sol";
import { LRTDeposit } from  "./LRTDeposit.sol";
import { LRTWithdraw } from  "./LRTWithdraw.sol";
import { LRTRebalance } from  "./LRTRebalance.sol";
import { LRTCompound } from  "./LRTCompound.sol";
import { LRTEmergency } from  "./LRTEmergency.sol";
import { LRTReader } from  "./LRTReader.sol";
import { LRTChecks } from "./LRTChecks.sol";

/**
  * @title LRTVault
  * @author Steadefi
  * @notice Main point of interaction with a Steadefi leveraged strategy vault
*/
contract LRTVault is ERC20, AccessManaged, ReentrancyGuard, ILRTVault, ILRTVaultEvents {

  using SafeERC20 for IERC20;

  /* ==================== STATE VARIABLES ==================== */

  // LRTTypes.Store
  LRTTypes.Store internal _store;

  /* ======================= MODIFIERS ======================= */

  // Allow only vault modifier
  modifier onlyVault() {
    _onlyVault();
    _;
  }

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @notice Initialize and configure vault's store, token approvals and whitelists
    * @param _name Name of vault
    * @param _symbol Symbol for vault token
    * @param _accessManager Address of access manager
    * @param store_ LRTTypes.Store
  */
  constructor (
    string memory _name,
    string memory _symbol,
    address _accessManager,
    LRTTypes.Store memory store_
  ) ERC20(_name, _symbol) AccessManaged(_accessManager) {
    _store.status = LRTTypes.Status.Open;
    _store.lrtAmt = uint256(0);
    _store.lastFeeCollected = block.timestamp;

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
    _store.swapSlippage = uint256(store_.swapSlippage);
    _store.minAssetValue = uint256(store_.minAssetValue);
    _store.maxAssetValue = uint256(store_.maxAssetValue);

    _store.tokenB = IERC20(store_.tokenB);
    _store.LRT = IERC20(store_.LRT);
    _store.WNT = IWNT(store_.WNT);
    _store.LST = IERC20(store_.LST);
    _store.USDC = IERC20(store_.USDC);
    _store.rewardToken = IERC20(store_.rewardToken);

    _store.tokenBLendingVault = ILendingVault(store_.tokenBLendingVault);

    _store.vault = ILRTVault(address(this));

    _store.chainlinkOracle = IChainlinkOracle(store_.chainlinkOracle);

    _store.swapRouter = ISwap(store_.swapRouter);

    // Set token approvals for this vault
    _store.tokenB.approve(address(_store.tokenBLendingVault), type(uint256).max);
  }

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice View vault store data
    * @return LRTTypes.Store
  */
  function store() public view returns (LRTTypes.Store memory) {
    return _store;
  }

  /**
    * @notice Returns the value of each strategy vault share token; equityValue / totalSupply()
    * @return svTokenValue  USD value of each share token in 1e18
  */
  function svTokenValue() public view returns (uint256) {
    return LRTReader.svTokenValue(_store);
  }

  /**
    * @notice Amount of share pending for minting as a form of management fee
    * @return pendingFee in 1e18
  */
  function pendingFee() public view returns (uint256) {
    return LRTReader.pendingFee(_store);
  }

  /**
    * @notice Conversion of equity value to svToken shares
    * @param value Equity value change after deposit in 1e18
    * @param currentEquity Current equity value of vault in 1e18
    * @return sharesAmt in 1e18
  */
  function valueToShares(uint256 value, uint256 currentEquity) public view returns (uint256) {
    return LRTReader.valueToShares(_store, value, currentEquity);
  }

  /**
    * @notice Convert token amount to USD value using price from oracle
    * @param token Token address
    * @param amt Amount in token decimals
    @ @return tokenValue USD value in 1e18
  */
  function convertToUsdValue(address token, uint256 amt) public view returns (uint256) {
    return LRTReader.convertToUsdValue(_store, token, amt);
  }

  /**
    * @notice Returns the total USD value of tokenB assets held by the vault
    * @notice Asset = Debt + Equity
    * @return assetValue USD value of total assets in 1e18
  */
  function assetValue() public view returns (uint256) {
    return LRTReader.assetValue(_store);
  }

  /**
    * @notice Returns the USD value of tokenB debt held by the vault
    * @notice Asset = Debt + Equity
    * @return tokenBDebtValue USD value of tokenB debt in 1e18
  */
  function debtValue() public view returns (uint256) {
    return LRTReader.debtValue(_store);
  }

  /**
    * @notice Returns the USD value of tokenB equity held by the vault;
    * @notice Asset = Debt + Equity
    * @return equityValue USD value of total equity in 1e18
  */
  function equityValue() public view returns (uint256) {
    return LRTReader.equityValue(_store);
  }

  /**
    * @notice Returns the amt of tokenB assets held by vault
    * @return tokenBAssetAmt in tokenB decimals
  */
  function assetAmt() public view returns (uint256) {
    return LRTReader.assetAmt(_store);
  }

  /**
    * @notice Returns the amt of tokenB debt held by vault
    * @return tokenBDebtAmt in tokenB decimals
  */
  function debtAmt() public view returns (uint256) {
    return LRTReader.debtAmt(_store);
  }

  /**
    * @notice Returns the amt of LRT held by vault
    * @return lrtAmt in 1e18
  */
  function lrtAmt() public view returns (uint256) {
    return LRTReader.lrtAmt(_store);
  }

  /**
    * @notice Returns the current leverage (asset / equity)
    * @return leverage Current leverage in 1e18
  */
  function leverage() public view returns (uint256) {
    return LRTReader.leverage(_store);
  }

  /**
    * @notice Returns the current delta (tokenA equityValue / vault equityValue)
    * @notice Delta refers to the position exposure of this vault's strategy to the
    * underlying volatile asset. Delta can be a negative value
    * @return delta in 1e18 (0 = Neutral, > 0 = Long, < 0 = Short)
  */
  function delta() public view returns (int256) {
    return LRTReader.delta(_store);
  }

  /**
    * @notice Returns the debt ratio (tokenA and tokenB debtValue) / (total assetValue)
    * @notice When assetValue is 0, we assume the debt ratio to also be 0
    * @return debtRatio % in 1e18
  */
  function debtRatio() public view returns (uint256) {
    return LRTReader.debtRatio(_store);
  }

  /**
    * @notice Additional capacity vault that can be deposited to vault based on available lending liquidity
    @ @return additionalCapacity USD value in 1e18
  */
  function additionalCapacity() public view returns (uint256) {
    return LRTReader.additionalCapacity(_store);
  }

  /**
    * @notice Total capacity of vault; additionalCapacity + equityValue
    @ @return capacity USD value in 1e18
  */
  function capacity() public view returns (uint256) {
    return LRTReader.capacity(_store);
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Deposit asset into vault and mint strategy vault share tokens to user
    * @param dp LRTTypes.DepositParams
  */
  function deposit(LRTTypes.DepositParams memory dp) external nonReentrant {
    LRTDeposit.deposit(_store, dp, false);
  }

  /**
    * @notice Deposit native asset (e.g. ETH) into vault and mint strategy vault share tokens to user
    * @notice This function is only function if vault accepts native token
    * @param dp LRTTypes.DepositParams
  */
  function depositNative(LRTTypes.DepositParams memory dp) external payable nonReentrant {
    LRTDeposit.deposit(_store, dp, true);
  }

  /**
    * @notice Withdraws asset from vault and burns strategy vault share tokens from user
    * @param wp LRTTypes.WithdrawParams
  */
  function withdraw(LRTTypes.WithdrawParams memory wp) external nonReentrant {
    LRTWithdraw.withdraw(_store, wp);
  }

  /**
    * @notice Emergency withdraw function, enabled only when vault status is Closed, burns
    svToken from user while withdrawing assets from vault to user
    * @param shareAmt Amount of vault token shares to withdraw in 1e18
  */
  function emergencyWithdraw(uint256 shareAmt) external nonReentrant {
    LRTEmergency.emergencyWithdraw(_store, shareAmt);
  }

  /* ================== INTERNAL FUNCTIONS =================== */

  /**
    * @notice Allow only vault
  */
  function _onlyVault() internal view {
    if (msg.sender != address(_store.vault)) revert Errors.OnlyVaultAllowed();
  }

  /* ================= RESTRICTED FUNCTIONS ================== */

  /**
    * @notice Rebalance vault's delta and/or debt ratio by adding liquidity
    * @dev Should be called by approved Keeper
    * @param rap LRTTypes.RebalanceAddParams
  */
  function rebalanceAdd(
    LRTTypes.RebalanceAddParams memory rap
  ) external nonReentrant restricted {
    LRTRebalance.rebalanceAdd(_store, rap);
  }

  /**
    * @notice Rebalance vault's delta and/or debt ratio by removing liquidity
    * @dev Should be called by approved Keeper
    * @param rrp LRTTypes.RebalanceRemoveParams
  */
  function rebalanceRemove(
    LRTTypes.RebalanceRemoveParams memory rrp
  ) external nonReentrant restricted {
    LRTRebalance.rebalanceRemove(_store, rrp);
  }

  /**
    * @notice Compounds ERC20 token rewards and convert to more LP
    * @dev Assumes that reward tokens are already in vault
    * @dev Always assume that we will do a swap
    * @dev Should be called by approved Keeper
    * @param cp LRTTypes.CompoundParams
  */
  function compound(
    LRTTypes.CompoundParams memory cp
  ) external nonReentrant restricted {
    LRTCompound.compound(_store, cp);
  }

  /**
    * @notice Compound LP tokens if vault has excess LP balance
    * @dev Assumes that LP tokens are already in vault and in excess of tracked lrtAmt
    * @dev Should be called by approved Keeper
  */
  function compoundLRT() external restricted {
    LRTCompound.compoundLRT(_store);
  }

  /**
    * @notice Set vault status to Paused
    * @dev To be called only in an emergency situation. Paused will be queued if vault is
    * in any status besides Open
    * @dev Cannot be called if vault status is already in Paused, Resume, Repaid or Closed
    * @dev Should be called by approved Keeper
  */
  function emergencyPause() external nonReentrant restricted {
    LRTEmergency.emergencyPause(_store);
  }

  /**
    * @notice Withdraws LP for all underlying assets to vault, repays all debt owed by vault
    * and set vault status to Repaid
    * @dev To be called only in an emergency situation and when vault status is Paused
    * @dev Can only be called if vault status is Paused
    * @dev Should be called by approved Keeper
  */
  function emergencyRepay() external nonReentrant restricted {
    LRTEmergency.emergencyRepay(_store);
  }

  /**
    * @notice Re-borrow assets to vault's strategy based on value of assets in vault and
    * set status of vault back to Paused
    * @dev Can only be called if vault status is Repaid
    * @dev Should be called by approved Keeper
  */
  function emergencyBorrow() external nonReentrant restricted {
    LRTEmergency.emergencyBorrow(_store);
  }

  /**
    * @notice Re-add all assets for liquidity for LP in anticipation of vault resuming
    * @dev Can only be called if vault status is Paused
    * @dev Should be called by approved Owner (Timelock + MultiSig)
  */
  function emergencyResume() external nonReentrant restricted {
    LRTEmergency.emergencyResume(_store);
  }

  /**
    * @notice Permanently shut down vault, allowing emergency withdrawals and sets vault
    * status to Closed
    * @dev Can only be called if vault status is Repaid
    * @dev Note that this is a one-way irreversible action
    * @dev Should be called by approved Owner (Timelock + MultiSig)
  */
  function emergencyClose() external nonReentrant restricted {
    LRTEmergency.emergencyClose(_store);
  }

  /**
    * @notice Emergency update of vault status
    * @dev Can only be called if emergency pause is triggered but vault status is not Paused
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param status LRTTypes.Status
  */
  function emergencyStatusChange(LRTTypes.Status status) external restricted {
    LRTEmergency.emergencyStatusChange(_store, status);
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
    * @param newTokenBLendingVault TokenB lending vault address
  */
  function updateLendingVaults(
    address newTokenBLendingVault
  ) external restricted {
    _store.tokenBLendingVault = ILendingVault(newTokenBLendingVault);

    _store.tokenB.approve(address(_store.tokenBLendingVault), type(uint256).max);

    emit LendingVaultsUpdated(newTokenBLendingVault);
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
    * @notice Update vault's swap slippage
    * @dev Should be called by approved Owner (Timelock + MultiSig)
    * @param swapSlippage Minimum slippage value in 1e4
  */
  function updateSwapSlippage(uint256 swapSlippage) external restricted {
    _store.swapSlippage = swapSlippage;
    emit SwapSlippageUpdated(swapSlippage);
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
      target == address(_store.tokenB) ||
      target == address(_store.LRT) ||
      target == address(_store.WNT) ||
      target == address(_store.LST) ||
      target == address(_store.USDC)
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
    LRTChecks.beforeMintFeeChecks(_store);

    _mint(_store.treasury, LRTReader.pendingFee(_store));
    _store.lastFeeCollected = block.timestamp;

    emit FeeMinted(LRTReader.pendingFee(_store));
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

  /* ================== FALLBACK FUNCTIONS =================== */

  /**
    * @notice Fallback function to receive native token sent to this contract
  */
  receive() external payable {}
}
