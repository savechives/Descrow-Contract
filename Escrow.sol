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

    IERC20 moderatorContract = IERC20(moderatorAddress);

    // app owner
    // appId => address
    mapping(uint256 => address) public appOwner;

    //how many seconds after order paid, can buyer make dispute
    // appId => interval
    mapping(uint256 => uint256) public appIntervalDispute;

    //how many seconds after order paid, can seller cash out order
    // appId => interval
    mapping(uint256 => uint256) public appIntervalCashOut;

    //how many seconds after dispute made, if seller does not response, buyer can cashout the refund
    // appId => interval
    mapping(uint256 => uint256) public appIntervalRefuse;

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
    mapping(uint256 => uint8) public appModCommission;

    // app owner commission
    mapping(uint256 => uint8) public appOwnerCommission;

    //after how many seconds, if seller does not refuse refund, buyer can cashout the refund.
    mapping(uint256 => mapping(uint256 => uint256)) public refuseExpired;

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
        uint8 status; //order status, 1 paid, 2 buyer ask refund, 3 completed, 4 seller refuse dispute, 5 buyer or seller appeal, so voters can vote
        uint256 refund; //disputeId
        uint256 modAId; //the mod that chosen by seller
        uint8 modAVote; // 0 not vote, 1 agree refund, 2 disagree refund.
        uint256 modBId; //the mod that chosen by buyer
        uint8 modBVote; // 0 not vote, 1 agree refund, 2 disagree refund.
        // The following info comes from app settings
        address appOwner; //app owner
        uint8 appOwnerCommission; //commission fee for app owner
        uint256 refundTime; //before when buyer can ask refund
        uint256 cashOutTime; //when can be cashed out
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
    event CreateOrder(
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

    //Appeal dispute event
    event Appeal(uint256 indexed appId, uint256 indexed orderId);

    //Vote to Agree or Disagree refund
    event Vote(
        address indexed user,
        bool indexed isAgree,
        uint256 indexed orderId,
        uint256 appId,
        uint256 price
    );

    //Refund now event
    event RefundNow(
        uint256 indexed appId,
        uint256 indexed orderId,
        uint8 indexed refundType //0 disagree win, 1 agree win, 2 seller refund
    );

    //Cash out event
    event CashOut(
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
        appMaxOrder[appId] = uint256(0);
        intervalDispute[appId] = uint256(1000000);
        intervalCashOut[appId] = uint256(1000000);
        intervalRefuse[appId] = uint256(86400);
        modCommission[appId] = uint8(1);
        appOwnerCommission[appId] = uint8(1);
        maxAppNum = appId;
        emit NewApp(appId);

        return appId;
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
            "Only app owner can set mod commission"
        );
        require(_commission > 0, "Commission must be greater than 0");
        require(_commission < 15, "Commission must be less than 15");
        modCommission[appId] = _commission;
        return true;
    }

    //Set app min votes difference
    function setAppOwnerCommission(uint256 appId, uint256 _commission)
        public
        returns (bool)
    {
        // Only app owner
        require(
            _msgSender() == appOwner[appId],
            "Only app owner can set mod commission"
        );
        require(_commission > 0, "Commission must be greater than 0");
        require(_commission < 15, "Commission must be less than 15");
        appOwnerCommission[appId] = _commission;
        return true;
    }

    //Set dispute interval timestamp
    function setIntervalDispute(uint256 appId, uint256 _timestamp)
        public
        onlyOwner
    {
        require(_timestamp > 10, "interval time too small!");
        require(_timestamp < 10000000, "interval time too big!");
        intervalDispute[appId] = _timestamp;
    }

    //Set refuse interval timestamp
    function setIntervalRefuse(uint256 appId, uint256 _timestamp)
        public
        onlyOwner
    {
        require(_timestamp > 10, "interval time too small!");
        require(_timestamp < 10000000, "interval time too big!");
        intervalRefuse[appId] = _timestamp;
    }

    //Set cash out interval timestamp
    function setIntervalCashOut(uint256 appId, uint256 _timestamp)
        public
        onlyOwner
    {
        require(_timestamp > 20, "interval time too small!");
        require(_timestamp < 10000000, "interval time too big!");
        intervalCashOut[appId] = _timestamp;
    }

    //Create Order
    function createOrder(
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
                amount > 0
        );
        //check if app order id already is already on the blockchain. PS : It is wrong to do that, as appId with appOrderId maybe duplicated, and it is acceptable.
        // if(chainOrderIdOfAppOrderId[appId][appOrderId] > 0 ) {
        //     revert("Dservice : The order is already paid");
        // }
        //Native Currency
        if (coinAddress == address(0)) {
            require(msg.value == amount, "Wrong amount or wrong value sent");
            //send BNB/ETH to this contract
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
        _order.cashOutTime = block.timestamp.add(intervalCashOut[appId]);
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
        emit CreateOrder(
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

    //confirm order received, and money will be cash out to seller's balance
    //triggled by buyer
    function confirmDone(uint256 orderId) public {
        require(
            _msgSender() == orderBook[appId][orderId].buyer,
            "Only buyer can confirm done"
        );

        require(
            orderBook[appId][orderId].status == uint8(1) ||
                orderBook[appId][orderId].status == uint8(2) ||
                orderBook[appId][orderId].status == uint8(4),
            "Order status must be equal to just paid or refund asked or dispute refused"
        );

        // cash out money to seller's balance
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
            appId,
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
            "Only buyer can make dispute"
        );

        require(
            orderBook[orderId].status == uint8(1) ||
                orderBook[orderId].status == uint8(2),
            "Order status must be equal to just paid or refund asked"
        );

        require(
            block.timestamp < orderBook[orderId].refundTime,
            "It is too late to make dispute"
        );

        require(refund > 0, "Refund amount must be bigger than 0");

        require(
            refund <= orderBook[orderId].amount,
            "Refund amount can not be bigger than paid amount"
        );

        // update order status
        if (orderBook[orderId].status == uint8(1)) {
            orderBook[orderId].status = uint8(2);
        }
        // update refund of order
        orderBook[orderId].refund = refund;
        // update refuse expired
        refuseExpired[orderId] = block.timestamp.add(
            intervalRefuse[orderBook[orderId].appId]
        );
        //emit event
        emit AskRefund(orderBook[orderId].appId, orderId, refund);
    }

    //cancel refund
    //triggled by buyer
    function cancelRefund(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].buyer,
            "Only buyer can cancel refund"
        );

        require(
            orderBook[orderId].status == uint8(2) ||
                orderBook[orderId].status == uint8(4),
            "Order status must be equal to refund asked or refund refused"
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
            "Only seller can refuse dispute"
        );

        require(
            orderBook[orderId].status == uint8(2),
            "Order status must be equal to refund asked"
        );

        //update order status to refund refused
        orderBook[orderId].status = uint8(4);

        emit RefuseRefund(orderBook[orderId].appId, orderId);
    }

    //appeal, so voters can vote
    //triggled by seller or buyer
    function appeal(uint256 orderId) public {
        require(
            _msgSender() == orderBook[orderId].seller ||
                _msgSender() == orderBook[orderId].buyer,
            "Only seller or buyer can appeal"
        );

        require(
            orderBook[orderId].status == uint8(4),
            "Order status must be equal to refund refused by seller"
        );

        //update order status to appeal dispute, ready for mods to vote
        orderBook[orderId].status = uint8(5);

        emit Appeal(orderBook[orderId].appId, orderId);
    }

    // if seller agreed refund, then refund immediately
    // else the msg.sender must deposit 1000 DService coin into it to vote agree
    function agreeRefund(uint256 orderId) public {
        //if seller agreed refund, than refund immediately
        if (_msgSender() == orderBook[orderId].seller) {
            require(
                orderBook[orderId].status == uint8(2) ||
                    orderBook[orderId].status == uint8(4),
                "order status must be at refund asked or refund refused"
            );
            sellerAgree(orderId);
        } else {
            require(
                orderBook[orderId].status == uint8(5),
                "mod can only vote on appealing status"
            );

            // if modA's owner equal to modB's owner and they are msg sender
            if (
                moderatorContract.getOwner(orderBook[orderId].modAId) ==
                moderatorContract.getOwner(orderBook[orderId].modBId)
            ) {
                // set modAVote/modBVote to voted
                orderBook[orderId].modAVote = uint8(1);
                orderBook[orderId].modBVote = uint8(1);
                refundNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId
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
                refundNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId
                );
            }
            // if voter is modA, and modA not vote yet, and modB not vote or vote disagree
            else if (
                moderatorContract.getOwner(orderBook[orderId].modAId) ==
                _msg.sender() &&
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
                    orderBook[orderId].appId
                );
            }
            // if voter is modA, and modA not vote yet, and modB vote agree
            else if (
                moderatorContract.getOwner(orderBook[orderId].modAId) ==
                _msg.sender() &&
                orderBook[orderId].modAVote == uint8(0) &&
                orderBook[orderId].modBVote == uint8(1)
            ) {
                // set modAVote to voted
                orderBook[orderId].modAVote = uint8(1);
                refundNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId
                );
            }
            // if voter is modB, and modB not vote yet, and modA not vote or vote disagree
            else if (
                moderatorContract.getOwner(orderBook[orderId].modBId) ==
                _msg.sender() &&
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
                    orderBook[orderId].appId
                );
            }
            // if voter is modB, and modB not vote yet, and modA vote agree
            else if (
                moderatorContract.getOwner(orderBook[orderId].modBId) ==
                _msg.sender() &&
                orderBook[orderId].modBVote == uint8(0) &&
                orderBook[orderId].modAVote == uint8(1)
            ) {
                // set modBVote to voted
                orderBook[orderId].modBVote = uint8(1);
                refundNow(orderId, true);
                emit Vote(
                    _msgSender(),
                    true,
                    orderId,
                    orderBook[orderId].appId
                );
            }
            // in other case , revert
            else {
                revert("Sender can not vote!");
            }
        }
    }

    // the msg.sender does not agree the refund
    function disagreeRefund(uint256 orderId) public {
        require(
            orderBook[orderId].status == uint8(5),
            "mod can only vote on appealing status"
        );

        // if modA's owner equal to modB's owner and they are msg sender
        if (
            moderatorContract.getOwner(orderBook[orderId].modAId) ==
            moderatorContract.getOwner(orderBook[orderId].modBId)
        ) {
            // set modAVote/modBVote to voted
            orderBook[orderId].modAVote = uint8(2);
            orderBook[orderId].modBVote = uint8(2);
            refundNow(orderId, false);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // if voter is app owner , and modA/modB not agree with each other.
        else if (
            orderBook[orderId].appOwner == _msgSender() &&
            ((orderBook[orderId].modAVote == uint8(2) &&
                orderBook[orderId].modBVote == uint8(1)) ||
                (orderBook[orderId].modAVote == uint8(1) &&
                    orderBook[orderId].modBVote == uint8(2)))
        ) {
            refundNow(orderId, false);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // if voter is modA, and modA not vote yet, and modB not vote or vote agree
        else if (
            moderatorContract.getOwner(orderBook[orderId].modAId) ==
            _msg.sender() &&
            orderBook[orderId].modAVote == uint8(0) &&
            (orderBook[orderId].modBVote == uint8(0) ||
                orderBook[orderId].modBVote == uint8(1))
        ) {
            // set modAVote to voted
            orderBook[orderId].modAVote = uint8(2);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // if voter is modA, and modA not vote yet, and modB vote disagree
        else if (
            moderatorContract.getOwner(orderBook[orderId].modAId) ==
            _msg.sender() &&
            orderBook[orderId].modAVote == uint8(0) &&
            orderBook[orderId].modBVote == uint8(2)
        ) {
            // set modAVote to voted
            orderBook[orderId].modAVote = uint8(2);
            refundNow(orderId, false);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // if voter is modB, and modB not vote yet, and modA not vote or vote agree
        else if (
            moderatorContract.getOwner(orderBook[orderId].modBId) ==
            _msg.sender() &&
            orderBook[orderId].modBVote == uint8(0) &&
            (orderBook[orderId].modAVote == uint8(0) ||
                orderBook[orderId].modAVote == uint8(1))
        ) {
            // set modBVote to voted
            orderBook[orderId].modBVote = uint8(2);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // if voter is modB, and modB not vote yet, and modA vote disagree
        else if (
            moderatorContract.getOwner(orderBook[orderId].modBId) ==
            _msg.sender() &&
            orderBook[orderId].modBVote == uint8(0) &&
            orderBook[orderId].modAVote == uint8(2)
        ) {
            // set modBVote to voted
            orderBook[orderId].modBVote = uint8(2);
            refundNow(orderId, false);
            emit Vote(_msgSender(), false, orderId, orderBook[orderId].appId);
        }
        // in other case , revert
        else {
            revert("Sender can not vote!");
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
            orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100));
        emit UserBalanceChanged(
                orderBook[orderId].appOwner,
                true,
                orderBook[orderId].amount.mul(orderBook[orderId].appOwnerCommission).div(100),
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
        emit RefundNow(orderBook[orderId].appId, orderId, uint8(1));
    }

    function refundNow(uint256 orderId, bool result) internal {
        // update order status to finish
        orderBook[orderId].status = uint8(3);

        // the mod who judge right decision will increase 1 score, as well as adding the mod commission
        uint8 modNum = 1;
        uint8 winVote = result ? 1 : 2;
        // if modA's owner equal to modB's owner, then just increase 1 score for the owner
        // and adding the mod commission
        if (
            moderatorContract.getOwner(orderBook[orderId].modAId) ==
            moderatorContract.getOwner(orderBook[orderId].modBId)
        ) {
            rewardMod(
                orderId,
                moderatorContract.getOwner(orderBook[orderId].modAId)
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
                    moderatorContract.getOwner(orderBook[orderId].modAId)
                );
            } else {
                rewardMod(
                    orderId,
                    moderatorContract.getOwner(orderBook[orderId].modBId)
                );
            }
        }
        // else if modA agree with modB
        else {
            // give both mods reward
            modNum = 2;
            rewardMod(
                orderId,
                moderatorContract.getOwner(orderBook[orderId].modAId)
            );
            rewardMod(
                orderId,
                moderatorContract.getOwner(orderBook[orderId].modBId)
            );
        }
        // caculate the commission fee
        uint256 finalCommission = orderBook[orderId].appOwnerCommission +
            (modNum * orderBook[orderId].modCommission);
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
            emit RefundNow(orderBook[orderId].appId, orderId, uint8(1));
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
            emit RefundNow(orderBook[orderId].appId, orderId, uint8(0));
        }
    }

    // reward mod
    // adding mod commission as well as increasing mod score
    function rewardMod(uint256 orderId, address mod) private {
        moderatorContract.increaseScore(mod, uint256(1));
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

    //seller want to cash out money from order to balance
    //or
    //buyer want to cash out money after seller either not to refuse dispute or agree dispute
    function cashOut(uint256 orderId) public {
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
        //seller cashout
        if (_msgSender() == orderBook[orderId].seller) {
            require(
                orderBook[orderId].status == uint8(1),
                "order status must be equal to 1 "
            );

            require(
                block.timestamp > orderBook[orderId].cashOutTime,
                "currently seller can not cash out, need to wait"
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
            // buyer cashout

            require(
                orderBook[orderId].status == uint8(2),
                "order status must be equal to 2 "
            );

            require(
                block.timestamp > refuseExpired[orderId],
                "currently buyer can not cash out, need to wait"
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
            revert("only seller or buyer can cash out");
        }

        orderBook[orderId].status = 3;
        emit CashOut(_msgSender(), orderBook[orderId].appId, orderId);
    }

    //withdraw from user balance
    function withdraw(uint256 _amount, address _coinAddress) public {
        //get user balance
        uint256 _balance = userBalance[_msgSender()][_coinAddress];

        require(_balance >= _amount, "Insufficient balance!");

        //descrease user balance
        userBalance[_msgSender()][_coinAddress] = _balance.sub(_amount);

        //if the coin type is ETH
        if (_coinAddress == address(0)) {
            //check balance is enough
            require(address(this).balance > _amount, "Insufficient balance");

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
