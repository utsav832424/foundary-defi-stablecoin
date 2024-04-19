// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.4/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Utsav Bhiakdiya
 * @notice This library is used to check the Chainlink oracle for stale data.
 * If a price is stale, the function will revert, and render the DSCEngine unusable - this is by design.
 * We want the DSCEngine to freeze if prices become stale.
 *
 * So if the chainlink network explodes and you have a lot of money locked in the protocol... to bad.
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60

    function staleCheckLatestRoundData(AggregatorV3Interface pricefeed)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            pricefeed.latestRoundData();

        uint256 secondSince = block.timestamp - updatedAt;
        if (secondSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
