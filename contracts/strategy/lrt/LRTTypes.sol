// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWNT } from "../../interfaces/tokens/IWNT.sol";
import { ILendingVault } from "../../interfaces/lending/ILendingVault.sol";
import { ILRTVault } from "../../interfaces/strategy/lrt/ILRTVault.sol";
import { IChainlinkOracle } from "../../interfaces/oracles/IChainlinkOracle.sol";
import { ISwap } from "../../interfaces/swap/ISwap.sol";

/**
  * @title LRTTypes
  * @author Steadefi
  * @notice Re-usable library of Types struct definitions for Steadefi leveraged vaults
*/
library LRTTypes {

  /* ======================= STRUCTS ========================= */

  struct Store {
    // Status of the vault
    Status status;
    // Amount of LRT that vault accounts for as total assets
    uint256 lrtAmt;
    // Timestamp when vault last collected management fee
    uint256 lastFeeCollected;

    // Target leverage of the vault in 1e18
    uint256 leverage;
    // Delta strategy
    Delta delta;
    // Management fee per second in % in 1e18
    uint256 feePerSecond;
    // Treasury address
    address treasury;

    // Guards: change threshold for debtRatio change after deposit/withdraw
    uint256 debtRatioStepThreshold; // in 1e4; e.g. 500 = 5%
    // Guards: upper limit of debt ratio after rebalance
    uint256 debtRatioUpperLimit; // in 1e18; 69e16 = 0.69 = 69%
    // Guards: lower limit of debt ratio after rebalance
    uint256 debtRatioLowerLimit; // in 1e18; 61e16 = 0.61 = 61%
    // Guards: upper limit of delta after rebalance
    int256 deltaUpperLimit; // in 1e18; 15e16 = 0.15 = +15%
    // Guards: lower limit of delta after rebalance
    int256 deltaLowerLimit; // in 1e18; -15e16 = -0.15 = -15%
    // Guards: Minimum vault slippage for vault shares/assets in 1e4; e.g. 100 = 1%
    uint256 minVaultSlippage;
    // Slippage for swaps in 1e4; e.g. 100 = 1%
    uint256 swapSlippage;
    // Minimum asset value per vault deposit/withdrawal
    uint256 minAssetValue;
    // Maximum asset value per vault deposit/withdrawal
    uint256 maxAssetValue;

    // Token to borrow for this strategy
    IERC20 tokenB;
    // LRT of this strategy
    IERC20 LRT;
    // Native token for this chain (i.e. ETH)
    IWNT WNT;
    // LST for this chain
    IERC20 LST;
    // USDC for this chain
    IERC20 USDC;
    // Reward token (e.g. ARB)
    IERC20 rewardToken;

    // Token B lending vault
    ILendingVault tokenBLendingVault;

    // Vault address
    ILRTVault vault;

    // Chainlink Oracle contract address
    IChainlinkOracle chainlinkOracle;

    // Swap router for this vault
    ISwap swapRouter;

    // DepositCache
    DepositCache depositCache;
    // WithdrawCache
    WithdrawCache withdrawCache;
    // RebalanceCache
    RebalanceCache rebalanceCache;
    // CompoundCache
    CompoundCache compoundCache;
  }

  struct DepositCache {
    // Address of user
    address payable user;
    // Deposit value (USD) in 1e18
    uint256 depositValue;
    // Minimum amount of shares expected in 1e18
    uint256 minSharesAmt;
    // Actual amount of shares minted in 1e18
    uint256 sharesToUser;
    // Amount of LRT that vault received in 1e18
    uint256 lrtAmt;
    // DepositParams
    DepositParams depositParams;
    // BorrowParams
    BorrowParams borrowParams;
    // HealthParams
    HealthParams healthParams;
  }

  struct WithdrawCache {
    // Address of user
    address payable user;
    // Ratio of shares out of total supply of shares to burn
    uint256 shareRatio;
    // Amount of LRT to remove liquidity from
    uint256 lrtAmt;
    // Withdrawal value in 1e18
    uint256 withdrawValue;
    // Minimum amount of assets that user receives
    uint256 minAssetsAmt;
    // Actual amount of assets that user receives
    uint256 assetsToUser;
    // Amount of tokenB that vault received in 1e18
    uint256 tokenBReceived;
    // WithdrawParams
    WithdrawParams withdrawParams;
    // RepayParams
    RepayParams repayParams;
    // HealthParams
    HealthParams healthParams;
  }

  struct CompoundCache {
    // Deposit value (USD) in 1e18
    uint256 depositValue;
    // CompoundParams
    CompoundParams compoundParams;
  }

  struct RebalanceCache {
    // RebalanceType (Delta or Debt)
    RebalanceType rebalanceType;
    // BorrowParams
    BorrowParams borrowParams;
    // LRT amount to remove in 1e18
    uint256 lrtAmtToRemove;
    // HealthParams
    HealthParams healthParams;
  }

  struct DepositParams {
    // Address of token depositing; can be tokenA, tokenB or lrt
    address token;
    // Amount of token to deposit in token decimals
    uint256 amt;
    // Slippage tolerance for swaps; e.g. 3 = 0.03%
    uint256 slippage;
    // Timestamp for deadline for this transaction to complete
    uint256 deadline;
  }

  struct WithdrawParams {
    // Amount of shares to burn in 1e18
    uint256 shareAmt;
    // Slippage tolerance for removing liquidity; e.g. 3 = 0.03%
    uint256 slippage;
    // Timestamp for deadline for this transaction to complete
    uint256 deadline;
  }

  struct CompoundParams {
    // Address of token in
    address tokenIn;
    // Address of token out
    address tokenOut;
    // Amount of token in
    uint256 amtIn;
    // Timestamp for deadline for this transaction to complete
    uint256 deadline;
  }

  struct RebalanceAddParams {
    // RebalanceType (Delta or Debt)
    RebalanceType rebalanceType;
    // BorrowParams
    BorrowParams borrowParams;
  }

  struct RebalanceRemoveParams {
    // RebalanceType (Delta or Debt)
    RebalanceType rebalanceType;
    // LRT amount to remove in 1e18
    uint256 lrtAmtToRemove;
  }

  struct BorrowParams {
    // Amount of tokenB to borrow in tokenB decimals
    uint256 borrowTokenBAmt;
  }

  struct RepayParams {
    // Amount of tokenB to repay in tokenB decimals
    uint256 repayTokenBAmt;
  }

  struct HealthParams {
    // LRT token balance in 1e18
    uint256 lrtAmtBefore;
    // USD value of equity in 1e18
    uint256 equityBefore;
    // Debt ratio in 1e18
    uint256 debtRatioBefore;
    // Delta in 1e18
    int256 deltaBefore;
    // USD value of equity in 1e18
    uint256 equityAfter;
    // svToken value before in 1e18
    uint256 svTokenValueBefore;
    // // svToken value after in 1e18
    uint256 svTokenValueAfter;
  }

  struct AddLiquidityParams {
    // Amount of tokenB to add liquidity
    uint256 tokenBAmt;
  }

  struct RemoveLiquidityParams {
    // Amount of LRT to remove liquidity
    uint256 lrtAmt;
  }

  /* ========== ENUM ========== */

  enum Status {
    // 0) Vault is open
    Open,
    // 1) User is depositing to vault
    Deposit,
    // 2) User deposit to vault failure
    Deposit_Failed,
    // 3) User is withdrawing from vault
    Withdraw,
    // 4) User withdrawal from vault failure
    Withdraw_Failed,
    // 5) Vault is rebalancing delta or debt  with more hedging
    Rebalance_Add,
    // 6) Vault is rebalancing delta or debt with less hedging
    Rebalance_Remove,
    // 7) Vault has rebalanced but still requires more rebalancing
    Rebalance_Open,
    // 8) Vault is compounding
    Compound,
    // 9) Vault is paused
    Paused,
    // 10) Vault is repaying
    Repay,
    // 11) Vault has repaid all debt after pausing
    Repaid,
    // 12) Vault is resuming
    Resume,
    // 13) Vault is closed after repaying debt
    Closed
  }

  enum Delta {
    // Neutral delta strategy; aims to hedge tokenA exposure
    Neutral,
    // Long delta strategy; aims to correlate with tokenA exposure
    Long,
    // Short delta strategy; aims to overhedge tokenA exposure
    Short
  }

  enum RebalanceType {
    // Rebalance delta; mostly borrowing/repay tokenA
    Delta,
    // Rebalance debt ratio; mostly borrowing/repay tokenB
    Debt
  }
}
