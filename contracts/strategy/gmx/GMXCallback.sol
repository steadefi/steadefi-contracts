// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IDeposit } from "../../interfaces/protocols/gmx/IDeposit.sol";
import { IWithdrawal } from "../../interfaces/protocols/gmx/IWithdrawal.sol";
import { IEvent } from "../../interfaces/protocols/gmx/IEvent.sol";
import { IDepositCallbackReceiver } from "../../interfaces/protocols/gmx/IDepositCallbackReceiver.sol";
import { IWithdrawalCallbackReceiver } from "../../interfaces/protocols/gmx/IWithdrawalCallbackReceiver.sol";
import { IRoleStore } from "../../interfaces/protocols/gmx/IRoleStore.sol";
import { IGMXVault } from "../../interfaces/strategy/gmx/IGMXVault.sol";
import { Errors } from "../../utils/Errors.sol";
import { GMXTypes } from "./GMXTypes.sol";

/**
  * @title GMXCallback
  * @author Steadefi
  * @notice The GMX callback handler for Steadefi leveraged vaults
*/
contract GMXCallback is IDepositCallbackReceiver, IWithdrawalCallbackReceiver {

  /* ==================== STATE VARIABLES ==================== */

  // Address of the vault this callback handler is for
  IGMXVault public vault;
  // GMX role store address
  IRoleStore public roleStore;

  /* ======================== EVENTS ========================= */

  event ProcessDeposit(
    bytes32 depositKey,
    uint256 lpAmtReceived
  );
  event ProcessRebalanceAdd(
    bytes32 depositKey,
    uint256 lpAmtReceived
  );
  event ProcessCompound(
    bytes32 depositKey,
    uint256 lpAmtReceived
  );
  event ProcessWithdrawFailureLiquidityAdded(
    bytes32 depositKey,
    uint256 lpAmtReceived
  );
  event ProcessEmergencyResume(
    bytes32 depositKey,
    uint256 lpAmtReceived
  );
  event ProcessDepositCancellation(bytes32 depositKey);
  event ProcessRebalanceAddCancellation(bytes32 depositKey);
  event ProcessCompoundCancellation(bytes32 depositKey);
  event ProcessEmergencyResumeCancellation(bytes32 depositKey);

  event ProcessWithdraw(
    bytes32 withdrawKey,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  );
  event ProcessRebalanceRemove(
    bytes32 withdrawKey,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  );
  event ProcessDepositFailureLiquidityWithdrawal(
    bytes32 withdrawKey,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  );
  event ProcessEmergencyRepay(
    bytes32 withdrawKey,
    uint256 tokenAReceived,
    uint256 tokenBReceived
  );
  event ProcessWithdrawCancellation(bytes32 withdrawKey);
  event ProcessRebalanceRemoveCancellation(bytes32 withdrawKey);

  /* ======================= MODIFIERS ======================= */

  // Allow only GMX controllers
  modifier onlyController() {
    if (!roleStore.hasRole(msg.sender, keccak256(abi.encode("CONTROLLER")))) {
      revert Errors.InvalidCallbackHandler();
    } else {
      _;
    }
  }

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @notice Initialize callback contract with associated vault address
    * @param _vault Address of vault
  */
  constructor (address _vault) {
    vault = IGMXVault(_vault);
    roleStore = IRoleStore(vault.store().roleStore);
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Process vault after successful deposit execution from GMX
    * @dev Callback function for GMX handler to call
    * @param depositKey bytes32 deposit key from GMX
    * @param eventData IEvent.Props
  */
  function afterDepositExecution(
    bytes32 depositKey,
    IDeposit.Props memory /* depositProps */,
    IEvent.Props memory eventData
  ) external onlyController {
    GMXTypes.Store memory _store = vault.store();

    uint256 _lpAmtReceived = eventData.uintItems.items[0].value;

    if (
      _store.status == GMXTypes.Status.Deposit &&
      _store.depositCache.depositKey == depositKey
    ) {
      emit ProcessDeposit(depositKey, _lpAmtReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessDeposit,
        depositKey,
        bytes32(0),
        _lpAmtReceived,
        0,
        0
      );
    } else if (
      _store.status == GMXTypes.Status.Rebalance_Add &&
      _store.rebalanceCache.depositKey == depositKey
    ) {
      emit ProcessRebalanceAdd(depositKey, _lpAmtReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessRebalanceAdd,
        depositKey,
        bytes32(0),
        _lpAmtReceived,
        0,
        0
      );
    } else if (
      _store.status == GMXTypes.Status.Compound &&
      _store.compoundCache.depositKey == depositKey
    ) {
      emit ProcessCompound(depositKey, _lpAmtReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessCompound,
        depositKey,
        bytes32(0),
        _lpAmtReceived,
        0,
        0
      );
    } else if (
      _store.status == GMXTypes.Status.Withdraw_Failed &&
      _store.withdrawCache.depositKey == depositKey
    ) {
      emit ProcessWithdrawFailureLiquidityAdded(depositKey, _lpAmtReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessWithdrawFailureLiquidityAdded,
        depositKey,
        bytes32(0),
        _lpAmtReceived,
        0,
        0
      );
    } else if (_store.status == GMXTypes.Status.Resume) {
      // This if block is to catch the Deposit callback after an
      // emergencyResume() to set the vault status to Open
      emit ProcessEmergencyResume(depositKey, _lpAmtReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessEmergencyResume,
        depositKey,
        bytes32(0),
        _lpAmtReceived,
        0,
        0
      );
    }
  }

  /**
    * @notice Process vault after deposit cancellation from GMX
    * @dev Callback function for GMX handler to call
    * @param depositKey bytes32 deposit key from GMX
  */
  function afterDepositCancellation(
    bytes32 depositKey,
    IDeposit.Props memory /* depositProps */,
    IEvent.Props memory /* eventData */
  ) external onlyController {
    GMXTypes.Store memory _store = vault.store();

    if (_store.status == GMXTypes.Status.Deposit) {
      if (_store.depositCache.depositKey == depositKey)
        emit ProcessDepositCancellation(depositKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessDepositCancellation,
          depositKey,
          bytes32(0),
          0,
          0,
          0
        );
    } else if (_store.status == GMXTypes.Status.Rebalance_Add) {
      if (_store.rebalanceCache.depositKey == depositKey)
        emit ProcessRebalanceAddCancellation(depositKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessRebalanceAddCancellation,
          depositKey,
          bytes32(0),
          0,
          0,
          0
        );
    } else if (_store.status == GMXTypes.Status.Compound) {
      if (_store.compoundCache.depositKey == depositKey)
        emit ProcessCompoundCancellation(depositKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessCompoundCancellation,
          depositKey,
          bytes32(0),
          0,
          0,
          0
        );
    } else if (_store.status == GMXTypes.Status.Resume) {
        emit ProcessEmergencyResumeCancellation(depositKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessEmergencyResumeCancellation,
          depositKey,
          bytes32(0),
          0,
          0,
          0
        );
    } else {
      revert Errors.DepositCancellationUnmatchedCallback();
    }
  }

  /**
    * @notice Process vault after successful withdrawal execution from GMX
    * @dev Callback function for GMX handler to call
    * @param withdrawKey bytes32 withdraw key from GMX
    * @param eventData IEvent.Props
  */
  function afterWithdrawalExecution(
    bytes32 withdrawKey,
    IWithdrawal.Props memory /* withdrawProps */,
    IEvent.Props memory eventData
  ) external onlyController {
    GMXTypes.Store memory _store = vault.store();

    uint256 _tokenAReceived = eventData.uintItems.items[0].value;
    uint256 _tokenBReceived = eventData.uintItems.items[1].value;

    if (
      _store.status == GMXTypes.Status.Withdraw &&
      _store.withdrawCache.withdrawKey == withdrawKey
    ) {
      emit ProcessWithdraw(withdrawKey, _tokenAReceived, _tokenBReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessWithdraw,
        bytes32(0),
        withdrawKey,
        0,
        _tokenAReceived,
        _tokenBReceived
      );
    } else if (
      _store.status == GMXTypes.Status.Rebalance_Remove &&
      _store.rebalanceCache.withdrawKey == withdrawKey
    ) {
      emit ProcessRebalanceRemove(withdrawKey, _tokenAReceived, _tokenBReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessRebalanceRemove,
        bytes32(0),
        withdrawKey,
        0,
        _tokenAReceived,
        _tokenBReceived
      );
    } else if (
      _store.status == GMXTypes.Status.Deposit_Failed &&
      _store.depositCache.withdrawKey == withdrawKey
    ) {
      emit ProcessDepositFailureLiquidityWithdrawal(withdrawKey, _tokenAReceived, _tokenBReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessDepositFailureLiquidityWithdrawal,
        bytes32(0),
        withdrawKey,
        0,
        _tokenAReceived,
        _tokenBReceived
      );
    } else if (
      _store.status == GMXTypes.Status.Repay
    ) {
      emit ProcessEmergencyRepay(withdrawKey, _tokenAReceived, _tokenBReceived);

      vault.emitProcessEvent(
        GMXTypes.CallbackType.ProcessEmergencyRepay,
        bytes32(0),
        withdrawKey,
        0,
        _tokenAReceived,
        _tokenBReceived
      );
    }
  }

  /**
    * @notice Process vault after withdrawal cancellation from GMX
    * @dev Callback function for GMX handler to call
    * @param withdrawKey bytes32 withdraw key from GMX
  */
  function afterWithdrawalCancellation(
    bytes32 withdrawKey,
    IWithdrawal.Props memory /* withdrawProps */,
    IEvent.Props memory /* eventData */
  ) external onlyController {
    GMXTypes.Store memory _store = vault.store();

    if (_store.status == GMXTypes.Status.Withdraw) {
      if (_store.withdrawCache.withdrawKey == withdrawKey)
        emit ProcessWithdrawCancellation(withdrawKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessWithdrawCancellation,
          bytes32(0),
          withdrawKey,
          0,
          0,
          0
        );
    } else if (_store.status == GMXTypes.Status.Rebalance_Remove) {
      if (_store.rebalanceCache.withdrawKey == withdrawKey)
        emit ProcessRebalanceRemoveCancellation(withdrawKey);

        vault.emitProcessEvent(
          GMXTypes.CallbackType.ProcessRebalanceRemoveCancellation,
          bytes32(0),
          withdrawKey,
          0,
          0,
          0
        );
    } else {
      revert Errors.WithdrawalCancellationUnmatchedCallback();
    }
  }
}
