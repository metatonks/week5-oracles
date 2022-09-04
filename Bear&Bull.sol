// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Chainlink Imports
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// This import includes functions from both ./KeeperBase.sol and
// ./interfaces/KeeperCompatibleInterface.sol
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
// Randomness
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// Dev imports. This only works on a local dev network
// and will not work on any test or main livenets.
import "hardhat/console.sol";

contract BullBear is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, KeeperCompatibleInterface, VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface COORDINATOR;

    // Your subscription ID.
    uint64 s_subscriptionId = 21471;

    // Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address vrfCoordinator = 0x6168499c0cFfCaCD319c818142124B7A15E857ab;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 keyHash = 0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 numWords =  1;

    uint256 public s_requestId;
    address s_owner;

    uint256 private constant ROLL_IN_PROGRESS = 42;
    uint256 public randomResult; // Set to public for ease of testing

    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;
    uint public /*immutable*/ interval;
    uint public lastTimeStamp;

    AggregatorV3Interface public priceFeed;
    int256 public currentPrice;

    // IPFS URIs for the dynamic nft graphics/metadata.
    // NOTE: These connect to my IPFS Companion node.
    // You should upload the contents of the /ipfs folder to your own node for development.
    // ipfs://bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q
    string[] bullUrisIpfs = [
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/gamer_bull.json",
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/party_bull.json",
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/simple_bull.json"
    ];
    string[] bearUrisIpfs = [
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/beanie_bear.json",
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/coolio_bear.json",
        "https://ipfs.io/ipfs/bafybeih7hyjera6axlpke2llenpzyefmbzvqxz7zt4efpq52slvd67nt2q/simple_bear.json"
    ];

    event TokensUpdated(string marketTrend);
    event RollStarted(uint256 indexed requestId);
    event RollCompleted(uint256 indexed requestId, uint256 indexed result);

    constructor(uint updateInterval, address _priceFeed) ERC721("Bull&Bear", "BBTK") VRFConsumerBaseV2(vrfCoordinator) {
        // Set hard coded as same for each deployment on Rinkeby
        //uint updateInterval = 60; // Need to wait a sufficient time for oracle query
        //address _priceFeed = 0xECe365B379E1dD183B20fc5f022230C044d51404;
 
        // Setup randomness calls
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
 
        // Sets the keeper update interval
        interval = updateInterval;
        lastTimeStamp = block.timestamp;

        // Sets the price feed address to
        // BTC/USD price feed contract address on rinkeby: https://rinkeby.etherscan.io/address/0xECe365B379E1dD183B20fc5f022230C044d51404
        // or the MockPriceFeed contract
        priceFeed = AggregatorV3Interface(_priceFeed);

        currentPrice = getLatestPrice();
    }

    // Quick function to set price for easier testing
    function setCurrentPrice(int256 _price) public onlyOwner {
        currentPrice = _price;
    }

    function safeMint(address to) public {
        // Current counter value will be the minted token's token ID.
        uint256 tokenId = _tokenIdCounter.current();

        // Increment it so next time it's correct when we call .current()
        _tokenIdCounter.increment();

        // Mint the token
        _safeMint(to, tokenId);

        // Default to a bull NFT
        string memory defaultUri = bullUrisIpfs[0];
        _setTokenURI(tokenId, defaultUri);
    }

    function checkUpkeep(bytes calldata /*checkData*/) external view override returns (bool upkeepNeeded, bytes memory /*performData*/) {
        upkeepNeeded = ((block.timestamp - lastTimeStamp) > interval) /*&& (randomResult != ROLL_IN_PROGRESS)*/;
    }

    function performUpkeep(bytes calldata /*performData*/) external override {
        if (((block.timestamp - lastTimeStamp) > interval) /*&& (randomResult != ROLL_IN_PROGRESS)*/) {
            lastTimeStamp = block.timestamp;

            int latestPrice = getLatestPrice();

            if (latestPrice == currentPrice) {
                return;
            }
            if (latestPrice < currentPrice) {
                // bear
                updateAllTokenUris("bear"); 
            }
            else {
                // bull
                updateAllTokenUris("bull");
            }

            currentPrice = latestPrice;
        }
    }

    function getLatestPrice() public view returns (int256)
    {
        (
        /*uint80 roundId*/,
        int price,
        /*uint256 startedAt*/,
        /*uint256 updatedAt*/,
        /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        // Example price returned 3034715771688
        return price;
    }

    function updateAllTokenUris(string memory trend) internal {
        if (compareStrings("bear", trend)) {
            for(uint i=0; i < _tokenIdCounter.current(); i++) {
                _setTokenURI(i, bearUrisIpfs[randomResult - 1]);
            }
        }
        else {
            for(uint i=0; i < _tokenIdCounter.current(); i++) {
                _setTokenURI(i, bullUrisIpfs[randomResult - 1]);
            }
        }

        emit TokensUpdated(trend);
    }

    // Randomness oracle calls
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {

        // transform the result to a number between 1 and 3 inclusively
        randomResult = (randomWords[0] % 3) + 1;

        // emitting event to signal that dice landed
        emit RollCompleted(requestId, randomResult);
    }

    function randomRoll() public onlyOwner returns (uint256 requestId) {
        s_requestId = COORDINATOR.requestRandomWords(
        keyHash,
        s_subscriptionId,
        requestConfirmations,
        callbackGasLimit,
        numWords
       );

        randomResult = ROLL_IN_PROGRESS;
        emit RollStarted(requestId);
    }

    // Helper function to set newInterval, only callable by owner
    function setInterval(uint256 newInterval) public onlyOwner {
        interval = newInterval;
    }

    // Helper function to update priceFeed. only callable by owner
    function setPriceFeed(address newFeed) public onlyOwner {
        priceFeed = AggregatorV3Interface(newFeed);
    }

    // Helper function to compare strings
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b)));
    }

    // The following functions are overrides required by Solidity.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}