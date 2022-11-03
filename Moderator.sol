pragma solidity ^0.5.16;

import "./common/ERC721Enumerable.sol";
import "./common/ERC721Metadata.sol";
import "./common/Ownable.sol";
import "./common/SafeMath.sol";
import "./common/Address.sol";
import "./IEscrow.sol";
import "./IModerator.sol";

contract Moderator is IModerator, ERC721Enumerable, ERC721Metadata,Ownable {

    // max supply
    uint256 public maxSupply = 4000000; 

    // mod's total score
    mapping(uint256 => uint256) public modTotalScore;

    // mod's success score
    mapping(uint256 => uint256) public modSuccessScore;

    // mod's success rate
    mapping(uint256 => uint8) public modSuccessRate;

    // mint event
    event Mint(
        uint256 indexed modId
    );

    // update score event
    event UpdateScore(
        uint256 indexed modId,
        bool indexed ifSuccess
    );

    // escrow contract address
    address payable public escrowAddress;

    constructor() public  ERC721Metadata("Vbhex Moderators", "Mod"){

    }

    // set escrow contract address
    function setEscrow(address payable _escrow) public onlyOwner {
        IEscrow EscrowContract = IEscrow(_escrow);
        require(EscrowContract.getModAddress()==address(this),'Mod: wrong escrow contract address');
        escrowAddress = _escrow; 
    }

    // mint a new mod
    function mint() public onlyOwner {
        uint256 tokenId                     = totalSupply().add(1);
        require(tokenId <= maxSupply, 'Mod: supply reach the max limit!');
        _safeMint(_msgSender(), tokenId);
        // set default mod score
        modTotalScore[tokenId]   =   1;  
        // emit mint event
        emit Mint(
            tokenId
        );
    }

    // get mod's total supply
    function getMaxModId() external returns(uint256) {
        return totalSupply();
    }

    // get mod's owner
    function getModOwner(uint256 modId) external returns(address) {
        require(modId <= totalSupply(),'Mod: illegal moderator ID!');
        return ownerOf(modId);
    }

    // update mod's score
    function updateModScore(uint256 modId, bool ifSuccess) external returns(bool) {
        //Only Escrow contract can increase score
        require(escrowAddress == msg.sender,'Mod: only escrow contract can update mod score');
        //total score add 1
        modTotalScore[modId] = modTotalScore[modId].add(1);
        if(ifSuccess) {
            // success score add 1
            modSuccessScore[modId] = modSuccessScore[modId].add(1);
        } else if(modSuccessScore[modId] > 0) {
            modSuccessScore[modId] = modSuccessScore[modId].sub(1);
        } else {
            // nothing changed
        }
        // recount mod success rate
        modSuccessRate[modId] = uint8(modSuccessScore[modId].mul(100).div(modTotalScore[modId]));
        // emit event
        emit UpdateScore(
            modId,
            ifSuccess
        );
        return true;

    }

}