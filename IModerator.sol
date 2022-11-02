pragma solidity ^0.5.16;

interface IModerator {
    
    // get mod's owner
    function getModOwner(uint256 modId) external returns(address);

    // get mod's total supply
    function getMaxModId() external returns(uint256);

    // increase mod's score
    function increaseScore(uint256 modId, uint256 inScore) external returns(bool);

    // decrease mod's score
    function decreaseScore(uint256 modId, uint256 deScore) external returns(bool);
}