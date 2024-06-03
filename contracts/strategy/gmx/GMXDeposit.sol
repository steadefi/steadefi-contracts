// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IDeposit } from "../../interfaces/protocols/gmx/IDeposit.sol";
import { IWithdrawal } from "../../interfaces/protocols/gmx/IWithdrawal.sol";
import { IEvent } from "../../interfaces/protocols/gmx/IEvent.sol";
import { IOrder } from "../../interfaces/protocols/gmx/IOrder.sol";
import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { GMXTypes } from "./GMXTypes.sol";
import { GMXReader } from "./GMXReader.sol";
import { GMXChecks } from "./GMXChecks.sol";
import { GMXManager } from "./GMXManager.sol";
import { GMXProcessDeposit } from "./GMXProcessDeposit.sol";
import { GMXEmergency } from "./GMXEmergency.sol";

/**
  * @title GMXDeposit
  * @author Steadefi
  * @notice Re-usable library functions for deposit operations for Steadefi leveraged vaults
*/
library GMXDeposit {

  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  /* ======================= CONSTANTS ======================= */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================== EVENTS ========================= */

  event DepositCreated(
    address indexed user,
    address asset,
    uint256 assetAmt
  );
  event DepositCompleted(
    address indexed user,
    uint256 shareAmt,
    uint256 equityBefore,
    uint256 equityAfter
  );
  event DepositCancelled(
    address indexed user
  );
  event DepositFailed(bytes reason);
  event DepositFailureProcessed();
  event DepositFailureLiquidityWithdrawalProcessed();

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
    * @param isNative Boolean as to whether user is depositing native asset (e.g. ETH, AVAX, etc.)
  */
  function deposit(
    GMXTypes.Store storage self,
    GMXTypes.DepositParams memory dp,
    bool isNative
  ) external {
    // Capture vault parameters before deposit
    GMXTypes.HealthParams memory _hp;

    _hp.lpAmtBefore = GMXReader.lpAmt(self);
    (_hp.tokenAAssetAmtBefore, _hp.tokenBAssetAmtBefore) = GMXReader.assetAmt(self);

    // Transfer assets from user to vault
    if (isNative) {
      GMXChecks.beforeNativeDepositChecks(self, dp);

      self.WNT.deposit{ value: dp.amt }();
    } else {
      IERC20(dp.token).safeTransferFrom(msg.sender, address(this), dp.amt);
    }

    GMXTypes.DepositCache memory _dc;

    _dc.user = payable(msg.sender);

    if (dp.token == address(self.lpToken)) {
      // If LP token deposited
      _dc.depositValue = self.gmxOracle.getLpTokenValue(
        address(self.lpToken),
        address(self.tokenA),
        address(self.tokenA),
        address(self.tokenB),
        true,
        false
      )
      * dp.amt
      / SAFE_MULTIPLIER;
    } else {
      // If tokenA or tokenB deposited
      _dc.depositValue = GMXReader.convertToUsdValue(
        self,
        address(dp.token),
        dp.amt
      );
    }
    _dc.depositParams = dp;
    _dc.healthParams = _hp;

    self.depositCache = _dc;

    GMXChecks.beforeDepositChecks(self, _dc.depositValue);

    // Calculate minimum amount of shares expected based on deposit value
    // and vault slippage value passed in and current equityValue.
    // We calculate this after `beforeDepositChecks()`
    // to ensure the vault slippage passed in meets the `minVaultSlippage`
    _dc.minSharesAmt = GMXReader.valueToShares(
      self,
      _dc.depositValue,
      GMXReader.equityValue(self)
    ) * (10000 - dp.slippage) / 10000;

    self.status = GMXTypes.Status.Deposit;

    // Borrow assets and create deposit in GMX
    (
      uint256 _borrowTokenAAmt,
      uint256 _borrowTokenBAmt
    ) = GMXManager.calcBorrow(self, _dc.depositValue);

    _dc.borrowParams.borrowTokenAAmt = _borrowTokenAAmt;
    _dc.borrowParams.borrowTokenBAmt = _borrowTokenBAmt;

    GMXManager.borrow(self, _borrowTokenAAmt, _borrowTokenBAmt);

    GMXTypes.AddLiquidityParams memory _alp;

    if (dp.token == address(self.tokenA)) {
      _alp.tokenAAmt = dp.amt + _borrowTokenAAmt;
    } else {
      _alp.tokenAAmt = _borrowTokenAAmt;
    }
    if (dp.token == address(self.tokenB)) {
      _alp.tokenBAmt = dp.amt + _borrowTokenBAmt;
    } else {
      _alp.tokenBAmt = _borrowTokenBAmt;
    }

    // Get deposit value of all tokenA/B in vault that will be added to GMX as liquidity
    // Note that this is slightly different from the user's depositValue calculated above, as
    // the user may have deposited LP tokens, which are NOT re-deposited to GMX, and as such
    // we should not include that as part of this deposit value as slippage
    uint256 _depositValueForAddingLiquidity = GMXReader.convertToUsdValue(
      self,
      address(self.tokenA),
      _alp.tokenAAmt
    ) + GMXReader.convertToUsdValue(
      self,
      address(self.tokenB),
      _alp.tokenBAmt
    );

    _alp.minMarketTokenAmt = GMXManager.calcMinMarketSlippageAmt(
      self,
      _depositValueForAddingLiquidity,
      self.liquiditySlippage
    );
    _alp.executionFee = dp.executionFee;

    _dc.depositKey = GMXManager.addLiquidity(
      self,
      _alp
    );

    self.depositCache = _dc;

    emit DepositCreated(
      _dc.user,
      _dc.depositParams.token,
      _dc.depositParams.amt
    );
  }

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
  */
  function processDeposit(
    GMXTypes.Store storage self,
    uint256 lpAmtReceived
  ) external {
    GMXChecks.beforeProcessDepositChecks(self);

    GMXTypes.DepositCache memory _dc = self.depositCache;
    GMXTypes.HealthParams memory _hp = _dc.healthParams;

    // Compute asset value of vault before deposit
    uint256 _assetValueBefore = _hp.lpAmtBefore
      * self.gmxOracle.getLpTokenValue(
        address(self.lpToken),
        address(self.tokenA),
        address(self.tokenA),
        address(self.tokenB),
        true,
        false
      ) / SAFE_MULTIPLIER;

    // Compute equity, debtRatio and delta of vault before deposit
    if (_assetValueBefore > 0) {
      // Use existing tokens debt amount subtracting borrowed tokens amt
      // to properly account for accrued interest of past borrows
      (uint256 _tokenADebtAmt, uint256 _tokenBDebtAmt) = GMXReader.debtAmt(self);

      _hp.tokenADebtAmtBefore = _tokenADebtAmt - _dc.borrowParams.borrowTokenAAmt;
      _hp.tokenBDebtAmtBefore = _tokenBDebtAmt - _dc.borrowParams.borrowTokenBAmt;

      uint256 _debtValueBefore = GMXReader.convertToUsdValue(
        self,
        address(self.tokenA),
        _hp.tokenADebtAmtBefore
      )
      + GMXReader.convertToUsdValue(
        self,
        address(self.tokenB),
        _hp.tokenBDebtAmtBefore
      );

      _hp.equityBefore = _assetValueBefore - _debtValueBefore;

      _hp.debtRatioBefore = _debtValueBefore
        * SAFE_MULTIPLIER
        / _assetValueBefore;

      if (_hp.tokenAAssetAmtBefore == 0 &&  _hp.tokenADebtAmtBefore == 0) {
        _hp.deltaBefore = 0;
      } else {
        bool _isPositive = _hp.tokenAAssetAmtBefore >= _hp.tokenADebtAmtBefore;

        uint256 _unsignedDelta = _isPositive ?
          _hp.tokenAAssetAmtBefore - _hp.tokenADebtAmtBefore :
          _hp.tokenADebtAmtBefore - _hp.tokenAAssetAmtBefore;

        int256 signedDelta = (_unsignedDelta
          * self.chainlinkOracle.consultIn18Decimals(address(self.tokenA))
          / _hp.equityBefore).toInt256();

        _hp.deltaBefore = _isPositive ? signedDelta : -signedDelta;
      }
    } else {
      _hp.equityBefore = 0;
      _hp.debtRatioBefore = 0;
      _hp.deltaBefore = 0;
    }

    self.depositCache.healthParams = _hp;

    // Process deposit with new LP toens received
    self.depositCache.lpAmtReceived = lpAmtReceived;

    // Account LP tokens received to vault
    self.lpAmt += lpAmtReceived;

    if (self.depositCache.depositParams.token == address(self.lpToken))
      self.lpAmt += self.depositCache.depositParams.amt;

    // Store equityAfter and shareToUser values in DepositCache
    self.depositCache.healthParams.equityAfter = GMXReader.equityValue(self);

    // Compute how many svTokens to mint to depositor
    self.depositCache.sharesToUser = GMXReader.valueToShares(
      self,
      self.depositCache.healthParams.equityAfter - _hp.equityBefore,
      _hp.equityBefore
    );

    // We transfer the logic of afterDepositChecks to GMXProcessDeposit.processDeposit()
    // to allow try/catch here to catch for afterDepositChecks() failing.
    // If there are any issues, a DepositFailed event will be emitted and
    // processDepositFailure() should be triggered.
    try GMXProcessDeposit.processDeposit(self) {
      self.vault.mintFee();
      // Mint shares to depositor
      self.vault.mint(self.depositCache.user, self.depositCache.sharesToUser);

      self.status = GMXTypes.Status.Open;

      // Check if there is an emergency pause queued
      if (self.shouldEmergencyPause) GMXEmergency.emergencyPause(self);

      emit DepositCompleted(
        self.depositCache.user,
        self.depositCache.sharesToUser,
        self.depositCache.healthParams.equityBefore,
        self.depositCache.healthParams.equityAfter
      );
    } catch (bytes memory reason) {
      self.status = GMXTypes.Status.Deposit_Failed;

      emit DepositFailed(reason);
    }
  }

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
  */
  function processDepositCancellation(
    GMXTypes.Store storage self
  ) external {
    GMXChecks.beforeProcessDepositCancellationChecks(self);

    // Repay borrowed assets
    GMXManager.repay(
      self,
      self.depositCache.borrowParams.borrowTokenAAmt,
      self.depositCache.borrowParams.borrowTokenBAmt
    );

    // Return user's deposited asset
    // If native token is being withdrawn, we convert wrapped to native
    if (self.depositCache.depositParams.token == address(self.WNT)) {
      self.WNT.withdraw(self.depositCache.depositParams.amt);
      (bool success, ) = self.depositCache.user.call{
        value: self.depositCache.depositParams.amt
      }("");
      // if native transfer unsuccessful, send WNT back to user
      if (!success) {
        self.WNT.deposit{value: self.depositCache.depositParams.amt}();
        IERC20(address(self.WNT)).safeTransfer(
          self.withdrawCache.user,
          self.depositCache.depositParams.amt
        );
      }
    } else {
      // Transfer requested withdraw asset to user
      IERC20(self.depositCache.depositParams.token).safeTransfer(
        self.depositCache.user,
        self.depositCache.depositParams.amt
      );
    }

    self.status = GMXTypes.Status.Open;

    // Check if there is an emergency pause queued
    if (self.shouldEmergencyPause) GMXEmergency.emergencyPause(self);

    emit DepositCancelled(self.depositCache.user);
  }

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
  */
  function processDepositFailure(
    GMXTypes.Store storage self,
    uint256 executionFee
  ) external {
    GMXChecks.beforeProcessAfterDepositFailureChecks(self);

    GMXTypes.RemoveLiquidityParams memory _rlp;

    // Remove amount of LP that was received
    _rlp.lpAmt = self.depositCache.lpAmtReceived;

    // Account for the vault's LP tokens
    self.lpAmt -= self.depositCache.lpAmtReceived;

    // If user deposited LP tokens as well, to standardize the flow, we will also add it
    // to the LP amount to be withdrawn and account for vault's LP tokens
    if (self.depositCache.depositParams.token == address(self.lpToken)) {
      _rlp.lpAmt += self.depositCache.depositParams.amt;
      self.lpAmt -= self.depositCache.depositParams.amt;
    }

    if (self.delta == GMXTypes.Delta.Long) {
      // If delta strategy is Long, remove all in tokenB to make it more
      // efficent to repay tokenB debt as Long strategy only borrows tokenB
      address[] memory _tokenASwapPath = new address[](1);
      _tokenASwapPath[0] = address(self.lpToken);
      _rlp.tokenASwapPath = _tokenASwapPath;

      (_rlp.minTokenAAmt, _rlp.minTokenBAmt) = GMXManager.calcMinTokensSlippageAmt(
        self,
        _rlp.lpAmt,
        address(self.tokenB),
        address(self.tokenB),
        self.liquiditySlippage
      );
    } else if (self.delta == GMXTypes.Delta.Short) {
      // If delta strategy is Short, remove all in tokenA to make it more
      // efficent to repay tokenA debt as Short strategy only borrows tokenA
      address[] memory _tokenBSwapPath = new address[](1);
      _tokenBSwapPath[0] = address(self.lpToken);
      _rlp.tokenBSwapPath = _tokenBSwapPath;

      (_rlp.minTokenAAmt, _rlp.minTokenBAmt) = GMXManager.calcMinTokensSlippageAmt(
        self,
        _rlp.lpAmt,
        address(self.tokenA),
        address(self.tokenA),
        self.liquiditySlippage
      );
    } else {
      // If delta strategy is Neutral, withdraw in both tokenA/B
      (_rlp.minTokenAAmt, _rlp.minTokenBAmt) = GMXManager.calcMinTokensSlippageAmt(
        self,
        _rlp.lpAmt,
        address(self.tokenA),
        address(self.tokenB),
        self.liquiditySlippage
      );
    }

    _rlp.executionFee = executionFee;

    // Remove liquidity
    self.depositCache.withdrawKey = GMXManager.removeLiquidity(
      self,
      _rlp
    );

    emit DepositFailureProcessed();
  }

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
  */
  function processDepositFailureLiquidityWithdrawal(
    GMXTypes.Store storage self,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  ) public {
    GMXChecks.beforeProcessAfterDepositFailureLiquidityWithdrawal(self);

    uint256 _tokenAAmtInVault = tokenAReceived;
    uint256 _tokenBAmtInVault = tokenBReceived;

    if (self.delta == GMXTypes.Delta.Long) {
      // We withdraw assets all in tokenB
      _tokenAAmtInVault = 0;
      _tokenBAmtInVault = tokenAReceived + tokenBReceived;
    } else if (self.delta == GMXTypes.Delta.Short) {
      // We withdraw assets all in tokenA
      _tokenAAmtInVault = tokenAReceived + tokenBReceived;
      _tokenBAmtInVault = 0;
    } else {
      // Both tokenA/B amount received are "correct" for their respective tokens
      _tokenAAmtInVault = tokenAReceived;
      _tokenBAmtInVault = tokenBReceived;
    }

    GMXTypes.RepayParams memory _rp;

    _rp.repayTokenAAmt = self.depositCache.borrowParams.borrowTokenAAmt;
    _rp.repayTokenBAmt = self.depositCache.borrowParams.borrowTokenBAmt;

    // Check if swap between assets are needed for repayment based on previous borrow
    (
      bool _swapNeeded,
      address _tokenFrom,
      address _tokenTo,
      uint256 _tokenToAmt
    ) = GMXManager.calcSwapForRepay(
      self,
      _rp,
      _tokenAAmtInVault,
      _tokenBAmtInVault
    );

    if (_swapNeeded) {
      ISwap.SwapParams memory _sp;

      _sp.tokenIn = _tokenFrom;
      _sp.tokenOut = _tokenTo;
      _sp.amountIn = GMXManager.calcAmountInMaximum(
        self,
        _tokenFrom,
        _tokenTo,
        _tokenToAmt
      );
      _sp.amountOut = _tokenToAmt;
      _sp.slippage = self.swapSlippage;
      _sp.deadline = block.timestamp;
      // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      // We allow deadline to be set as the current block timestamp whenever this function
      // is called because this function is triggered as a follow up function (by a callback/keeper)
      // and not directly by a user/keeper. If this follow on function flow reverts due to this tx
      // being processed after a set deadline, this will cause the vault to be in a "stuck" state.
      // To resolve this, this function will have to be called again with an updated deadline until it
      // succeeds/a miner processes the tx.

      uint256 _amountIn = GMXManager.swapTokensForExactTokens(self, _sp);
      if (_tokenFrom == address(self.tokenA)) {
        _tokenAAmtInVault -= _amountIn;
        _tokenBAmtInVault += _tokenToAmt;
      } else if (_tokenFrom == address(self.tokenB)) {
        _tokenBAmtInVault -= _amountIn;
        _tokenAAmtInVault += _tokenToAmt;
      }
    }

    // Adjust amount to repay for both tokens due to slight differences
    // from liqudiity withdrawal and swaps. If the amount to repay based on previous borrow
    // is more than the available balance vault has, we simply repay what the vault has
    uint256 _repayTokenAAmt;
    uint256 _repayTokenBAmt;

    if (self.depositCache.borrowParams.borrowTokenAAmt > _tokenAAmtInVault) {
      _repayTokenAAmt = _tokenAAmtInVault;
    } else {
      _repayTokenAAmt = self.depositCache.borrowParams.borrowTokenAAmt;
    }

    if (self.depositCache.borrowParams.borrowTokenBAmt > _tokenBAmtInVault) {
      _repayTokenBAmt = _tokenBAmtInVault;
    } else {
      _repayTokenBAmt = self.depositCache.borrowParams.borrowTokenBAmt;
    }

    // Repay borrowed assets
    GMXManager.repay(
      self,
      _repayTokenAAmt,
      _repayTokenBAmt
    );

    _tokenAAmtInVault -= _repayTokenAAmt;
    _tokenBAmtInVault -= _repayTokenBAmt;

    // Refund user the rest of the remaining withdrawn assets after repayment
    // Will be in tokenA/tokenB only; so if user deposited LP tokens
    // they will still be refunded in tokenA/tokenB
    self.tokenA.safeTransfer(self.depositCache.user, _tokenAAmtInVault);
    self.tokenB.safeTransfer(self.depositCache.user, _tokenBAmtInVault);

    self.status = GMXTypes.Status.Open;

    // Check if there is an emergency pause queued
    if (self.shouldEmergencyPause) GMXEmergency.emergencyPause(self);

    emit DepositFailureLiquidityWithdrawalProcessed();
  }
}
