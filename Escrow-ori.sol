pragma solidity ^0.5.16;

import "./common/IERC20.sol";
import "./common/Ownable.sol";
import "./common/SafeMath.sol";
import "./IEscrow.sol";
import "./IModerator.sol";

contract Escrow is IEscrow, Ownable {
    using SafeMath for uint256;
    //moderator contract
    address public moderatorAddress;

    IModerator moderatorContract = IModerator(moderatorAddress);

    // app owner
    // appId => address
    mapping(uint256 => address) public appOwner;

    //how many seconds after order paid, can buyer make dispute
    // appId => interval
    mapping(uint256 => uint256) public intervalDispute;

    //how many seconds after order paid, can seller claim order
    // appId => interval
    mapping(uint256 => uint256) public intervalClaim;

    //how many seconds after dispute made, if seller does not response, buyer can claim the refund
    // appId => interval
    mapping(uint256 => uint256) public intervalRefuse;

    // app uri
    // appId => string
    mapping(uint256 => string) public appURI;

    // app name
    // appId => string
    mapping(uint256 => string) public appName;

    // total app num
    uint256 private maxAppNum;

    // total order num
    uint256 public maxOrderId;

    // app mod commission (For each mod and app owner if possible)
    mapping(uint256 => uint8) public modCommission;

    // app owner commission
    mapping(uint256 => uint8) public appOwnerCommission;

    //after how many seconds, if seller does not refuse refund, buyer can claim the refund.
    mapping(uint256 => uint256) public refuseExpired;

    //Struct Order
    struct Order {
        uint256 id; //order id
        uint256 appId; //app   id
        uint256 amount; //order amount
        address coinAddress; //coin contract address
        address buyer; //buyer address
        address seller; //seller address
        uint256 appOrderId; //centralized app order id
        uint256 timestamp; //timestamp
        uint8 status; //order status, 1 paid, 2 buyer ask refund, 3 completed, 4 seller refuse dispute, 5 buyer or seller escalate, so voters can vote
        uint256 refund; //disputeId
        uint256 modAId; //the mod that chosen by seller
        uint8 modAVote; // 0 not vote, 1 agree refund, 2 disagree refund.
        uint256 modBId; //the mod that chosen by buyer
        uint8 modBVote; // 0 not vote, 1 agree refund, 2 disagree refund.
        // The following info comes from app settings
        address appOwner; //app owner
        uint8 appOwnerCommission; //commission fee for app owner
        uint256 refundTime; //before when buyer can ask refund
        uint256 claimTime; //when can be cashed out
        uint8 modCommission; //The commision fee in percentage to each mod, including app owner if it resolves the order
    }

    // orderId => Order
    mapping(uint256 => Order) public orderBook;

    // user balance (userAddress => mapping(coinAddress => balance))
    mapping(address => mapping(address => uint256)) public userBalance;

    //Withdraw event
    event Withdraw(
        address indexed user, //user wallet address
        uint256 indexed amount, //withdraw amount
        address indexed coinContract //withdraw coin contract
    );

    //Create new APP event
    event NewApp(uint256 indexed appId); //appId

    //Create order event
    event PayOrder(
        uint256 indexed orderId,
        uint256 indexed appOrderId,
        address indexed coinAddress,
        uint256 amount,
        address buyer,
        address seller,
        uint256 appId,
        uint256 entityId,
        uint256 modAId,
        uint256 modBId
    );

    //Confirm Done event
    event ConfirmDone(uint256 indexed appId, uint256 indexed orderId);

    //Ask refund event
    event AskRefund(
        uint256 indexed appId,
        uint256 indexed orderId,
        uint256 indexed refund
    );

    //Cancel refund event
    event CancelRefund(uint256 indexed appId, uint256 indexed orderId);

    //Refuse refund event
    event RefuseRefund(uint256 indexed appId, uint256 indexed orderId);

    //Escalate dispute event
    event Escalate(uint256 indexed appId, uint256 indexed orderId);

    //Vote to Agree or Disagree refund
    event Vote(
        address indexed user,
        bool indexed isAgree,
        uint256 indexed orderId,
        uint256 appId,
        uint8 voterType // 0 both modA&modB, 1 modA, 2 modB, 3 app Owner 
    );

    //Refund now event
    event ResolvedNow(
        uint256 indexed appId,
        uint256 indexed orderId,
        uint8 indexed refundType //0 disagree win, 1 agree win, 2 seller refund
    );

    //Cash out event
    event Claim(
        address indexed user,
        uint256 indexed appId,
        uint256 indexed orderId
    );

    //User Balance Changed event
    event UserBalanceChanged(
        address indexed user,
        bool indexed isIn,
        uint256 indexed amount,
        address coinAddress,
        uint256 appId,
        uint256 orderId
    );

    constructor() public {}

    // make the contract payable
    function() external payable {}

    function getModAddress() external returns (address)
    {
        return moderatorAddress;
    }

    // get total apps quantity
    function getTotalAppsQuantity() public view returns (uint256) {
        return maxAppNum;
    }

    // get app owner
    function getAppOwner(uint256 appId) public view returns (address) {
        return appOwner[appId];
    }

    //Create new APP
    function newApp(
        address _appOwner,
        string memory _appName,
        string memory websiteURI
    ) public onlyOwner returns (uint256) {
        uint256 appId = maxAppNum.add(1);
        appOwner[appId] = _appOwner;
        appURI[appId] = websiteURI;
        appName[appId] = _appName;
        intervalDispute[appId] = uint256(1000000);
        intervalClaim[appId] = uint256(1000000);
        intervalRefuse[appId] = uint256(86400);
        modCommission[appId] = uint8(1);
        appOwnerCommission[appId] = uint8(1);
        maxAppNum = appId;
        emit NewApp(appId);

        return appId;
    }

    //Transfer app owner to a new address
    function setAppOwner(uint256 appId, address _newOwner)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set app owner"
        );
        require(_newOwner != address(0), "Escrow: new owner is the zero address");
        appOwner[appId] = _newOwner;

        return true;
    }

    //Set mod commission
    //Only app owner
    function setModCommission(uint256 appId, uint8 _commission)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set mod commission"
        );
        require(_commission < 15, "Escrow: commission must be less than 15");
        modCommission[appId] = _commission;
        return true;
    }

    //Set app owner commission
    function setAppOwnerCommission(uint256 appId, uint8 _commission)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set app owner commission"
        );
        require(_commission < 45, "Escrow: commission must be less than 45");
        appOwnerCommission[appId] = _commission;
        return true;
    }

    //Set dispute interval
    function setIntervalDispute(uint256 appId, uint256 _seconds)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set dispute interval"
        );
        require(_seconds > 10, "Escrow: interval time too small!");
        require(_seconds < 10000000, "Escrow: interval time too big!");
        intervalDispute[appId] = _seconds;
        return true;
    }

    //Set refuse interval
    function setIntervalRefuse(uint256 appId, uint256 _seconds)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set refuse interval"
        );
        require(_seconds > 10, "Escrow: interval time too small!");
        require(_seconds < 10000000, "Escrow: interval time too big!");
        intervalRefuse[appId] = _seconds;
        return true;
    }

    //Set claim interval
    function setIntervalClaim(uint256 appId, uint256 _seconds)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Escrow: only app owner can set claim interval"
        );
        require(_seconds > 20, "Escrow: interval time too small!");
        require(_seconds < 10000000, "Escrow: interval time too big!");
        intervalClaim[appId] = _seconds;
        return true;
    }

    //Pay Order
    function payOrder(
        uint256 appId,
        uint256 amount,
        address coinAddress,
        address seller,
        uint256 appOrderId,
        uint256 entityId,
        uint256 modAId,
        uint256 modBId
    ) public payable returns (uint256) {
        require(
            entityId > 0 &&
                appId > 0 &&
                appId <= maxAppNum &&
                appOrderId > 0 &&
                amount > 0,
                "Escrow: all the ids should be bigger than 0"
        );
        //Mod Id should be validated
        uint256 maxModId = moderatorContract.getMaxModId();
        require(modAId <= maxModId && modBId <= maxModId, "Escrow: mod id is too big");
        //Native Currency
        if (coinAddress == address(0)) {
            require(msg.value == amount, "Escrow: Wrong amount or wrong value sent");
            //send native currency to this contract
            address(this).transfer(amount);
        } else {
            IERC20 buyCoinContract = IERC20(coinAddress);
            //send ERC20 to this contract
            buyCoinContract.transferFrom(msg.sender, address(this), amount);
        }
        uint256 orderId = maxOrderId.add(1);
        // store order information
        Order memory _order;
        _order.id = orderId;
        _order.appId = appId;
        _order.coinAddress = coinAddress;
        _order.amount = amount;
        _order.appOrderId = appOrderId;
        _order.buyer = _msgSender();
        _order.seller = seller;
        _order.timestamp = block.timestamp;
        _order.refundTime = block.timestamp.add(intervalDispute[appId]);
        _order.claimTime = block.timestamp.add(intervalClaim[appId]);
        _order.refund = uint256(0);
        _order.status = uint8(1);
        _order.modAId = modAId;
        _order.modAVote = uint8(0);
        _order.modBId = modBId;
        _order.modBVote = uint8(0);
        _order.appOwner = appOwner[appId];
        _order.modCommission = modCommission[appId];
        _order.appOwnerCommission = appOwnerCommission[appId];

        orderBook[orderId] = _order;
        //update max order information
        maxOrderId = orderId;
        // record the app order id on blockchain. PS : No need any more.
        // chainOrderIdOfAppOrderId[appId][appOrderId] = orderId;

        // emit event
        emit PayOrder(
            orderId,
            appOrderId,
            coinAddress,
            amount,
            _msgSender(),
            seller,
            appId,
            entityId,
            modAId,
            modBId
        );

        return orderId;
    }

    //confirm order received, and money will be sent to seller's balance
    //triggled by buyer
    function confirmDone(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].buyer,
            "Escrow: only buyer can confirm done"
        );

        require(
            orderBook[orderId].status == uint8(1) ||
                orderBook[orderId].status == uint8(2) ||
                orderBook[orderId].status == uint8(4),
            "Escrow: order status must be equal to just paid or refund asked or dispute refused"
        );

        // send money to seller's balance
        userBalance[orderBook[orderId].seller][
            orderBook[orderId].coinAddress
        ] = userBalance[orderBook[orderId].seller][
            orderBook[orderId].coinAddress
        ].add(orderBook[orderId].amount);
        emit UserBalanceChanged(
            orderBook[orderId].seller,
            true,
            orderBook[orderId].amount,
            orderBook[orderId].coinAddress,
            orderBook[orderId].appId,
            orderId
        );

        // set order status to completed
        orderBook[orderId].status == uint8(3);

        //emit event
        emit ConfirmDone(orderBook[orderId].appId, orderId);
    }

    //ask refund
    //triggled by buyer
    function askRefund(uint256 orderId, uint256 refund) public {
        require(
            _msgSender() == orderBook[orderId].buyer,
            "Escrow: only buyer can make dispute"
        );

        require(
            orderBook[orderId].status == uint8(1) ||
                orderBook[orderId].status == uint8(2),
            "Escrow: order status must be equal to just paid or refund asked"
        );

        require(
            block.timestamp < orderBook[orderId].refundTime,
            "Escrow: it is too late to make dispute"
        );

        require(refund > 0, "Escrow: refund amount must be bigger than 0");

        require(
            refund <= orderBook[orderId].amount,
            "Escrow: refund amount can not be bigger than paid amount"
        );

        // update order status
        if (orderBook[orderId].status == uint8(1)) {
            orderBook[orderId].status = uint8(2);
        }
        // update refund of order
        orderBook[orderId].refund = refund;
        // update refuse expired
        refuseExpired[orderId] = block.timestamp.add(intervalRefuse[orderBook[orderId].appId]);
        //emit event
        emit AskRefund(orderBook[orderId].appId, orderId, refund);
    }

    //cancel refund
    //triggled by buyer
    function cancelRefund(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].buyer,
            "Escrow: only buyer can cancel refund"
        );

        require(
            orderBook[orderId].status == uint8(2) ||
                orderBook[orderId].status == uint8(4),
            "Escrow: order status must be equal to refund asked or refund refused"
        );

        //update order status to paid
        orderBook[orderId].status = uint8(1);

        emit CancelRefund(orderBook[orderId].appId, orderId);
    }

    //refuse refund
    //triggled by seller
    function refuseRefund(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].seller,
            "Escrow: only seller can refuse dispute"
        );

        require(
            orderBook[orderId].status == uint8(2),
            "Escrow: order status must be equal to refund asked"
        );

        //update order status to refund refused
        orderBook[orderId].status = uint8(4);

        emit RefuseRefund(orderBook[orderId].appId, orderId);
    }

    //escalate, so mods can vote
    //triggled by seller or buyer
    function escalate(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].seller ||
                _msgSender() == orderBook[orderId].buyer,
            "Escrow: only seller or buyer can escalate"
        );

        require(
            orderBook[orderId].status == uint8(4),
            "Escrow: order status must be equal to refund refused by seller"
        );

        //update order status to escalate dispute, ready for mods to vote
        orderBook[orderId].status = uint8(5);

        emit Escalate(orderBook[orderId].appId, orderId);
    }

    // if seller agreed refund, then refund immediately
    // otherwise let mods or appOwner(if need) to judge
    function agreeRefund(uint256 orderId) public {
        //if seller agreed refund, then refund immediately
        if (_msgSender() == orderBook[orderId].seller) {
            require(
                orderBook[orderId].status == uint8(2) ||
                    orderBook[orderId].status == uint8(4) ||
                    orderBook[orderId].status == uint8(5),
                "Escrow: order status must be at refund asked or refund refused or dispute esclated"
            );
            sellerAgree(orderId);
        } else {
            require(
                orderBook[orderId].status == uint8(5),
                "Escrow: mod can only vote on dispute escalated status"
            );
            address modAWallet   =   moderatorContract.getModOwner(orderBook[orderId].modAId);
            address modBWallet   =   moderatorContract.getModOwner(orderBook[orderId].modBId);
            // if modA's owner equal to modB's owner and they are msg sender
            if (
                modAWallet == modBWallet &&
                modAWallet == _msgSender()
            ) {
                // set modAVote/modBVote to voted
                orderBook[orderId].modAVote = uint8(1);
                orderBook[orderId].modBVote = uint8(1);
                resolvedNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(0)
                );
            }
            // if voter is app owner , and modA/modB not agree with each other.
            else if (
                orderBook[orderId].appOwner == _msgSender() &&
                ((orderBook[orderId].modAVote == uint8(1) &&
                    orderBook[orderId].modBVote == uint8(2)) ||
                    (orderBook[orderId].modAVote == uint8(2) &&
                        orderBook[orderId].modBVote == uint8(1)))
            ) {
                resolvedNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(3)
                );
            }
            // if voter is modA, and modA not vote yet, and modB not vote or vote disagree
            else if (
                modAWallet ==  msg.sender &&
                orderBook[orderId].modAVote == uint8(0) &&
                (orderBook[orderId].modBVote == uint8(0) ||
                    orderBook[orderId].modBVote == uint8(2))
            ) {
                // set modAVote to voted
                orderBook[orderId].modAVote = uint8(1);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(1)
                );
            }
            // if voter is modA, and modA not vote yet, and modB vote agree
            else if (
                modAWallet == msg.sender &&
                orderBook[orderId].modAVote == uint8(0) &&
                orderBook[orderId].modBVote == uint8(1)
            ) {
                // set modAVote to voted
                orderBook[orderId].modAVote = uint8(1);
                resolvedNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(1)
                );
            }
            // if voter is modB, and modB not vote yet, and modA not vote or vote disagree
            else if (
                modBWallet == msg.sender &&
                orderBook[orderId].modBVote == uint8(0) &&
                (orderBook[orderId].modAVote == uint8(0) ||
                    orderBook[orderId].modAVote == uint8(2))
            ) {
                // set modBVote to voted
                orderBook[orderId].modBVote = uint8(1);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(2)
                );
            }
            // if voter is modB, and modB not vote yet, and modA vote agree
            else if (
                modBWallet == msg.sender &&
                orderBook[orderId].modBVote == uint8(0) &&
                orderBook[orderId].modAVote == uint8(1)
            ) {
                // set modBVote to voted
                orderBook[orderId].modBVote = uint8(1);
                resolvedNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId,
                    uint8(2)
                );
            }
            // in other case , revert
            else {
                revert("Escrow: sender can not vote!");
            }
        }
    }

    // the msg.sender does not agree the refund
    function disagreeRefund(uint256 orderId) public {
        require(
            orderBook[orderId].status == uint8(5),
            "Escrow: mod can only vote on dispute escalated status"
        );

        address modAWallet   =   moderatorContract.getModOwner(orderBook[orderId].modAId);
        address modBWallet   =   moderatorContract.getModOwner(orderBook[orderId].modBId);
        // if modA's owner equal to modB's owner and they are msg sender
        if (
            modAWallet == modBWallet && 
            modAWallet == _msgSender()
        ) {
            // set modAVote/modBVote to voted
            orderBook[orderId].modAVote = uint8(2);
            orderBook[orderId].modBVote = uint8(2);
            resolvedNow(orderId, false);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(0)
                );
        }
        // if voter is app owner , and modA/modB not agree with each other.
        else if (
            orderBook[orderId].appOwner == _msgSender() &&
            ((orderBook[orderId].modAVote == uint8(2) &&
                orderBook[orderId].modBVote == uint8(1)) ||
                (orderBook[orderId].modAVote == uint8(1) &&
                    orderBook[orderId].modBVote == uint8(2)))
        ) {
            resolvedNow(orderId, false);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(3)
                );
        }
        // if voter is modA, and modA not vote yet, and modB not vote or vote agree
        else if (
            modAWallet == msg.sender &&
            orderBook[orderId].modAVote == uint8(0) &&
            (orderBook[orderId].modBVote == uint8(0) ||
                orderBook[orderId].modBVote == uint8(1))
        ) {
            // set modAVote to voted
            orderBook[orderId].modAVote = uint8(2);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(1)
                );
        }
        // if voter is modA, and modA not vote yet, and modB vote disagree
        else if (
            modAWallet == msg.sender &&
            orderBook[orderId].modAVote == uint8(0) &&
            orderBook[orderId].modBVote == uint8(2)
        ) {
            // set modAVote to voted
            orderBook[orderId].modAVote = uint8(2);
            resolvedNow(orderId, false);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(1)
                );
        }
        // if voter is modB, and modB not vote yet, and modA not vote or vote agree
        else if (
            modBWallet == msg.sender &&
            orderBook[orderId].modBVote == uint8(0) &&
            (orderBook[orderId].modAVote == uint8(0) ||
                orderBook[orderId].modAVote == uint8(1))
        ) {
            // set modBVote to voted
            orderBook[orderId].modBVote = uint8(2);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(2)
                );
        }
        // if voter is modB, and modB not vote yet, and modA vote disagree
        else if (
            modBWallet == msg.sender &&
            orderBook[orderId].modBVote == uint8(0) &&
            orderBook[orderId].modAVote == uint8(2)
        ) {
            // set modBVote to voted
            orderBook[orderId].modBVote = uint8(2);
            resolvedNow(orderId, false);
            emit Vote(
                _msgSender(), 
                false, 
                orderId, 
                orderBook[orderId].appId,
                uint8(2)
                );
        }
        // in other case , revert
        else {
            revert("Escrow: sender can not vote!");
        }
    }

    // if seller agreed refund, then refund immediately
    function sellerAgree(uint256 orderId) internal {
        require(_msgSender() == orderBook[orderId].seller);
        // update order status to finish
        orderBook[orderId].status = uint8(3);
        // final commission is the app owner commission
        uint8 finalCommission = orderBook[orderId].appOwnerCommission;
        // add app ownner commission fee
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress] =
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress].add(
            orderBook[orderId].amount.mul(finalCommission).div(100));
        emit UserBalanceChanged(
                orderBook[orderId].appOwner,
                true,
                orderBook[orderId].amount.mul(finalCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
        // as the refund is approved, refund to buyer
        userBalance[orderBook[orderId].buyer][
            orderBook[orderId].coinAddress
        ] = userBalance[orderBook[orderId].buyer][
            orderBook[orderId].coinAddress
        ].add(orderBook[orderId].refund.mul(100 - finalCommission).div(100));
        emit UserBalanceChanged(
            orderBook[orderId].buyer,
            true,
            orderBook[orderId].refund.mul(100 - finalCommission).div(100),
            orderBook[orderId].coinAddress,
            orderBook[orderId].appId,
            orderId
        );
        // if there is amount left, then send left amount to seller
        if (orderBook[orderId].amount > orderBook[orderId].refund) {
            userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ] = userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ].add(
                    (orderBook[orderId].amount.sub(orderBook[orderId].refund))
                        .mul(100 - finalCommission)
                        .div(100)
                );
            emit UserBalanceChanged(
                orderBook[orderId].seller,
                true,
                (orderBook[orderId].amount.sub(orderBook[orderId].refund))
                    .mul(100 - finalCommission)
                    .div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
        }
        emit ResolvedNow(orderBook[orderId].appId, orderId, uint8(1));
    }

    function resolvedNow(uint256 orderId, bool result) internal {
        // update order status to finish
        orderBook[orderId].status = uint8(3);

        // the mod who judge right decision will increase 1 score, as well as adding the mod commission
        uint8 modNum = 1;
        uint8 winVote = result ? 1 : 2;
        // get the mod's owneßr wallet address
        address modAWallet = moderatorContract.getModOwner(orderBook[orderId].modAId);
        address modBWallet = moderatorContract.getModOwner(orderBook[orderId].modBId);
        // if modA's owner equal to modB's owner, then just increase 1 success score for the owner
        // and add the mod commission
        if (
            modAWallet == modBWallet
        ) {
            rewardMod(
                orderId,
                orderBook[orderId].modAId,
                modAWallet
            );
        }
        // else if modA does not agree with modB
        else if (orderBook[orderId].modAVote != orderBook[orderId].modBVote) {
            modNum = 2;
            // anyway app owner will get the mod commission
            userBalance[orderBook[orderId].appOwner][
                orderBook[orderId].coinAddress
            ] = userBalance[orderBook[orderId].appOwner][
                orderBook[orderId].coinAddress
            ].add(
                    orderBook[orderId]
                        .amount
                        .mul(orderBook[orderId].modCommission)
                        .div(100)
                );
            // the mod who vote the same as final result will give award
            if (orderBook[orderId].modAVote == winVote) {
                rewardMod(
                    orderId,
                    orderBook[orderId].modAId,
                    modAWallet
                );
                moderatorContract.updateModScore(orderBook[orderId].modBId,false);
            } else {
                rewardMod(
                    orderId,
                    orderBook[orderId].modBId,
                    modBWallet
                );
                moderatorContract.updateModScore(orderBook[orderId].modAId,false);
            }
        }
        // else if modA agree with modB
        else {
            // give both mods reward
            modNum = 2;
            rewardMod(
                orderId,
                orderBook[orderId].modAId,
                modAWallet
            );
            rewardMod(
                orderId,
                orderBook[orderId].modBId,
                modBWallet
            );
        }
        // caculate the commission fee
        uint256 finalCommission = orderBook[orderId].appOwnerCommission +
            (modNum * orderBook[orderId].modCommission);
        // send app owner commission fee
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress] =
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress].add(
            orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100));
        emit UserBalanceChanged(
                orderBook[orderId].appOwner,
                true,
                orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
        //if result is to refund, then refund to buyer, the left will be sent to seller
        //else all paid to the seller

        if (result == true) {
            // as the refund is approved, refund to buyer
            userBalance[orderBook[orderId].buyer][orderBook[orderId].coinAddress] = 
            userBalance[orderBook[orderId].buyer][orderBook[orderId].coinAddress].add(
                    orderBook[orderId].refund.mul(100 - finalCommission).div(100));
            emit UserBalanceChanged(
                orderBook[orderId].buyer,
                true,
                orderBook[orderId].refund.mul(100 - finalCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
            // if there is amount left, then send left amount to seller
            if (orderBook[orderId].amount > orderBook[orderId].refund) {
                userBalance[orderBook[orderId].seller][
                    orderBook[orderId].coinAddress
                ] = userBalance[orderBook[orderId].seller][
                    orderBook[orderId].coinAddress
                ].add(
                        (
                            orderBook[orderId].amount.sub(
                                orderBook[orderId].refund
                            )
                        ).mul(100 - finalCommission).div(100)
                    );
                emit UserBalanceChanged(
                    orderBook[orderId].seller,
                    true,
                    (orderBook[orderId].amount.sub(orderBook[orderId].refund))
                        .mul(100 - finalCommission)
                        .div(100),
                    orderBook[orderId].coinAddress,
                    orderBook[orderId].appId,
                    orderId
                );
            }
            emit ResolvedNow(orderBook[orderId].appId, orderId, uint8(1));
        } else {
            // send all the amount to the seller
            userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ] = userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ].add(
                    orderBook[orderId].amount.mul(100 - finalCommission).div(
                        100
                    )
                );
            emit UserBalanceChanged(
                orderBook[orderId].seller,
                true,
                orderBook[orderId].amount.mul(100 - finalCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
            emit ResolvedNow(orderBook[orderId].appId, orderId, uint8(0));
        }
    }

    // reward mod
    // adding mod commission as well as increasing mod score
    function rewardMod(uint256 orderId, uint256 modId, address mod) private {
        moderatorContract.updateModScore(modId, true);
        userBalance[mod][orderBook[orderId].coinAddress] = 
        userBalance[mod][orderBook[orderId].coinAddress].add(
            orderBook[orderId].amount.mul(orderBook[orderId].modCommission).div(100));
        emit UserBalanceChanged(
                mod,
                true,
                orderBook[orderId].amount.mul(orderBook[orderId].modCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
    }

    //seller want to claim money from order to balance
    //or
    //buyer want to claim money after seller either not to refuse dispute or agree dispute
    function claim(uint256 orderId) public {
        // final commission is the app owner commission
        uint8 finalCommission = orderBook[orderId].appOwnerCommission;
        // add app ownner commission fee
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress] =
        userBalance[orderBook[orderId].appOwner][orderBook[orderId].coinAddress].add(
            orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100));
        emit UserBalanceChanged(
                orderBook[orderId].appOwner,
                true,
                orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
        //seller claim
        if (_msgSender() == orderBook[orderId].seller) {
            require(
                orderBook[orderId].status == uint8(1),
                "Escrow: order status must be equal to 1 "
            );

            require(
                block.timestamp > orderBook[orderId].claimTime,
                "Escrow: currently seller can not claim, need to wait"
            );
            // send all the amount to the seller
            userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ] = userBalance[orderBook[orderId].seller][
                orderBook[orderId].coinAddress
            ].add(
                    orderBook[orderId].amount.mul(100 - finalCommission).div(
                        100
                    )
                );
            emit UserBalanceChanged(
                orderBook[orderId].seller,
                true,
                orderBook[orderId].amount.mul(100 - finalCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
            
        } else if (_msgSender() == orderBook[orderId].buyer) {
            // buyer claim

            require(
                orderBook[orderId].status == uint8(2),
                "Escrow: order status must be equal to 2 "
            );

            require(
                block.timestamp > refuseExpired[orderId],
                "Escrow: currently buyer can not claim, need to wait"
            );
            // refund to buyer
            userBalance[orderBook[orderId].buyer][orderBook[orderId].coinAddress] = 
            userBalance[orderBook[orderId].buyer][orderBook[orderId].coinAddress].add(
                    orderBook[orderId].refund.mul(100 - finalCommission).div(100));
            emit UserBalanceChanged(
                orderBook[orderId].buyer,
                true,
                orderBook[orderId].refund.mul(100 - finalCommission).div(100),
                orderBook[orderId].coinAddress,
                orderBook[orderId].appId,
                orderId
            );
            // if there is amount left, then send left amount to seller
            if (orderBook[orderId].amount > orderBook[orderId].refund) {
                userBalance[orderBook[orderId].seller][
                    orderBook[orderId].coinAddress
                ] = userBalance[orderBook[orderId].seller][
                    orderBook[orderId].coinAddress
                ].add(
                        (
                            orderBook[orderId].amount.sub(
                                orderBook[orderId].refund
                            )
                        ).mul(100 - finalCommission).div(100)
                    );
                emit UserBalanceChanged(
                    orderBook[orderId].seller,
                    true,
                    (orderBook[orderId].amount.sub(orderBook[orderId].refund))
                        .mul(100 - finalCommission)
                        .div(100),
                    orderBook[orderId].coinAddress,
                    orderBook[orderId].appId,
                    orderId
                );
            }
            
        } else {
            revert("Escrow: only seller or buyer can claim");
        }

        orderBook[orderId].status = 3;
        emit Claim(_msgSender(), orderBook[orderId].appId, orderId);
    }

    //withdraw from user balance
    function withdraw(uint256 _amount, address _coinAddress) public {
        //get user balance
        uint256 _balance = userBalance[_msgSender()][_coinAddress];

        require(_balance >= _amount, "Escrow: insufficient balance!");

        //descrease user balance
        userBalance[_msgSender()][_coinAddress] = _balance.sub(_amount);

        //if the coin type is ETH
        if (_coinAddress == address(0)) {
            //check balance is enough
            require(address(this).balance > _amount, "Escrow: insufficient balance");

            msg.sender.transfer(_amount);
        } else {
            //if the coin type is ERC20

            IERC20 _token = IERC20(_coinAddress);

            _token.transfer(msg.sender, _amount);
        }

        //emit withdraw event
        emit Withdraw(msg.sender, _amount, _coinAddress);
    }
}
