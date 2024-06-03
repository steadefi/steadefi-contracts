// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Errors } from "../../utils/Errors.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTReader } from "./LRTReader.sol";

/**
  * @title LRTChecks
  * @author Steadefi
  * @notice Re-usable library functions for require function checks for Steadefi leveraged vaults
*/
library LRTChecks {

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice Checks before native token deposit
    * @param self LRTTypes.Store
    * @param dp LRTTypes.DepositParams
  */
  function beforeNativeDepositChecks(
    LRTTypes.Store storage self,
    LRTTypes.DepositParams memory dp
  ) external view {
    if (dp.token != address(self.WNT))
      revert Errors.InvalidNativeTokenAddress();

    if (dp.amt == 0) revert Errors.EmptyDepositAmount();
  }

  /**
    * @notice Checks before token deposit
    * @param self LRTTypes.Store
    * @param depositValue USD value in 1e18
  */
  function beforeDepositChecks(
    LRTTypes.Store storage self,
    uint256 depositValue
  ) external view {
    if (self.status != LRTTypes.Status.Open)
      revert Errors.NotAllowedInCurrentVaultStatus();

    if (
      self.depositCache.depositParams.token != address(self.LRT) &&
      self.depositCache.depositParams.token != address(self.WNT) &&
      self.depositCache.depositParams.token != address(self.LST) &&
      self.depositCache.depositParams.token != address(self.USDC)
    ) {
      revert Errors.InvalidDepositToken();
    }

    if (self.depositCache.depositParams.amt == 0)
      revert Errors.InsufficientDepositAmount();

    if (self.depositCache.depositParams.slippage < self.minVaultSlippage)
      revert Errors.InsufficientVaultSlippageAmount();

    if (depositValue == 0)
      revert Errors.InsufficientDepositValue();

    if (depositValue < self.minAssetValue)
      revert Errors.InsufficientDepositValue();

    if (depositValue > self.maxAssetValue)
      revert Errors.ExcessiveDepositValue();

    if (depositValue > LRTReader.additionalCapacity(self))
      revert Errors.InsufficientLendingLiquidity();

    if (LRTReader.equityValue(self) == 0 && IERC20(address(self.vault)).totalSupply() > 0)
      revert Errors.DepositNotAllowedWhenEquityIsZero();
  }

  /**
    * @notice Checks after deposit
    * @param self LRTTypes.Store
  */
  function afterDepositChecks(
    LRTTypes.Store storage self
  ) external view {
    // Guards: revert if lrtAmt did not increase at all
    if (LRTReader.lrtAmt(self) <= self.depositCache.healthParams.lrtAmtBefore)
      revert Errors.InsufficientLPTokensMinted();

    // Guards: check that debt ratio is within step change range
    if (!_isWithinStepChange(
      self.depositCache.healthParams.debtRatioBefore,
      LRTReader.debtRatio(self),
      self.debtRatioStepThreshold
    )) revert Errors.InvalidDebtRatio();

    // Slippage: Check whether user received enough shares as expected
    if (self.depositCache.sharesToUser < self.depositCache.minSharesAmt)
      revert Errors.InsufficientSharesMinted();
  }

  /**
    * @notice Checks before vault withdrawal
    * @param self LRTTypes.Store

  */
  function beforeWithdrawChecks(
    LRTTypes.Store storage self
  ) external view {
    if (self.status != LRTTypes.Status.Open)
      revert Errors.NotAllowedInCurrentVaultStatus();

    if (self.withdrawCache.withdrawParams.shareAmt == 0)
      revert Errors.EmptyWithdrawAmount();

    if (
      self.withdrawCache.withdrawParams.shareAmt >
      IERC20(address(self.vault)).balanceOf(self.withdrawCache.user)
    ) revert Errors.InsufficientWithdrawBalance();

    if (self.withdrawCache.withdrawValue > self.maxAssetValue)
      revert Errors.ExcessiveWithdrawValue();

    if (self.withdrawCache.withdrawParams.slippage < self.minVaultSlippage)
      revert Errors.InsufficientVaultSlippageAmount();
  }

  /**
    * @notice Checks after token withdrawal
    * @param self LRTTypes.Store
  */
  function afterWithdrawChecks(
    LRTTypes.Store storage self
  ) external view {
    // Guards: revert if lpAmt did not decrease at all
    if (LRTReader.lrtAmt(self) >= self.withdrawCache.healthParams.lrtAmtBefore)
      revert Errors.InsufficientLPTokensBurned();

    // Guards: revert if equity did not decrease at all
    if (
      self.withdrawCache.healthParams.equityAfter >=
      self.withdrawCache.healthParams.equityBefore
    ) revert Errors.InvalidEquityAfterWithdraw();

    // Guards: check that debt ratio is within step change range
    if (!_isWithinStepChange(
      self.withdrawCache.healthParams.debtRatioBefore,
      LRTReader.debtRatio(self),
      self.debtRatioStepThreshold
    )) revert Errors.InvalidDebtRatio();

    // Check that user received enough assets as expected
    if (self.withdrawCache.assetsToUser < self.withdrawCache.minAssetsAmt)
      revert Errors.InsufficientAssetsReceived();
  }

  /**
    * @notice Checks before rebalancing
    * @param self LRTTypes.Store
    * @param rebalanceType LRTTypes.RebalanceType
  */
  function beforeRebalanceChecks(
    LRTTypes.Store storage self,
    LRTTypes.RebalanceType rebalanceType
  ) external view {
    if (
      self.status != LRTTypes.Status.Open &&
      self.status != LRTTypes.Status.Rebalance_Open
    ) revert Errors.NotAllowedInCurrentVaultStatus();

    // Check that rebalance type is Delta or Debt
    // And then check that rebalance conditions are met
    // Note that Delta rebalancing requires vault's delta strategy to be Neutral as well
    if (rebalanceType == LRTTypes.RebalanceType.Delta && self.delta == LRTTypes.Delta.Neutral) {
      if (
        self.rebalanceCache.healthParams.deltaBefore <= self.deltaUpperLimit &&
        self.rebalanceCache.healthParams.deltaBefore >= self.deltaLowerLimit
      ) revert Errors.InvalidRebalancePreConditions();
    } else if (rebalanceType == LRTTypes.RebalanceType.Debt) {
      if (
        self.rebalanceCache.healthParams.debtRatioBefore <= self.debtRatioUpperLimit &&
        self.rebalanceCache.healthParams.debtRatioBefore >= self.debtRatioLowerLimit
      ) revert Errors.InvalidRebalancePreConditions();
    } else {
       revert Errors.InvalidRebalanceParameters();
    }
  }

  /**
    * @notice Checks after rebalancing add or remove
    * @param self LRTTypes.Store
  */
  function afterRebalanceChecks(
    LRTTypes.Store storage self
  ) external view {
    // Guards: check that delta is within limits for Neutral strategy
    if (self.delta == LRTTypes.Delta.Neutral) {
      int256 _delta = LRTReader.delta(self);

      if (
        _delta > self.deltaUpperLimit ||
        _delta < self.deltaLowerLimit
      ) revert Errors.InvalidDelta();
    }

    // Guards: check that debt is within limits for Long/Neutral strategy
    uint256 _debtRatio = LRTReader.debtRatio(self);

    if (
      _debtRatio > self.debtRatioUpperLimit ||
      _debtRatio < self.debtRatioLowerLimit
    ) revert Errors.InvalidDebtRatio();
  }

  /**
    * @notice Checks before compound
    * @param self LRTTypes.Store
  */
  function beforeCompoundChecks(
    LRTTypes.Store storage self
  ) external view {
    if (
      self.status != LRTTypes.Status.Open
    ) revert Errors.NotAllowedInCurrentVaultStatus();

    if (self.compoundCache.depositValue == 0)
      revert Errors.InsufficientDepositAmount();
  }

  /**
    * @notice Checks before compound LRT
    * @param self LRTTypes.Store
  */
  function beforeCompoundLRTChecks(
    LRTTypes.Store storage self
  ) external view {
    if (
      self.status != LRTTypes.Status.Open
    ) revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before emergency pausing of vault
    * @param self LRTTypes.Store
  */
  function beforeEmergencyPauseChecks(
    LRTTypes.Store storage self
  ) external view {
    if (
      self.status == LRTTypes.Status.Paused ||
      self.status == LRTTypes.Status.Resume ||
      self.status == LRTTypes.Status.Repaid ||
      self.status == LRTTypes.Status.Closed
    ) revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before emergency repaying of vault
    * @param self LRTTypes.Store
  */
  function beforeEmergencyRepayChecks(
    LRTTypes.Store storage self
  ) external view {
    if (self.status != LRTTypes.Status.Paused)
      revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before emergency re-borrowing assets of vault
    * @param self LRTTypes.Store
  */
  function beforeEmergencyBorrowChecks(
    LRTTypes.Store storage self
  ) external view {
    if (self.status != LRTTypes.Status.Repaid)
      revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before resuming vault
    * @param self LRTTypes.Store
  */
  function beforeEmergencyResumeChecks (
    LRTTypes.Store storage self
  ) external view {
    if (self.status != LRTTypes.Status.Paused)
      revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before emergency closure of vault
    * @param self LRTTypes.Store
  */
  function beforeEmergencyCloseChecks (
    LRTTypes.Store storage self
  ) external view {
    if (self.status != LRTTypes.Status.Repaid)
      revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before a withdrawal during emergency closure
    * @param self LRTTypes.Store
    * @param shareAmt Amount of shares to burn
  */
  function beforeEmergencyWithdrawChecks(
    LRTTypes.Store storage self,
    uint256 shareAmt
  ) external view {
    if (self.status != LRTTypes.Status.Closed)
      revert Errors.NotAllowedInCurrentVaultStatus();

    if (shareAmt == 0)
      revert Errors.EmptyWithdrawAmount();

    if (shareAmt > IERC20(address(self.vault)).balanceOf(msg.sender))
      revert Errors.InsufficientWithdrawBalance();
  }

  /**
    * @notice Checks before emergency status change
    * @param self LRTTypes.Store
  */
  function beforeEmergencyStatusChangeChecks(
    LRTTypes.Store storage self
  ) external view {
    if (
      self.status == LRTTypes.Status.Open ||
      self.status == LRTTypes.Status.Repaid ||
      self.status == LRTTypes.Status.Closed
    ) revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /**
    * @notice Checks before shares are minted
    * @param self LRTTypes.Store
  */
  function beforeMintFeeChecks(
    LRTTypes.Store storage self
  ) external view {
    if (self.status == LRTTypes.Status.Paused || self.status == LRTTypes.Status.Closed)
      revert Errors.NotAllowedInCurrentVaultStatus();
  }

  /* ================== INTERNAL FUNCTIONS =================== */

  /**
    * @notice Check if values are within threshold range
    * @param valueBefore Previous value
    * @param valueAfter New value
    * @param threshold Tolerance threshold; 100 = 1%
    * @return boolean Whether value after is within threshold range
  */
  function _isWithinStepChange(
    uint256 valueBefore,
    uint256 valueAfter,
    uint256 threshold
  ) internal pure returns (bool) {
    // To bypass initial vault deposit
    if (valueBefore == 0)
      return true;

    return (
      valueAfter >= valueBefore * (10000 - threshold) / 10000 &&
      valueAfter <= valueBefore * (10000 + threshold) / 10000
    );
  }
}
