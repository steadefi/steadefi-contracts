// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTChecks } from "./LRTChecks.sol";
import { LRTManager } from "./LRTManager.sol";

/**
  * @title LRTCompound
  * @author Steadefi
  * @notice Re-usable library functions for compound operations for Steadefi leveraged vaults
*/
library LRTCompound {

  using SafeERC20 for IERC20;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================== EVENTS ========================= */

  event CompoundCompleted();

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function compound(
    LRTTypes.Store storage self,
    LRTTypes.CompoundParams memory cp
  ) external {
    self.compoundCache.compoundParams = cp;

    LRTChecks.beforeCompoundChecks(self);

    ISwap.SwapParams memory _sp;

    _sp.tokenIn = cp.tokenIn;
    _sp.tokenOut = cp.tokenOut;
    _sp.amountIn = cp.amtIn;
    _sp.amountOut = 0; // amount out minimum calculated in Swap
    _sp.slippage = self.swapSlippage;
    _sp.deadline = cp.deadline;

    // If tokenOut swapped is LRT, add to vault's LRT tracker
    // If not simply leave the token in the vault
    if (cp.tokenOut == address(self.LRT)) {
      self.lrtAmt += LRTManager.swapExactTokensForTokens(self, _sp);
    }

    emit CompoundCompleted();
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function compoundLRT(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeCompoundLRTChecks(self);

    // If lpAmt is somehow less than actual LP tokens balance, we sync it up it
    if (self.lrtAmt < self.LRT.balanceOf(address(this))) {
      self.lrtAmt = self.LRT.balanceOf(address(this));

      emit CompoundCompleted();
    }
  }
}
