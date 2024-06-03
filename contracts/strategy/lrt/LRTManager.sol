// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTReader } from "./LRTReader.sol";
import { LRTWorker } from "./LRTWorker.sol";

/**
  * @title LRTManager
  * @author Steadefi
  * @notice Re-usable library functions for calculations and operations of borrows, repays, swaps
  * adding and removal of liquidity to yield source
*/
library LRTManager {

  using SafeERC20 for IERC20;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================== EVENTS ========================= */

  event BorrowSuccess(uint256 borrowTokenBAmt);
  event RepaySuccess(uint256 repayTokenBAmt);

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice Calculate amount of tokenA and tokenB to borrow
    * @param self LRTTypes.Store
    * @param depositValue USD value in 1e18
  */
  function calcBorrow(
    LRTTypes.Store storage self,
    uint256 depositValue
  ) external view returns (uint256) {
    // Calculate final position value based on deposit value
    uint256 _positionValue = depositValue * self.leverage / SAFE_MULTIPLIER;

    // Obtain the value to borrow
    uint256 _borrowValue = _positionValue - depositValue;

    uint256 _tokenBDecimals = IERC20Metadata(address(self.tokenB)).decimals();

    uint256 _borrowTokenBAmt = _borrowValue
      * SAFE_MULTIPLIER
      / LRTReader.convertToUsdValue(self, address(self.tokenB), 10**(_tokenBDecimals))
      / (10 ** (18 - _tokenBDecimals));

    return _borrowTokenBAmt;
  }

  /**
    * @notice Calculate amount of tokenB to repay based on token shares ratio being withdrawn
    * @param self LRTTypes.Store
    * @param shareRatio Amount of vault token shares relative to total supply in 1e18
  */
  function calcRepay(
    LRTTypes.Store storage self,
    uint256 shareRatio
  ) external view returns (uint256) {
    uint256 tokenBDebtAmt = LRTReader.debtAmt(self);

    uint256 _repayTokenBAmt = shareRatio * tokenBDebtAmt / SAFE_MULTIPLIER;

    return _repayTokenBAmt;
  }

  /**
    * @notice Calculate maximum amount of tokenIn allowed when swapping for an exact
    * amount of tokenOut as a form of slippage protection
    * @dev We slightly buffer amountOut here with swapSlippage to account for fees, etc.
    * @param self LRTTypes.Store
    * @param tokenIn Address of tokenIn
    * @param tokenOut Address of tokenOut
    * @param amountOut Amt of tokenOut wanted
    * @param slippage Slippage in 1e4
    * @return amountInMaximum in 1e18
  */
  function calcAmountInMaximum(
    LRTTypes.Store storage self,
    address tokenIn,
    address tokenOut,
    uint256 amountOut,
    uint256 slippage
  ) external view returns (uint256) {
    // Value of token out wanted in 1e18
    uint256 _tokenOutValue = amountOut
      * self.chainlinkOracle.consultIn18Decimals(tokenOut)
      / (10 ** IERC20Metadata(tokenOut).decimals());

    // Maximum amount in in 1e18
    uint256 _amountInMaximum = _tokenOutValue
      * SAFE_MULTIPLIER
      / self.chainlinkOracle.consultIn18Decimals(tokenIn)
      * (10000 + slippage) / 10000;

    // If tokenIn asset decimals is less than 18, e.g. USDC,
    // we need to normalize the decimals of _amountInMaximum
    if (IERC20Metadata(tokenIn).decimals() < 18)
      _amountInMaximum /= 10 ** (18 - IERC20Metadata(tokenIn).decimals());

    return _amountInMaximum;
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Borrow tokens from lending vaults
    * @param self LRTTypes.Store
    * @param borrowTokenBAmt Amount of tokenB to borrow in token decimals
  */
  function borrow(
    LRTTypes.Store storage self,
    uint256 borrowTokenBAmt
  ) public {
    if (borrowTokenBAmt > 0) {
      self.tokenBLendingVault.borrow(borrowTokenBAmt);
    }

    emit BorrowSuccess(borrowTokenBAmt);
  }

  /**
    * @notice Repay tokens to lending vaults
    * @param self LRTTypes.Store
    * @param repayTokenBAmt Amount of tokenB to repay in token decimals
  */
  function repay(
    LRTTypes.Store storage self,
    uint256 repayTokenBAmt
  ) public {
    if (repayTokenBAmt > 0) {
      self.tokenBLendingVault.repay(repayTokenBAmt);
    }

    emit RepaySuccess(repayTokenBAmt);
  }

  /**
    * @notice Swap exact amount of tokenIn for as many possible amount of tokenOut
    * @param self LRTTypes.Store
    * @param sp ISwap.SwapParams
    * @return amountOut in token decimals
  */
  function swapExactTokensForTokens(
    LRTTypes.Store storage self,
    ISwap.SwapParams memory sp
  ) external returns (uint256) {
    if (sp.amountIn > 0) {
      return LRTWorker.swapExactTokensForTokens(self, sp);
    } else {
      return 0;
    }
  }

  /**
    * @notice Swap as little posible tokenIn for exact amount of tokenOut
    * @param self LRTTypes.Store
    * @param sp ISwap.SwapParams
    * @return amountIn in token decimals
  */
  function swapTokensForExactTokens(
    LRTTypes.Store storage self,
    ISwap.SwapParams memory sp
  ) external returns (uint256) {
    if (sp.amountIn > 0) {
      return LRTWorker.swapTokensForExactTokens(self, sp);
    } else {
      return 0;
    }
  }
}
