pragma solidity ^0.5.16;

interface IModerator {
    
    // get mod's owner
    function getModOwner(uint256 modId) external view returns(address);

    // get mod's total supply
    function getMaxModId() external view returns(uint256);

    // update mod's score
    function updateModScore(uint256 modId, bool ifSuccess) external returns(bool);
}