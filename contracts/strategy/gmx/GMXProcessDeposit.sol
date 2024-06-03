// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { GMXTypes } from "./GMXTypes.sol";
import { GMXChecks } from "./GMXChecks.sol";

/**
  * @title GMXProcessDeposit
  * @author Steadefi
  * @notice Re-usable library functions for process deposit operations for Steadefi leveraged vaults
*/
library GMXProcessDeposit {

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc GMXVault
    * @param self GMXTypes.Store
  */
  function processDeposit(
    GMXTypes.Store storage self
  ) external view {
    GMXChecks.afterDepositChecks(self);
  }
}
