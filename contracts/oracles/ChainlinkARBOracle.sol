// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { Errors } from "../utils/Errors.sol";

contract ChainlinkARBOracle is AccessManaged, Pausable {

  using SafeCast for int256;

  /* ======================= STRUCTS ========================= */

  struct ChainlinkResponse {
    uint80 roundId;
    int256 answer;
    uint256 timestamp;
    bool success;
    uint8 decimals;
  }

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;
  uint256 public constant SEQUENCER_GRACE_PERIOD_TIME = 1 hours;

  /* ==================== STATE VARIABLES ==================== */

  // Chainlink Arbitrum sequencer feed address
  AggregatorV3Interface internal sequencerUptimeFeed;

  /* ======================= MAPPINGS ======================== */

  // Mapping of token to Chainlink USD price or denominator ratio feed
  mapping(address => address) public feeds;
  // Mapping of token to maximum delay allowed (in seconds) of last price update
  mapping(address => uint256) public maxDelays;
  // Mapping of token to denominator token ratio
  mapping(address => address) public tokenToDenominatorToken;

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @param _sequencerFeed  Chainlink Arbitrum sequencer feed address
    * @param _accessManager Address of access manager
  */
  constructor(
    address _sequencerFeed,
    address _accessManager
  ) AccessManaged(_accessManager) {
    if (_sequencerFeed == address(0)) revert Errors.ZeroAddressNotAllowed();

    sequencerUptimeFeed = AggregatorV3Interface(_sequencerFeed);
  }

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice Get token price from Chainlink feed
    * @param token Token address
    * @return price Asset price in int256
    * @return decimals Price decimals in uint8
  */
  function consult(address token) public view whenNotPaused returns (int256, uint8) {
    address _feed = feeds[token];

    if (_feed == address(0)) revert Errors.NoTokenPriceFeedAvailable();

    ChainlinkResponse memory chainlinkResponse = _getChainlinkResponse(_feed);

    if (_chainlinkIsFrozen(chainlinkResponse, token)) revert Errors.FrozenTokenPriceFeed();
    if (_chainlinkIsBroken(chainlinkResponse)) revert Errors.BrokenTokenPriceFeed();

    return (chainlinkResponse.answer, chainlinkResponse.decimals);
  }

  /**
    * @notice Get token price in USD from Chainlink feed returned in 1e18
    * @dev Check if token has denominator and get denominator token price to compute USD value
    * @param token Token address
    * @return price in 1e18
  */
  function consultIn18Decimals(address token) external view whenNotPaused returns (uint256) {
    if (tokenToDenominatorToken[token] != address(0)) {
      // Get token denominator ratio
      (int256 baseAnswer, uint8 baseDecimals) = consult(token);

      // Get denominator token price
      (int256 _dtAnswer, uint8 _dtDecimals) = consult(tokenToDenominatorToken[token]);

      // Multiply token denominator ratio with denominator token price
      return (
        (baseAnswer.toUint256() * 1e18 / (10 ** baseDecimals))
        * (_dtAnswer.toUint256() * 1e18 / (10 ** _dtDecimals))
        / SAFE_MULTIPLIER
      );
    } else {
      // Get token price
      (int256 _answer, uint8 _decimals) = consult(token);

      return _answer.toUint256() * 1e18 / (10 ** _decimals);
    }
  }

  /* ================== INTERNAL FUNCTIONS =================== */

  /**
    * @notice Check if Chainlink oracle is not working as expected
    * @param currentResponse Current Chainlink response
    * @return Status of check in boolean
  */
  function _chainlinkIsBroken(
    ChainlinkResponse memory currentResponse
  ) internal view returns (bool) {
    return _badChainlinkResponse(currentResponse);
  }

  /**
    * @notice Checks to see if Chainlink oracle is returning a bad response
    * @param response Chainlink response
    * @return Status of check in boolean
  */
  function _badChainlinkResponse(ChainlinkResponse memory response) internal view returns (bool) {
    // Check for response call reverted
    if (!response.success) { return true; }
    // Check for an invalid roundId that is 0
    if (response.roundId == 0) { return true; }
    // Check for an invalid timeStamp that is 0, or in the future
    if (response.timestamp == 0 || response.timestamp > block.timestamp) { return true; }
    // Check for non-positive price
    if (response.answer <= 0) { return true; }

    return false;
  }

  /**
    * @notice Check to see if Chainlink oracle response is frozen/too stale
    * @param response Chainlink response
    * @param token Token address
    * @return Status of check in boolean
  */
  function _chainlinkIsFrozen(ChainlinkResponse memory response, address token) internal view returns (bool) {
    return (block.timestamp - response.timestamp) > maxDelays[token];
  }


  /**
    * @notice Get latest Chainlink response
    * @param _feed Chainlink oracle feed address
    * @return ChainlinkResponse
  */
  function _getChainlinkResponse(address _feed) internal view returns (ChainlinkResponse memory) {
    ChainlinkResponse memory _chainlinkResponse;

    _chainlinkResponse.decimals = AggregatorV3Interface(_feed).decimals();

    // Arbitrum sequencer uptime feed
    (
      /* uint80 _roundID*/,
      int256 _answer,
      uint256 _startedAt,
      /* uint256 _updatedAt */,
      /* uint80 _answeredInRound */
    ) = sequencerUptimeFeed.latestRoundData();

    // Answer == 0: Sequencer is up
    // Answer == 1: Sequencer is down
    bool _isSequencerUp = _answer == 0;
    if (!_isSequencerUp) revert Errors.SequencerDown();

    // Make sure the grace period has passed after the
    // sequencer is back up.
    uint256 _timeSinceUp = block.timestamp - _startedAt;
    if (_timeSinceUp <= SEQUENCER_GRACE_PERIOD_TIME) revert Errors.GracePeriodNotOver();

    (
      uint80 _latestRoundId,
      int256 _latestAnswer,
      /* uint256 _startedAt */,
      uint256 _latestTimestamp,
      /* uint80 _answeredInRound */
    ) = AggregatorV3Interface(_feed).latestRoundData();

    _chainlinkResponse.roundId = _latestRoundId;
    _chainlinkResponse.answer = _latestAnswer;
    _chainlinkResponse.timestamp = _latestTimestamp;
    _chainlinkResponse.success = true;

    return _chainlinkResponse;
  }

  /* ================= RESTRICTED FUNCTIONS ================== */

  /**
    * @notice Add Chainlink price feed for token
    * @param token Token address
    * @param feed Chainlink price feed address
  */
  function addTokenPriceFeed(address token, address feed) external restricted {
    if (token == address(0)) revert Errors.ZeroAddressNotAllowed();
    if (feed == address(0)) revert Errors.ZeroAddressNotAllowed();

    feeds[token] = feed;
  }

  /**
    * @notice Add Chainlink max delay for token
    * @param token Token address
    * @param maxDelay  Max delay allowed in seconds
  */
  function addTokenMaxDelay(address token, uint256 maxDelay) external restricted {
    if (token == address(0)) revert Errors.ZeroAddressNotAllowed();
    if (feeds[token] == address(0)) revert Errors.NoTokenPriceFeedAvailable();
    if (maxDelay < 0) revert Errors.TokenPriceFeedMaxDelayMustBeGreaterOrEqualToZero();

    maxDelays[token] = maxDelay;
  }

  /**
    * @notice Update token to denominator token
    * @param token Base token address
    * @param dt Denominator token address
  */
  function updateTokenToDenominatorToken(address token, address dt) external restricted {
    if (token == address(0)) revert Errors.ZeroAddressNotAllowed();
    if (dt == address(0)) revert Errors.ZeroAddressNotAllowed();

    tokenToDenominatorToken[token] = dt;
  }

  /**
    * @notice Emergency pause of this oracle
  */
  function emergencyPause() external restricted whenNotPaused {
    _pause();
  }

  /**
    * @notice Emergency resume of this oracle
  */
  function emergencyResume() external restricted whenPaused {
    _unpause();
  }
}
