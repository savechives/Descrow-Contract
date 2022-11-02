pragma solidity ^0.5.16;

import "./common/ERC721Metadata.sol";
import "./common/Ownable.sol";
import "./common/SafeMath.sol";
import "./common/Address.sol";
import "./IEscrow.sol";

contract Moderator is IModerator, ERC721Metadata,Ownable {

    // max supply
    uint256 public maxSupply = 4000000; 

    // mod's score
    mapping(uint256 => uint256) public modScore;

    // mint event
    event Mint(
        uint256 indexed modId
    );

    // increase score event
    event increaseScore(
        uint256 indexed modId,
        uint256 indexed inScore
    );

    // decrease score event
    event increaseScore(
        uint256 indexed modId,
        uint256 indexed deScore
    );

    // escrow contract address
    address payable public escrowAddress;

    constructor() public  ERC721Metadata("Escrow's Moderators", "Mod"){
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
        _safeMint(appOwner, tokenId);
        // set default mod score
        modScore[tokenId]   =   1;  
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

    // increase mod's score
    function increaseScore(uint256 modId, uint256 inScore) external returns(bool) {
        //Only Escrow contract can increase score
        require(escrowAddress == msg.sender,'Mod: only escrow contract can call this method');

        //increase moderate score
        modScore[modId] = inScore.add(modScore[modId]);

        // emit event
        emit IncreaseScore(
            modId,
            inScore
        );

        return true;
    }

    // decrease mod's score
    function decreaseScore(uint256 modId, uint256 deScore) external returns(bool) {
        //Only Escrow contract can increase score
        require(escrowAddress == msg.sender,'Mod: only escrow contract can call this method');

        // The score of the mode must be bigger than deScore
        require(modScore[modId] >= deScore, 'Mod: the score of the mode must be bigger than deScore');
        //increase moderate score
        modScore[modId] = deScore.sub(modScore[modId]);

        // emit event
        emit DecreaseScore(
            modId,
            deScore
        );

        return true;
    }

}