// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./utils/Ownable.sol";

contract Exchange is Pausable, Ownable {
   
    using SafeMath for uint256;

    uint256 public eventId = 0;
    uint256 public ODD_DECIMALS = 10**4; // 1*10**4 = 10000 => 1.000
    uint256 public CURRENCY_DECIMALS = 10**7; 
    uint256[] public eventIds;
    mapping(uint256 => Event) public events;
    mapping(address => uint256[]) public myEvents;

 
    struct Fraction {
        uint256 pool;           /* (Pool) Total pool amount (ETH in WEI) */
        uint256 cost;           /* (VF) Fraction Cost (ETH in WEI) */
        uint256 odd;            /* (Odd) Odd of Fraction (in 10**4) (ex : 2.410 = 2410) */
        /* IN + OUT */
        uint256 amount;         /* (#F) Total amount of fractions (in 10**18)  */
        /* IN */
        uint256 inPool;                 /* (In) Total amount Absolute of fractions in pool (in 10**18) */
        uint256 relIn;            /* (#In) Relative amount of fractions in pool (in 10**18) */
        mapping(address => uint256) inPoolBalances;   /* (#In[]) Relative amount of fractions in pool per address (in 10**18)*/
        /* OUT */
        uint256 outPool;                 /* (Out) Total amount of fractions off pool (in 10**18) */
        uint256 relOut;            /* (#Out) Relative amount of fractions off pool (in 10**18) */
        mapping(address => uint256) outPoolBalances;   /* (#Out[])Relative amount of fractions off pool per address (in 10**18)*/
        /* Fees */
        uint256 fees;                       /* Absolute Amount of Fees available (in 10**18)  */
        uint256 liqAmount;                      /* Absolute Amount of Fractions in liquidity */
        mapping(address => uint256) liquidity;  /* Liquidity of Address - absolute values */
        // TO DO : Use fees for something
    }

    struct ResultSpace {
        uint256 id;                         /* Result Space External ID - IPFS Mapping*/
        uint256 resultId;                   /* Result Space ID */
        Fraction fraction;                  /* Amount of Fractions existent */
        mapping(address => bool) tookWinnings; /* See if Winnings were taken */
    }

    struct Event {
        string name; /* Event name */
        mapping(uint256 => ResultSpace) resultSpaces;
        uint256 result; /* result space id (when finalized) */
        string urlOracle; /* URL that determines the result */
        bool isResolved; /* If Resolved */
    }    

    event CreateEvent(uint256 indexed id, string indexed name);
    event BuyEvent(uint256 indexed id, uint256 indexed resultSpaceId, uint256 fractionAmount, uint256 fractionCost, address indexed buyer);
    event CloseEvent(uint256 indexed id, uint256 indexed resultSpaceId);
    event WithdrawEvent(uint256 indexed id, uint256 winAmount, address indexed buyer);
    event SellEvent(uint256 indexed id, uint256 liquidateAmount, address indexed seller);

    constructor() public {
       
    }

    function isEventOpen(uint256 _eventId) public returns (bool success){
        return (events[_eventId].isResolved == false);
    }

    function isEventClosed(uint256 _eventId) public returns (bool success){
        return (events[_eventId].isResolved == true);
    }

    function createEvent(uint256[] memory _resultSpaceIds /* Descriptions */, string memory _urlOracle, string memory _eventName) payable public onlyOwner returns (bool success) {
        require(_resultSpaceIds.length == 2, "Result Spaces need to be 2 "); 
        uint256 resultId = 1;
        uint256 fractionAmount = 100*CURRENCY_DECIMALS;
        uint256 initialFractionCost = msg.value.div(_resultSpaceIds.length).div(fractionAmount); /* Initial Amount */
        require(initialFractionCost > 0, "Initial Fraction Cost has to be > 0"); /* Initial Fraction Cost has to be > 0 */

        /* Create Event */
        Event storage _event = events[eventId];
        _event.name = _eventName;
        _event.urlOracle = _urlOracle;
        _event.isResolved = false;

        /* Create the Result spaces */
        for (uint i = 0; i < _resultSpaceIds.length; i++) {

            ResultSpace storage resultSpace = _event.resultSpaces[resultId];

            resultSpace.resultId = resultId;
            resultSpace.id = _resultSpaceIds[i];

            Fraction storage fraction = resultSpace.fraction;
            fraction.pool = msg.value.div(_resultSpaceIds.length);
            fraction.cost = initialFractionCost;
            fraction.odd = _resultSpaceIds.length*ODD_DECIMALS;
            fraction.amount = fractionAmount;
            fraction.inPool = fractionAmount;
            fraction.relIn = fractionAmount;
            fraction.outPool = 0;
            fraction.relOut = 0;
            fraction.fees = 0;
            fraction.liqAmount = 0;

            resultId = resultId + 1;
            _event.resultSpaces[resultId].fraction.inPoolBalances[address(this)] = fractionAmount;
        }

        eventIds.push(eventId);
        emit CreateEvent(eventId, _eventName);
        eventId = eventId + 1;
        return true;
    }

    function addLiquidity(uint256 _eventId) payable public returns (bool success) {
        require(isEventOpen(_eventId));
        require(msg.value > 0, "Amount has to be > 0");

        ResultSpace storage resultSpace_opp = events[_eventId].resultSpaces[1];
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[2];

        uint256 poolA2 = 0;
        uint256 poolB2 = 0;
        uint256 FA2 = 0;
        uint256 FB2 = 0;
        uint256 ratio = 50; /* 50% */ // resultSpace_opp.fraction.pool.div(resultSpace.fraction.pool)

        /* Pool A2 */
        poolA2 = resultSpace.fraction.pool.add(msg.value.mul(ratio).div(100));
        /* Pool B2 */
        poolB2 = resultSpace_opp.fraction.pool.add(msg.value.mul(ratio).div(100));

        /* FA2 */
        FA2 = (poolA2.mul(resultSpace.fraction.amount)).div(resultSpace.fraction.pool);
        /* FB2 */
        FB2 = (poolB2.mul(resultSpace_opp.fraction.amount)).div(resultSpace_opp.fraction.pool);

        resultSpace.fraction.pool = poolA2;
        resultSpace_opp.fraction.pool = poolB2;

        uint256 fractionsToAddA = FA2.sub(resultSpace.fraction.amount);
        uint256 fractionsToAddB = FB2.sub(resultSpace_opp.fraction.amount);

        uint256 inPoolA2 = resultSpace.fraction.inPool.add(fractionsToAddA);
        uint256 inPoolB2 = resultSpace_opp.fraction.inPool.add(fractionsToAddB);

        uint256 relIn2 = fractionsToAddA;
        uint256 relIn2_opp = fractionsToAddB;

        if(resultSpace.fraction.relIn > 0){
            relIn2 = inPoolA2.mul(resultSpace.fraction.relIn).div(resultSpace.fraction.inPool);
        }
        if(resultSpace_opp.fraction.relIn > 0){
            relIn2_opp = inPoolB2.mul(resultSpace_opp.fraction.relIn).div(resultSpace_opp.fraction.inPool);
        }        

        /* INA2 */
        resultSpace.fraction.inPool = inPoolA2;
        /* INB2 */
        resultSpace_opp.fraction.inPool = inPoolB2;

        /* INA[]2 */
        resultSpace.fraction.inPoolBalances[msg.sender] = resultSpace.fraction.inPoolBalances[msg.sender].add(relIn2.sub(resultSpace.fraction.relIn));
        /* INB[]2 */
        resultSpace_opp.fraction.inPoolBalances[msg.sender] = resultSpace_opp.fraction.inPoolBalances[msg.sender].add(relIn2_opp.sub(resultSpace_opp.fraction.relIn));

        /* LiqA[]2 */
        resultSpace.fraction.liquidity[msg.sender] = resultSpace.fraction.liquidity[msg.sender].add(fractionsToAddA);
        /* LiqB[]2 */
        resultSpace_opp.fraction.liquidity[msg.sender] = resultSpace_opp.fraction.liquidity[msg.sender].add(fractionsToAddB);

        /* #INA2 */
        resultSpace.fraction.relIn = relIn2;
        /* #INB2 */
        resultSpace_opp.fraction.relIn = relIn2_opp;

        resultSpace.fraction.amount = FA2;
        resultSpace_opp.fraction.amount = FB2;

        /* Add Liquidity Amount */
        resultSpace.fraction.liqAmount = resultSpace.fraction.liqAmount.add(fractionsToAddA);
        resultSpace_opp.fraction.liqAmount = resultSpace.fraction.liqAmount.add(fractionsToAddB);
        
        myEvents[msg.sender].push(_eventId);
    }

    function removeLiquidity(uint256 _eventId) public returns (bool success) {

        ResultSpace storage resultSpace_opp = events[_eventId].resultSpaces[1];
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[2];
        
        require(resultSpace.fraction.liquidity[msg.sender] > 0, "Liquidity has to bigger than 0");
        require(resultSpace_opp.fraction.liquidity[msg.sender] > 0, "Liquidity has to bigger than 0");

        uint256 poolA2 = 0;
        uint256 poolB2 = 0;

        uint256 liqPoolAfromUser = resultSpace.fraction.liquidity[msg.sender].mul(resultSpace.fraction.pool).div(resultSpace.fraction.amount);
        uint256 liqPoolBfromUser = resultSpace_opp.fraction.liquidity[msg.sender].mul(resultSpace_opp.fraction.pool).div(resultSpace_opp.fraction.amount);
        
        /* Pool A2 */
        resultSpace.fraction.pool = resultSpace.fraction.pool.sub(liqPoolAfromUser);
        /* Pool B2 */
        resultSpace_opp.fraction.pool = resultSpace_opp.fraction.pool.sub(liqPoolBfromUser);

        /* FA2 */
        resultSpace.fraction.amount = resultSpace.fraction.amount.sub(resultSpace.fraction.liquidity[msg.sender]);
        /* FB2 */
        resultSpace_opp.fraction.amount = resultSpace_opp.fraction.amount.sub(resultSpace_opp.fraction.liquidity[msg.sender]);

        /* INA2 */
        uint256 inPoolA2 = resultSpace.fraction.inPool.sub(resultSpace.fraction.liquidity[msg.sender]);
        /* INB2 */
        uint256 inPoolB2 = resultSpace_opp.fraction.inPool.sub(resultSpace_opp.fraction.liquidity[msg.sender]);

        /* #INA2 */
        uint256 relAIn = resultSpace.fraction.relIn.mul(inPoolA2).div(resultSpace.fraction.inPool);
        /* #INB2 */
        uint256 relBIn = resultSpace_opp.fraction.relIn.mul(inPoolB2).div(resultSpace_opp.fraction.inPool);

        /* Initial Fractions Amount */
        uint256 initialFractionsA = resultSpace.fraction.inPoolBalances[msg.sender].mul(resultSpace.fraction.inPool).div(resultSpace.fraction.relIn);
        uint256 initialFractionsB = resultSpace_opp.fraction.inPoolBalances[msg.sender].mul(resultSpace_opp.fraction.inPool).div(resultSpace_opp.fraction.relIn);

        /* INA[]2 */
        resultSpace.fraction.inPoolBalances[msg.sender] = relAIn.mul(initialFractionsA.sub(resultSpace.fraction.liquidity[msg.sender])).div(inPoolA2);
        /* INB[]2 */
        resultSpace_opp.fraction.inPoolBalances[msg.sender] = relBIn.mul(initialFractionsB.sub(resultSpace_opp.fraction.liquidity[msg.sender])).div(inPoolB2);

        resultSpace.fraction.inPool = inPoolA2;
        resultSpace_opp.fraction.inPool = inPoolB2;

        resultSpace.fraction.relIn = relAIn;
        resultSpace_opp.fraction.relIn = relBIn;

        /* Remove Liquidity Amount */
        resultSpace.fraction.liqAmount = resultSpace.fraction.liqAmount.sub(resultSpace.fraction.liquidity[msg.sender]);
        resultSpace_opp.fraction.liqAmount = resultSpace_opp.fraction.liqAmount.sub(resultSpace_opp.fraction.liquidity[msg.sender]);

        /* LiqA[]2 */
        resultSpace.fraction.liquidity[msg.sender] = 0;
        /* LiqB[]2 */
        resultSpace_opp.fraction.liquidity[msg.sender] = 0;

        uint256 totalLiquidity = liqPoolAfromUser.mul(resultSpace.fraction.cost).add(liqPoolBfromUser.mul(resultSpace_opp.fraction.cost));
        /* Remove Liquidity */
        msg.sender.transfer(totalLiquidity);
    }

    function buy(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) payable public returns (bool success) {
        require(isEventOpen(_eventId));
        require(_fractionsAmount > 0, "Amount has to be > 0");

        uint256 _oppResSpaceId = 1;
        if(_resultSpaceId == 1){_oppResSpaceId = 2;}

        ResultSpace storage resultSpace_opp = events[_eventId].resultSpaces[_oppResSpaceId];
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[_resultSpaceId];

        uint256 marketValue =  getFractionsCost(_eventId, _resultSpaceId, _fractionsAmount);
        uint256 previousFractionCost = resultSpace.fraction.cost;

        uint256 slipage = getSlipageOnBuy(_eventId, _resultSpaceId, _fractionsAmount);
        require(slipage < 3, "Slipage has to be less than 3");

        require(msg.value == marketValue, "Tx value has to be equal to payable sent"); 

        /* Pool A2 */
        resultSpace.fraction.pool = resultSpace.fraction.pool.add(marketValue);
        /* Odd A2 */
        resultSpace.fraction.odd = 1*ODD_DECIMALS + (resultSpace_opp.fraction.pool.mul(ODD_DECIMALS).div(resultSpace.fraction.pool));
        /* Odd B2 */
        resultSpace_opp.fraction.odd = 1*ODD_DECIMALS + (resultSpace.fraction.pool.mul(ODD_DECIMALS).div(resultSpace_opp.fraction.pool));
        /* VF A2 */
        resultSpace.fraction.cost = resultSpace.fraction.pool.div(resultSpace.fraction.amount);
        /* VF B2 */
        resultSpace_opp.fraction.cost = resultSpace_opp.fraction.pool.div(resultSpace_opp.fraction.amount);
        /* #In A2 */
        uint256 relIn2 = _fractionsAmount;
        if(resultSpace.fraction.relIn > 0){
            relIn2 = resultSpace.fraction.relIn.div(1 - (previousFractionCost.div(resultSpace.fraction.relIn)));
        }
        /* #In[] A2 */
        resultSpace.fraction.inPoolBalances[msg.sender] = relIn2.sub(resultSpace.fraction.relIn);
        resultSpace.fraction.relIn = relIn2;
        myEvents[msg.sender].push(_eventId);
        emit BuyEvent(_eventId, _resultSpaceId, _fractionsAmount, previousFractionCost, msg.sender);
        return true;
    }

    function sell(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) public returns (bool success) {
        require(isEventOpen(_eventId));
        require(_fractionsAmount > 0, "Amount has to be > 0");
        
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[_resultSpaceId];
        uint256 _oppResSpaceId = 1;
        if(_resultSpaceId == 1){_oppResSpaceId = 2;}
        ResultSpace storage resultSpace_opp = events[_eventId].resultSpaces[_oppResSpaceId];

        uint256 fractionsAmountRelative = (_fractionsAmount.mul(resultSpace.fraction.relOut)).div(resultSpace.fraction.outPool);
        require(resultSpace.fraction.outPoolBalances[msg.sender] > fractionsAmountRelative, "No Balance to Liquidate");

        uint256 slipage = getSlipageOnSell(_eventId, _resultSpaceId, _fractionsAmount);
        require(slipage < 3, "Slipage has to be less than 3");

        uint256 marketValue = _fractionsAmount.mul(resultSpace.fraction.cost);

        /* #Out[] A2 */
        resultSpace.fraction.outPoolBalances[msg.sender] = resultSpace.fraction.outPoolBalances[msg.sender].sub(fractionsAmountRelative);
        /* Out A2 */
        resultSpace.fraction.outPool = resultSpace.fraction.outPool.sub(_fractionsAmount);
        /* #Out A2 */
        resultSpace.fraction.relOut = resultSpace.fraction.relOut.sub(fractionsAmountRelative);
        /* In A2 */
        resultSpace.fraction.inPool = resultSpace.fraction.inPool.add(_fractionsAmount);
        /* Pool A2 */
        resultSpace.fraction.pool = resultSpace.fraction.pool.sub(marketValue);
        /* Odd A2 */
        resultSpace.fraction.odd = 1*ODD_DECIMALS + (resultSpace_opp.fraction.pool.mul(ODD_DECIMALS).div(resultSpace.fraction.pool));
        /* Odd B2 */
        resultSpace_opp.fraction.odd = 1*ODD_DECIMALS + (resultSpace.fraction.pool.mul(ODD_DECIMALS).div(resultSpace_opp.fraction.pool));
        /* VF A2 */
        resultSpace.fraction.cost = resultSpace.fraction.pool.div(resultSpace.fraction.amount);
        /* VF B2 */
        resultSpace_opp.fraction.cost = resultSpace_opp.fraction.pool.div(resultSpace_opp.fraction.amount);
      
        /* Liquidate the pool capital to the seller */
        msg.sender.transfer(marketValue);

        /* Winnings taken */
        emit SellEvent(_eventId, marketValue, msg.sender);
        return true;
    }

    function getSlipageOnSell(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) view public returns (uint256 slipage) {
        ResultSpace memory resultSpace = events[_eventId].resultSpaces[_resultSpaceId];
        uint256 marketValue = getFractionsCost(_eventId, _resultSpaceId, _fractionsAmount);
        uint256 newValue = (resultSpace.fraction.pool.sub(marketValue)).div(resultSpace.fraction.amount);
        return newValue.mul(100).div(marketValue);
    }

    function getSlipageOnBuy(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) view public returns (uint256 slipage) {
        ResultSpace memory resultSpace = events[_eventId].resultSpaces[_resultSpaceId];
        uint256 marketValue = getFractionsCost(_eventId, _resultSpaceId, _fractionsAmount);
        uint256 newValue = (resultSpace.fraction.pool.sub(marketValue)).div(resultSpace.fraction.amount);
        return marketValue.mul(100).div(newValue);
    }

    function getFractionsCost(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) view public returns (uint256) {
        ResultSpace memory resultSpace = events[_eventId].resultSpaces[_resultSpaceId];
        return _fractionsAmount.mul(resultSpace.fraction.cost);
    }

    function pullFractions(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) public returns (bool success) {
        require(isEventOpen(_eventId));
        require(_fractionsAmount > 0, "Amount has to be > 0");

        ResultSpace storage resultSpace = events[_eventId].resultSpaces[_resultSpaceId];        
        /* #FT */
        uint256 fractionsAmountRelative = (_fractionsAmount.mul(resultSpace.fraction.relIn)).div(resultSpace.fraction.inPool);
        require(resultSpace.fraction.inPoolBalances[msg.sender] > fractionsAmountRelative, "No Balance to Pull Fractions");

        uint256 fractionsOutsideOfLiquidity = resultSpace.fraction.relIn.mul(resultSpace.fraction.inPoolBalances[msg.sender]).div(resultSpace.fraction.inPool);
        require(_fractionsAmount < fractionsOutsideOfLiquidity, "Amount of Fractions outside of liquidity have to be bigger than proposed"); 

        /* #In[] A2 */
        resultSpace.fraction.inPoolBalances[msg.sender] = resultSpace.fraction.inPoolBalances[msg.sender].sub(fractionsAmountRelative);
        /* In A2 */
        resultSpace.fraction.inPool = resultSpace.fraction.inPool.sub(_fractionsAmount);
        /* #In A2 */
        resultSpace.fraction.relIn = resultSpace.fraction.relIn.sub(fractionsAmountRelative);

        uint256 out2 = resultSpace.fraction.outPool.add(_fractionsAmount);
        uint256 relOut2 = (resultSpace.fraction.relOut.mul(out2)).div(resultSpace.fraction.outPool);

        /* #Out[] A2 */
        resultSpace.fraction.outPoolBalances[msg.sender] = relOut2.sub(resultSpace.fraction.relOut);
        /* #Out A2 */
        resultSpace.fraction.relOut = relOut2;
        /* Out A2 */
        resultSpace.fraction.outPool = out2;

        return true;
    }

    function pushFractions(uint256 _eventId, uint256 _resultSpaceId, uint256 _fractionsAmount) public returns (bool success) {
        require(isEventOpen(_eventId));
        require(_fractionsAmount > 0, "Amount has to be > 0");

        ResultSpace storage resultSpace = events[_eventId].resultSpaces[_resultSpaceId];

        /* #FT */
        uint256 fractionsAmountRelative = (_fractionsAmount.mul(resultSpace.fraction.relOut)).div(resultSpace.fraction.outPool);
        require(resultSpace.fraction.outPoolBalances[msg.sender] > fractionsAmountRelative, "No Balance to Pull Fractions");
 
        /* #Out[] A2 */
        resultSpace.fraction.outPoolBalances[msg.sender] = resultSpace.fraction.outPoolBalances[msg.sender].sub(fractionsAmountRelative);
        /* Out A2 */
        resultSpace.fraction.outPool = resultSpace.fraction.outPool.sub(_fractionsAmount);
        /* #Out A2 */
        resultSpace.fraction.relOut = resultSpace.fraction.relOut.sub(fractionsAmountRelative);

        uint256 in2 = resultSpace.fraction.inPool.add(_fractionsAmount);
        uint256 relIn2 = (resultSpace.fraction.relIn.mul(in2)).div(resultSpace.fraction.inPool);

        /* #Int[] A2 */
        resultSpace.fraction.inPoolBalances[msg.sender] = relIn2.sub(resultSpace.fraction.relIn);
        /* #In A2 */
        resultSpace.fraction.relIn = relIn2;
        /* In A2 */
        resultSpace.fraction.inPool = in2;

        return true;
    }

    /* Event Resolution */
    function resolveEvent(uint256 _eventId, uint256 _resultId) public onlyOwner returns (bool success) {
        require(isEventOpen(_eventId));
        /* Confirm it exists */
        require((_resultId > 0) && (_resultId < 3));
        /* Set the result */
        events[_eventId].result = _resultId;
        /* Close Event */
        events[_eventId].isResolved = true;
        emit CloseEvent(_eventId, _resultId);
    }

    function withdrawWins(uint256 _eventId, uint256 _resultSpaceId) public returns (bool success) {

        require(isEventClosed(_eventId), "Event has to be closed");
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[_resultSpaceId];
        require(events[_eventId].result == _resultSpaceId, "Result Space is not the winner");
        require(resultSpace.tookWinnings[msg.sender] == false, "Winning already taken");

        /* Get Win Amount */
        uint256 absoluteFractionsIn = (resultSpace.fraction.inPoolBalances[msg.sender].mul(resultSpace.fraction.inPool)).div(resultSpace.fraction.relIn);
        uint256 absoluteFractionsOut = (resultSpace.fraction.outPoolBalances[msg.sender].mul(resultSpace.fraction.outPool)).div(resultSpace.fraction.relOut);
        uint256 winningAmount = ((absoluteFractionsOut.add(absoluteFractionsIn)).mul(resultSpace.fraction.cost).mul(resultSpace.fraction.odd)).div(ODD_DECIMALS.mul(CURRENCY_DECIMALS));

        /* Send Winnings */
        msg.sender.transfer(winningAmount);

        /* Winnings taken */
        events[_eventId].resultSpaces[_resultSpaceId].tookWinnings[msg.sender] = true;
        emit WithdrawEvent(_eventId, winningAmount, msg.sender);
    }

    /* Get All Events */
    function getEvents() view public returns (uint256[] memory event_ids) {
        return eventIds;
    }

    /* Get Event Date */
    function getEventData(uint256 _eventId) view public returns (string memory, uint256, string memory, bool) {
        Event memory _event = events[_eventId];
        /* Return Event Data */
        return (_event.name, _event.result, _event.urlOracle, _event.isResolved);
    }

    /* Get Result Space Date */
    function getResultSpaceData(uint256 _eventId, uint256 resultSpace_id) view public returns (
        uint256 _id, uint256 _resultId, uint256 _pool, uint256 _cost, uint256 _odd, 
        uint256 _amount, uint256 _in, uint256 _out, uint256 _fees, uint256 _liqAmount
    ) {
        ResultSpace memory resultSpace = events[_eventId].resultSpaces[resultSpace_id];

        return (resultSpace.id, resultSpace.resultId, resultSpace.fraction.pool, resultSpace.fraction.cost,
        resultSpace.fraction.odd, resultSpace.fraction.amount, resultSpace.fraction.inPool, resultSpace.fraction.outPool,
        resultSpace.fraction.fees, resultSpace.fraction.liqAmount);
    }

    /* Get Portfolio of My events based on address */
    function getMyEvents() view public returns (uint256[] memory){
        return myEvents[msg.sender];
    }

    /* Get Portfolio of My Holdings/Liquidity on Event Data based on address (IN / OUT / Liquidity for each type) */
    function getMyEventHoldings(uint256 _eventId) view public returns (uint256, uint256, uint256, uint256, uint256, uint256){
        /* TO DO */
        ResultSpace storage resultSpace = events[_eventId].resultSpaces[1];
        ResultSpace storage resultSpace_opp = events[_eventId].resultSpaces[2];

        return (
            resultSpace.fraction.inPoolBalances[msg.sender], resultSpace.fraction.outPoolBalances[msg.sender], resultSpace.fraction.liquidity[msg.sender],
            resultSpace_opp.fraction.inPoolBalances[msg.sender], resultSpace_opp.fraction.outPoolBalances[msg.sender], resultSpace_opp.fraction.liquidity[msg.sender]
            );
    }

   function removeOtherERC20Tokens(address _tokenAddress, address _to) external onlyOwner {
        ERC20 erc20Token = ERC20(_tokenAddress);
        erc20Token.transfer(_to, erc20Token.balanceOf(address(this)));
    } 
}