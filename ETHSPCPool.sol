//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

import "./SpaceCoin.sol";
import "./Math.sol";

// what happens if someone just donates SPC or ETH so it affects the value locked in contract and ERC-20 SPC?
// pool is based off of the state variables below so nothing will be affected i think
contract ETHSPCPool is ERC20 {
    uint256 public balanceSPC;
    uint256 public balanceETH;
    uint256 public balanceLPT;

    uint256 public MIN_LPT = 1000;

    SpaceCoin public spaceCoin;

    bool public lock;

    constructor(address _spaceCoin) ERC20("LiquidityPoolTokens", "LPT") {
        spaceCoin = SpaceCoin(_spaceCoin);
    }

    event Mint(
        address executor,
        address to,
        uint256 depositedETH,
        uint256 depositedSPC,
        uint256 receivedLPT
    );

    event Burn(
        address executor,
        address to,
        uint256 burnedLPT,
        uint256 receivedETH,
        uint256 receivedSPC
    );

    event Swap(
        address executor,
        address to,
        uint256 swapInETH,
        uint256 swapInSPC,
        uint256 swapOutETH,
        uint256 swapOutSPC
    );

    // protect against malicious ERC-20s
    modifier withLock() {
        require(lock == false, "REENTRANCY_DENIED");
        lock = true;
        _;
        lock = false;
    }

    // anyone can call this function (executor) and they send lp tokens to "to" person
    /// @notice assumes that ETH or SPC has been deposited to the pool
    /// it keeps balance and reserve to know how much was added
    function mint(address to) external {
        // use the deposited amount to mint a certain amount of LP tokens
        // do i need to calculate a fee??? NOPE
        /**
         * Steps
         * 1. calculate amount that has added to pool for each token
         * 2. if it's the first deposit, lp tokens is equal to sqrt of geometric mean
         * 3. if it's a subsequent deposit, lp tokens is equal to ratio of deposit/totalSupply*numLPTokensinExistence
         * 4. Update the reserve amounts
         * 5. Assert that the k is greater than or equal to the last k
         */
        uint256 currentETH = address(this).balance;
        uint256 currentSPC = spaceCoin.balanceOf(address(this));

        // both should be positive
        uint256 depositedETH = currentETH - balanceETH;
        uint256 depositedSPC = currentSPC - balanceSPC;
        uint256 totalLPT = totalSupply();

        // if either is 0, initial deposit would make the other token valued at infinite amount
        // for subsequent deposit this would reward 0 tokens
        // for both, there's no deposit to mint anything
        // rewardLPT is guarenteed to be nonzero with this
        if (depositedETH == 0 || depositedSPC == 0) {
            revert("ZERO_DEPOSITED");
        }

        uint256 rewardLPT;
        // 1st LPT reward is equal to sqrt of product of deposits
        if (totalLPT == 0) {
            uint256 nonAdjustedLPT = Math.sqrt(depositedETH * depositedSPC);
            require(nonAdjustedLPT > MIN_LPT, "MINT_AMOUNT_SMALL");
            rewardLPT = nonAdjustedLPT - MIN_LPT;
            _mint(address(7), MIN_LPT);
        } else {
            // subsequent deposit is equal to deposit/totalSupply*numLPTokensinExistence
            rewardLPT = Math.min(
                (totalLPT * depositedETH) / balanceETH,
                (totalLPT * depositedSPC) / balanceSPC
            );
        }

        require(rewardLPT > 0, "MINT_AMOUNT_ZERO");

        _mint(to, rewardLPT);

        // i don't think this will ever occur if you can only add
        require(
            currentETH * currentSPC >= balanceETH * balanceSPC,
            "K_VALUE_LOW"
        );

        // update balance to reflect amount
        balanceETH = currentETH;
        balanceSPC = currentSPC;

        emit Mint(msg.sender, to, depositedETH, depositedSPC, rewardLPT);
    }

    /// @notice assumes that LP tokens have been transferred back to pool
    function burn(address to) external withLock returns(uint256 receivedETH, uint256 receivedSPC){
        // calculates the amount of tokens of SPC and ETH to send back to user
        /**
         * Steps
         * 1. findout amount of LP tokens that were transferred back to pool
         * 2. get equal amounts of ETH/SPC and send them back to user
         * 3. burn the LP tokens received
         */
        // burnLPT is how much the user wants to burn/trade in cuz they transferred it to pool's ownership already
        uint256 burnLPT = balanceOf(address(this));
        require(burnLPT > 0, "NOTHING_TO_BURN");

        uint256 totalLPT = totalSupply();

        uint256 currentETH = address(this).balance;
        uint256 currentSPC = spaceCoin.balanceOf(address(this));

        // we'll never have divide by zero errors
        receivedETH = (burnLPT * currentETH) / totalLPT;
        receivedSPC = (burnLPT * currentSPC) / totalLPT;

        // console.log(
        //     burnLPT,
        //     this.balanceOf(address(this)),
        //     "desired burn vs balance"
        // );

        _burn(address(this), burnLPT);
        // burn LPT!
        // _transfer(address(this), address(7), burnLPT);

        // send eth
        (bool success, ) = to.call{value: receivedETH}("");
        require(success, "CANT_SEND_ETH");

        // send SPC
        spaceCoin.transfer(to, receivedSPC);

        // update balances
        balanceETH = currentETH - receivedETH;
        balanceSPC = currentSPC - receivedSPC;

        emit Burn(msg.sender, to, burnLPT, receivedETH, receivedSPC);
    }

    function swapSPCtoETH(address to) external withLock {
        uint256 currentSPC = spaceCoin.balanceOf(address(this));

        require(balanceETH > 0 && balanceSPC > 0, "ZERO_LIQUIDITY");

        // both should be greater than or equal to 0
        uint256 depositedSPC = currentSPC - balanceSPC;

        require(depositedSPC > 0, "ZERO_DEPOSITED");

        uint256 withdrawETH;

        {
            uint256 newETHBalance = (balanceSPC * balanceETH) /
                (((99 * depositedSPC) / 100) + balanceSPC);
            withdrawETH = balanceETH - newETHBalance;
        }

        require(withdrawETH < balanceETH, "NOT_ENOUGH_LIQUIDITY");

        require(withdrawETH > 0, "ZERO_SWAP");

        (bool success, ) = to.call{value: withdrawETH}("");
        require(success, "CANT_SEND_ETH");

        uint256 currentETH = address(this).balance;

        uint256 currentSPCWithoutFee = currentSPC - (depositedSPC / 100);

        require(
            currentETH * currentSPCWithoutFee >= balanceETH * balanceSPC,
            "K_VALUE_LOW"
        );

        balanceETH = currentETH;
        balanceSPC = currentSPC;

        emit Swap(msg.sender, to, 0, depositedSPC, withdrawETH, 0);
    }

    // note someone can add SPC to the pool -- but we use the official SPC values
    function swapETHtoSPC(address to) external {
        uint256 currentETH = address(this).balance;

        require(balanceETH > 0 && balanceSPC > 0, "ZERO_LIQUIDITY");

        // both should be greater than or equal to 0
        uint256 depositedETH = currentETH - balanceETH;

        require(depositedETH > 0, "ZERO_DEPOSITED");

        uint256 withdrawSPC;

        // 0.04 -0.0004

        {
            uint256 newSPCBalance = (balanceETH * balanceSPC) /
                (((99 * depositedETH) / 100) + balanceETH);
            withdrawSPC = balanceSPC - newSPCBalance;
        }

        // note that we use "official" spc , not actual balance
        require(withdrawSPC < balanceSPC, "NOT_ENOUGH_LIQUIDITY");

        // is a user able to withdraw the entire pool? no

        require(withdrawSPC > 0, "ZERO_SWAP");

        spaceCoin.transfer(to, withdrawSPC);

        uint256 currentSPC = spaceCoin.balanceOf(address(this));

        uint256 currentETHWithoutFee = currentETH - (depositedETH / 100);

        require(
            currentETHWithoutFee * currentSPC >= balanceETH * balanceSPC,
            "K_VALUE_LOW"
        );

        balanceETH = currentETH;
        balanceSPC = currentSPC;

        emit Swap(msg.sender, to, depositedETH, 0, 0, withdrawSPC);
    }

    // function swapSPCtoETH(address to) external withLock {}

    function sendETH() external payable {}

    // // i enforce the tax in the swap code, not outside of the swap code
    // // before this, tokens will need to be transferred in
    // // router will check that min amount to be swapped in is past some amount
    // function swap(address to) external withLock {
    //     // require(amountETHOut == 0 || amountSPCOut == 0, "CANT_SWAP");
    //     // ideally, one should be 0 and the other non-zero
    //     // what does it even mean if someone deposits both at the same time?
    //     // when swap finishes.. remember to take 1% fee and put it back in the pool
    //     /**
    //      * Steps
    //      * 1. (before) user deposits ETH and/or SPC
    //      * 2. calculate amount of ETH out based on SPC
    //      * 3. calculate amount of SPC out based on ETH
    //      * 4. transfer that amount
    //      */
    //     uint256 currentETH = address(this).balance;
    //     uint256 currentSPC = spaceCoin.balanceOf(address(this));

    //     require(currentETH > 0 && currentSPC > 0, "ZERO_LIQUIDITY");

    //     // both should be greater than or equal to 0
    //     uint256 depositedETH = currentETH - balanceETH;
    //     uint256 depositedSPC = currentSPC - balanceSPC;

    //     // console.log(depositedETH, depositedSPC, "deposited");

    //     // require(depositedETH == 0 || depositedSPC == 0, "NO_DOUBLE_SWAP");
    //     require(depositedETH > 0 || depositedSPC > 0, "ZERO_DEPOSITED");

    //     // y_f = k/(.99x_deposit + x) due to 1 percent fee
    //     // uint256 withdrawETH = depositedSPC * 99 * balanceSPC * (balanceSPC * balanceETH) / 100;

    //     uint256 withdrawETH;
    //     uint256 withdrawSPC;

    //     {
    //         uint256 newETHBalance = depositedSPC > 0
    //             ? (balanceSPC * balanceETH) /
    //                 (((99 * depositedSPC) / 100) + balanceSPC)
    //             : balanceETH;
    //         uint256 newSPCBalance = depositedETH > 0
    //             ? (balanceETH * balanceSPC) /
    //                 (((99 * depositedETH) / 100) + balanceETH)
    //             : balanceSPC;
    //         withdrawETH = balanceETH - newETHBalance;
    //         withdrawSPC = balanceSPC - newSPCBalance;

    //         // console.log((((99 * depositedETH) / 100) + balanceETH), "eth");
    //         // console.log(newETHBalance, newSPCBalance, "new balances");
    //         // console.log(withdrawETH, withdrawSPC, "withdraw amount");
    //     }

    //     require(
    //         withdrawETH < currentETH && withdrawSPC < currentSPC,
    //         "NOT_ENOUGH_LIQUIDITY"
    //     );

    //     // is a user able to withdraw the entire pool? no

    //     if (withdrawETH > 0) {
    //         (bool success, ) = to.call{value: withdrawETH}("");
    //         require(success, "CANT_SEND_ETH");
    //     }
    //     if (withdrawSPC > 0) {
    //         spaceCoin.transfer(to, withdrawSPC);
    //     }

    //     // reassign these variables after transfer
    //     currentETH = address(this).balance;
    //     currentSPC = spaceCoin.balanceOf(address(this));

    //     uint256 currentETHWithoutFee = currentETH - (depositedETH / 100);
    //     uint256 currentSPCWithoutFee = currentSPC - (depositedSPC / 100);

    //     // k should only be same or increase BEFORE the 1% fee we took
    //     require(
    //         currentETHWithoutFee * currentSPCWithoutFee >=
    //             balanceETH * balanceSPC,
    //         "K_VALUE_LOW"
    //     );

    //     balanceETH = currentETH;
    //     balanceSPC = currentSPC;

    //     emit Swap(
    //         msg.sender,
    //         to,
    //         depositedETH,
    //         depositedSPC,
    //         withdrawETH,
    //         withdrawSPC
    //     );
    // }
}
