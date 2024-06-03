// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTReader } from "./LRTReader.sol";
import { LRTChecks } from "./LRTChecks.sol";
import { LRTManager } from "./LRTManager.sol";

/**
  * @title LRTRebalance
  * @author Steadefi
  * @notice Re-usable library functions for rebalancing operations for Steadefi leveraged vaults
*/
library LRTRebalance {

  /* ======================== EVENTS ========================= */

  event RebalanceAdded(
    uint rebalanceType,
    uint256 borrowTokenBAmt
  );
  event RebalanceRemoved(
    uint rebalanceType,
    uint256 lrtAmtToRemove
  );
  event RebalanceSuccess(
    uint256 svTokenValueBefore,
    uint256 svTokenValueAfter
  );

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function rebalanceAdd(
    LRTTypes.Store storage self,
    LRTTypes.RebalanceAddParams memory rap
  ) external {
    LRTTypes.RebalanceCache memory _rc;

    _rc.rebalanceType = rap.rebalanceType;
    _rc.borrowParams = rap.borrowParams;

    _rc.healthParams.lrtAmtBefore = LRTReader.lrtAmt(self);
    _rc.healthParams.debtRatioBefore = LRTReader.debtRatio(self);
    _rc.healthParams.deltaBefore = LRTReader.delta(self);
    _rc.healthParams.svTokenValueBefore = LRTReader.svTokenValue(self);

    self.rebalanceCache = _rc;

    LRTChecks.beforeRebalanceChecks(self, rap.rebalanceType);

    LRTManager.borrow(self, rap.borrowParams.borrowTokenBAmt);

    // Swap tokenB to WNT first
    ISwap.SwapParams memory _sp;

    _sp.tokenIn = address(self.tokenB);
    _sp.tokenOut = address(self.WNT);
    _sp.amountIn = rap.borrowParams.borrowTokenBAmt;
    _sp.slippage = self.swapSlippage;
    _sp.deadline = block.timestamp;

    uint256 _wntAmountOut = LRTManager.swapExactTokensForTokens(self, _sp);

    // Then swap token WNT to LRT
    ISwap.SwapParams memory _sp2;

    _sp2.tokenIn = address(self.WNT);
    _sp2.tokenOut = address(self.LRT);
    _sp2.amountIn = _wntAmountOut;
    _sp2.slippage = self.swapSlippage;
    _sp2.deadline = block.timestamp;

    // Add to vault's total LRT amount
    self.lrtAmt += LRTManager.swapExactTokensForTokens(self, _sp2);

    emit RebalanceAdded(
      uint(rap.rebalanceType),
      rap.borrowParams.borrowTokenBAmt
    );

    LRTChecks.afterRebalanceChecks(self);

    emit RebalanceSuccess(
      self.rebalanceCache.healthParams.svTokenValueBefore,
      LRTReader.svTokenValue(self)
    );
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function rebalanceRemove(
    LRTTypes.Store storage self,
    LRTTypes.RebalanceRemoveParams memory rrp
  ) external {
    LRTTypes.RebalanceCache memory _rc;

    _rc.rebalanceType = rrp.rebalanceType;
    _rc.lrtAmtToRemove = rrp.lrtAmtToRemove;

    _rc.healthParams.lrtAmtBefore = LRTReader.lrtAmt(self);
    _rc.healthParams.debtRatioBefore = LRTReader.debtRatio(self);
    _rc.healthParams.deltaBefore = LRTReader.delta(self);
    _rc.healthParams.svTokenValueBefore = LRTReader.svTokenValue(self);

    self.rebalanceCache = _rc;

    LRTChecks.beforeRebalanceChecks(self, rrp.rebalanceType);

    self.lrtAmt -= rrp.lrtAmtToRemove;

    // Swap LRT to WNT first
    ISwap.SwapParams memory _sp;

    _sp.tokenIn = address(self.LRT);
    _sp.tokenOut = address(self.WNT);
    _sp.amountIn = rrp.lrtAmtToRemove;
    _sp.slippage = self.swapSlippage;
    _sp.deadline = block.timestamp;

    uint256 _wntAmountOut = LRTManager.swapExactTokensForTokens(self, _sp);

    // Swap WNT to tokenB
    ISwap.SwapParams memory _sp2;

    _sp2.tokenIn = address(self.WNT);
    _sp2.tokenOut = address(self.tokenB);
    _sp2.amountIn = _wntAmountOut;
    _sp2.slippage = self.swapSlippage;
    _sp2.deadline = block.timestamp;

    uint256 _tokenBAmt = LRTManager.swapExactTokensForTokens(self, _sp2);

    // Repay
    LRTManager.repay(self, _tokenBAmt);

    emit RebalanceRemoved(
      uint(rrp.rebalanceType),
      rrp.lrtAmtToRemove
    );

    LRTChecks.afterRebalanceChecks(self);

    emit RebalanceSuccess(
      self.rebalanceCache.healthParams.svTokenValueBefore,
      LRTReader.svTokenValue(self)
    );
  }
}
