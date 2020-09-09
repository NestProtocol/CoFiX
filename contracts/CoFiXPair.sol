// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import './interface/ICoFiXPair.sol';
import './CoFiXERC20.sol';
import './interface/IERC20.sol';
import './interface/ICoFiXFactory.sol';
import './interface/ICoFiXController.sol';
import './lib/TransferHelpers.sol';
import "./lib/ABDKMath64x64.sol";


contract CoFiXPair is ICoFiXPair, CoFiXERC20 {
    using SafeMath  for uint;

    uint public override constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public override factory;
    address public override token0; // WETH token
    address public override token1; // any ERC20 token


    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves

    // TODO: enlarge these base params
    uint256 constant public K_BASE = 100000; // K
    uint256 constant public NAVPS_BASE = 10000; // NAVPS (Net Asset Value Per Share)
    uint256 constant public THETA_BASE = 10000; // theta

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'CPair: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public override view returns (uint112 _reserve0, uint112 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'CPair: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, address outToken, uint outAmount, address indexed to);
    event Swap(
        address indexed sender,
        uint amountIn,
        uint amountOut,
        address outToken,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    

    constructor() public {
        factory = msg.sender;
    }

    receive() external payable {}

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external override {
        require(msg.sender == factory, 'CPair: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves
    function _update(uint balance0, uint balance1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'CPair: OVERFLOW');
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external payable override lock returns (uint liquidity, uint oracleFeeChange) {
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        (uint112 _reserve0, uint112 _reserve1) = getReserves(); // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        uint256 _ethBalanceBefore = address(this).balance;
        { // scope for ethAmount/erc20Amount/blockNum to avoid stack too deep error
            // query price
            OraclePrice memory _op;
            (_op.K, _op.ethAmount, _op.erc20Amount, _op.blockNum, _op.theta) = queryOracle(_token1, to);
            uint256 navps = calcNAVPerShareForMint(_reserve0, _reserve1, _op);
            liquidity = calcLiquidity(amount0, amount1, navps, _op);
        }
        oracleFeeChange = msg.value.sub(_ethBalanceBefore.sub(address(this).balance));

        require(liquidity > 0, 'CPair: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1);
        if (oracleFeeChange > 0) TransferHelper.safeTransferETH(msg.sender, oracleFeeChange);

        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address outToken, address to) external payable override lock returns (uint amountOut, uint oracleFeeChange) {
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        uint256 _ethBalanceBefore = address(this).balance;
        uint256 fee;
        {
            // query price
            OraclePrice memory _op;
            (_op.K, _op.ethAmount, _op.erc20Amount, _op.blockNum, _op.theta) = queryOracle(_token1, to);
            if (outToken == _token0) {
                (amountOut, fee) = calcOutToken0ForBurn(liquidity, _op); // navps calculated
            } else if (outToken == _token1) {
                (amountOut, fee) = calcOutToken1ForBurn(liquidity, _op); // navps calculated
            }  else {
                revert("CPair: wrong outToken");
            }
        }
        oracleFeeChange = msg.value.sub(_ethBalanceBefore.sub(address(this).balance));

        require(amountOut > 0, 'CPair: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(outToken, to, amountOut);
        if (fee > 0) _safeTransfer(_token0, ICoFiXFactory(factory).getFeeReceiver(), fee);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1);
        if (oracleFeeChange > 0) TransferHelper.safeTransferETH(msg.sender, oracleFeeChange);

        emit Burn(msg.sender, outToken, amountOut, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swapForExact(address outToken, uint amountOutExact, address to)
        external
        payable override lock
        returns (uint amountIn, uint amountOut, uint oracleFeeChange)
    {
        address _token0 = token0;
        address _token1 = token1;
        OraclePrice memory _op;

        { // scope for ethAmount/erc20Amount/blockNum to avoid stack too deep error
            uint256 _ethBalanceBefore = address(this).balance;
            // query price
            (_op.K, _op.ethAmount, _op.erc20Amount, _op.blockNum, _op.theta) = queryOracle(_token1, to);
            oracleFeeChange = msg.value.sub(_ethBalanceBefore.sub(address(this).balance));
        }

        {
            uint256 balance0 = IERC20(_token0).balanceOf(address(this));
            uint256 balance1 = IERC20(_token1).balanceOf(address(this));
            (uint112 _reserve0, uint112 _reserve1) = getReserves(); // gas savings
            uint _amountInNeeded;
     
            if (outToken == _token1) {
                amountIn = balance0.sub(_reserve0);
                require(amountIn > 0, "CPair: wrong amount0In"); // for different revert reason
                _amountInNeeded = calcInNeededToken0(amountOutExact, _op);
                require(_amountInNeeded <= amountIn, "CPair: wrong amountIn");
                if (amountIn.sub(_amountInNeeded) > 0) {
                    _safeTransfer(_token0, to, amountIn.sub(_amountInNeeded)); // send back the amount0 token change
                }
            } else if (outToken == _token0) {
                amountIn = balance1.sub(_reserve1);
                require(amountIn > 0, "CPair: wrong amount1In"); // for different revert reason
                _amountInNeeded = calcInNeededToken1(amountOutExact, _op);
                require(_amountInNeeded <= amountIn, "CPair: wrong amountIn");
                if (amountIn.sub(_amountInNeeded) > 0) {
                    _safeTransfer(_token1, to, amountIn.sub(_amountInNeeded)); // send back the amount1 token change
                }
            } else {
                revert("CPair: wrong outToken");
            }
        }

        require(amountIn > 0, "CPair: INSUFFICIENT_INPUT_AMOUNT");
        
        {
            require(to != _token0 && to != _token1, "CPair: INVALID_TO");

            amountOut = amountOutExact;
            _safeTransfer(outToken, to, amountOut); // optimistically transfer tokens

            uint256 balance0 = IERC20(_token0).balanceOf(address(this));
            uint256 balance1 = IERC20(_token1).balanceOf(address(this));

            _update(balance0, balance1);
            if (oracleFeeChange > 0) TransferHelper.safeTransferETH(msg.sender, oracleFeeChange);
        }

        emit Swap(msg.sender, amountIn, amountOut, outToken, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swapWithExact(address outToken, address to) external payable override lock returns (uint amountIn, uint amountOut, uint oracleFeeChange) {
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        uint256 fee;
        { // scope for ethAmount/erc20Amount/blockNum to avoid stack too deep error
            uint256 _ethBalanceBefore = address(this).balance;
            // query price
            OraclePrice memory _op;
            (_op.K, _op.ethAmount, _op.erc20Amount, _op.blockNum, _op.theta) = queryOracle(_token1, to);
            (uint112 _reserve0, uint112 _reserve1) = getReserves(); // gas savings

            if (outToken == _token1) {
                amountIn = balance0.sub(_reserve0);
                require(amountIn > 0, "CPair: wrong amount0In");
                (amountOut, fee) = calcOutToken1(amountIn, _op);
            } else if (outToken == _token0) {
                amountIn = balance1.sub(_reserve1);
                require(amountIn > 0, "CPair: wrong amount1In");
                (amountOut, fee) = calcOutToken0(amountIn, _op);
            } else {
                revert("CPair: wrong outToken");
            }
            oracleFeeChange = msg.value.sub(_ethBalanceBefore.sub(address(this).balance));
        }
        
        require(to != _token0 && to != _token1, 'CPair: INVALID_TO');

        _safeTransfer(outToken, to, amountOut); // optimistically transfer tokens
        if (fee > 0) _safeTransfer(_token0, ICoFiXFactory(factory).getFeeReceiver(), fee);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1);
        if (oracleFeeChange > 0) TransferHelper.safeTransferETH(msg.sender, oracleFeeChange);

        emit Swap(msg.sender, amountIn, amountOut, outToken, to);
    }

    // force balances to match reserves
    function skim(address to) external override lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external override lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    // calc Net Asset Value Per Share for mint
    // use it in this contract, for optimized gas usage
    function calcNAVPerShareForMint(uint256 balance0, uint256 balance1, OraclePrice memory _op) public view returns (uint256 navps) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            navps = NAVPS_BASE;
        } else {
            /*
            N_{p} &= (A_{u}/P_{s}^{'} + A_{e})/S \\\\
                  &= (A_{u}/(P * (1 - K)) + A_{e})/S \\\\
                  &= (\frac{A_{u}}{\frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} - k)}{(k_{BASE})}} + A_{e})/S \\\\
                  &= (\frac{A_{u}*ethAmount*k_{BASE}}{erc20Amount*(k_{BASE} - k)}+ A_{e}) / S \\\\
                  &= (A_{u}*ethAmount*k_{BASE}+ A_{e}*erc20Amount*(k_{BASE} - k)) / S / (erc20Amount*(k_{BASE} - k)) \\\\
            N_{p} &= NAVPS_{BASE}*(A_{u}*ethAmount*k_{BASE}+ A_{e}*erc20Amount*(k_{BASE} - k)) / S / (erc20Amount*(k_{BASE} - k)) \\\\
            // navps = NAVPS_BASE * ( (balance1*_op.ethAmount*K_BASE) + (balance0*_op.erc20Amount*(K_BASE-_op.K)) ) / _totalSupply / _op.erc20Amount / (K_BASE-_op.K);
            */
            uint256 kbaseSubK = K_BASE.sub(_op.K);
            uint256 balance1MulEthKbase = balance1.mul(_op.ethAmount).mul(K_BASE);
            uint256 balance0MulErcKbsk = balance0.mul(_op.erc20Amount).mul(kbaseSubK);
            navps = NAVPS_BASE.mul( (balance1MulEthKbase).add(balance0MulErcKbsk) ).div(_totalSupply).div(_op.erc20Amount).div(kbaseSubK);
        }
    }

    // calc Net Asset Value Per Share for burn
    // use it in this contract, for optimized gas usage
    function calcNAVPerShareForBurn(uint256 balance0, uint256 balance1, OraclePrice memory _op) public view returns (uint256 navps) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            navps = NAVPS_BASE;
        } else {
            /*
            N_{p}^{'} &= (A_{u}/P_{b}^{'} + A_{e})/S \\\\
                      &= (A_{u}/(P * (1 + K)) + A_{e})/S \\\\
                      &= (\frac{A_{u}}{\frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} + k)}{(k_{BASE})}} + A_{e})/S \\\\
                      &= (\frac{A_{u}*ethAmount*k_{BASE}}{erc20Amount*(k_{BASE} + k)}+ A_{e}) / S \\\\
                      &= (A_{u}*ethAmount*k_{BASE}+ A_{e}*erc20Amount*(k_{BASE} + k)) / S / (erc20Amount*(k_{BASE} + k)) \\\\
            N_{p}^{'} &= NAVPS_{BASE}*(A_{u}*ethAmount*k_{BASE}+ A_{e}*erc20Amount*(k_{BASE} + k)) / S / (erc20Amount*(k_{BASE} + k)) \\\\
            // navps = NAVPS_BASE * ( (balance1*_op.ethAmount*K_BASE) + (balance0*_op.erc20Amount*(K_BASE+_op.K)) ) / _totalSupply / _op.erc20Amount / (K_BASE+_op.K);
            */
            uint256 kbaseAddK = K_BASE.add(_op.K);
            uint256 balance1MulEthKbase = balance1.mul(_op.ethAmount).mul(K_BASE);
            uint256 balance0MulErcKbsk = balance0.mul(_op.erc20Amount).mul(kbaseAddK);
            navps = NAVPS_BASE.mul( (balance1MulEthKbase).add(balance0MulErcKbsk) ).div(_totalSupply).div(_op.erc20Amount).div(kbaseAddK);
        }
    }


    // use it in this contract, for optimized gas usage
    function calcLiquidity(uint256 amount0, uint256 amount1, uint256 navps, OraclePrice memory _op) public pure returns (uint256 liquidity) {
        /*
        s_{1} &= a / (N_{p} / NAVPS_{BASE}) \\\\
              &= a * NAVPS_{BASE} / N_{p} \\\\
        s_{2} &= b / P_{b}^{'} / (N_{p} / NAVPS_{BASE}) \\\\
              &= b / (N_{p} / NAVPS_{BASE}) / P_{b}^{'} \\\\
              &= b * NAVPS_{BASE} / N_{p} / P_{b}^{'} \\\\
              &= b * NAVPS_{BASE} / N_{p} / (\frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} + k)}{(k_{BASE})}) \\\\
              &= b * NAVPS_{BASE} * ethAmount * k_{BASE} / N_{p} / (erc20Amount * (k_{BASE} + k))
        s &= s_1 + s_2 \\\\
          &= a * NAVPS_{BASE} / N_{p} + b * NAVPS_{BASE} / N_{p} / P_{b}^{'} \\\\
          &= a * NAVPS_{BASE} / N_{p} + b * NAVPS_{BASE} * ethAmount * k_{BASE} / N_{p} / (erc20Amount * (k_{BASE} + k)) \\\\
        // liquidity = (amount0 * NAVPS_BASE / navps) + (amount1 * NAVPS_BASE * _op.ethAmount * K_BASE / navps / _op.erc20Amount / (K_BASE + _op.K));
        */
        uint256 amnt0MulNbaseDivN = amount0.mul(NAVPS_BASE).div(navps);
        uint256 amnt1MulNbaseEthKbase = amount1.mul(NAVPS_BASE).mul(_op.ethAmount).mul(K_BASE);
        liquidity = ( amnt0MulNbaseDivN ).add( amnt1MulNbaseEthKbase.div(navps).div(_op.erc20Amount).div(K_BASE.add(_op.K)) );
    }

    // get Net Asset Value Per Share
    // only for read, could cost more gas if use it directly in contract
    function getNAVPerShareForMint(OraclePrice memory _op) public view returns (uint256 navps) {
        return calcNAVPerShareForMint(reserve0, reserve1, _op);
    }

    // get Net Asset Value Per Share
    // only for read, could cost more gas if use it directly in contract
    function getNAVPerShareForBurn(OraclePrice memory _op) public view returns (uint256 navps) {
        return calcNAVPerShareForBurn(reserve0, reserve1, _op);
    }

    // get estimated liquidity amount (it represents the amount of pool tokens will be minted if someone provide liquidity to the pool)
    // only for read, could cost more gas if use it directly in contract
    function getLiquidity(uint256 amount0, uint256 amount1, OraclePrice memory _op) public view returns (uint256 liquidity) {
        uint256 navps = getNAVPerShareForMint(_op);
        return calcLiquidity(amount0, amount1, navps, _op);
    }

    // calc amountOut for token0 (WETH) when send liquidity token to pool for burning
    function calcOutToken0ForBurn(uint256 liquidity, OraclePrice memory _op) public view returns (uint256 amountOut, uint256 fee) {
        /*
        e &= c * (N_{p}^{'} / NAVPS_{BASE}) * (THETA_{BASE} - \theta)/THETA_{BASE} \\\\
          &= c * \frac{N_{p}^{'}}{NAVPS_{BASE}} * \frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= c * N_{p}^{'} * (THETA_{BASE} - \theta) / NAVPS_{BASE} / THETA_{BASE} \\\\
        // amountOut = liquidity * navps * (THETA_BASE - _op.theta) / NAVPS_BASE / THETA_BASE;
        */
        uint256 navps = calcNAVPerShareForBurn(reserve0, reserve1, _op);
        amountOut = liquidity.mul(navps).mul(THETA_BASE.sub(_op.theta)).div(NAVPS_BASE).div(THETA_BASE);
        if (_op.theta != 0) {
            // fee = liquidity * navps * (_op.theta) / NAVPS_BASE / THETA_BASE;
            fee = liquidity.mul(navps).mul(_op.theta).div(NAVPS_BASE).div(THETA_BASE);
        }
        return (amountOut, fee);
    }


    // calc amountOut for token1 (ERC20 token) when send liquidity token to pool for burning
    function calcOutToken1ForBurn(uint256 liquidity, OraclePrice memory _op) public view returns (uint256 amountOut, uint256 fee) {
        /*
        u &= c * (N_{p}^{'} / NAVPS_{BASE}) * P_{s}^{'} * (THETA_{BASE} - \theta)/THETA_{BASE} \\\\
          &= c * \frac{N_{p}^{'}}{NAVPS_{BASE}} * \frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} - k)}{(k_{BASE})} * \frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= \frac{c * N_{p}^{'} * erc20Amount * (k_{BASE} - k) * (THETA_{BASE} - \theta)}{NAVPS_{BASE}*ethAmount*k_{BASE}*THETA_{BASE}}
        // amountOut = liquidity * navps * _op.erc20Amount * (K_BASE - _op.K) * (THETA_BASE - _op.theta) / NAVPS_BASE / _op.ethAmount / K_BASE / THETA_BASE;
        */
        uint256 navps = calcNAVPerShareForBurn(reserve0, reserve1, _op);
        uint256 liqMulMany = liquidity.mul(navps).mul(_op.erc20Amount).mul(K_BASE.sub(_op.K)).mul(THETA_BASE.sub(_op.theta));
        amountOut = liqMulMany.div(NAVPS_BASE).div(_op.ethAmount).div(K_BASE).div(THETA_BASE);
        if (_op.theta != 0) {
            // fee = liquidity * navps * (_op.theta) / NAVPS_BASE / THETA_BASE;
            fee = liquidity.mul(navps).mul(_op.theta).div(NAVPS_BASE).div(THETA_BASE);
        }
        return (amountOut, fee);
    }

    // get estimated amountOut for token0 (WETH) when swapWithExact
    function calcOutToken0(uint256 amountIn, OraclePrice memory _op) public pure returns (uint256 amountOut, uint256 fee) {
        /*
        x &= (a/P_{b}^{'})*\frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= a / (\frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} + k)}{(k_{BASE})}) * \frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= \frac{a*ethAmount*k_{BASE}}{erc20Amount*(k_{BASE} + k)} * \frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= \frac{a*ethAmount*k_{BASE}*(THETA_{BASE} - \theta)}{erc20Amount*(k_{BASE} + k)*THETA_{BASE}} \\\\
        // amountOut = amountIn * _op.ethAmount * K_BASE * (THETA_BASE - _op.theta) / _op.erc20Amount / (K_BASE + _op.K) / THETA_BASE;
        */
        amountOut = amountIn.mul(_op.ethAmount).mul(K_BASE).mul(THETA_BASE.sub(_op.theta)).div(_op.erc20Amount).div(K_BASE.add(_op.K)).div(THETA_BASE);
        if (_op.theta != 0) {
            // fee = amountIn * _op.ethAmount * K_BASE * (_op.theta) / _op.erc20Amount / (K_BASE + _op.K) / THETA_BASE;
            fee = amountIn.mul(_op.ethAmount).mul(K_BASE).mul(_op.theta).div(_op.erc20Amount).div(K_BASE.add(_op.K)).div(THETA_BASE);
        }
        return (amountOut, fee);
    }

    // get estimated amountOut for token1 (ERC20 token) when swapWithExact
    function calcOutToken1(uint256 amountIn, OraclePrice memory _op) public pure returns (uint256 amountOut, uint256 fee) {
        /*
        y &= b*P_{s}^{'}*\frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= b * \frac{erc20Amount}{ethAmount} * \frac{(k_{BASE} - k)}{(k_{BASE})} * \frac{THETA_{BASE} - \theta}{THETA_{BASE}} \\\\
          &= \frac{b*erc20Amount*(k_{BASE} - k)*(THETA_{BASE} - \theta)}{ethAmount*k_{BASE}*THETA_{BASE}} \\\\
        // amountOut = amountIn * _op.erc20Amount * (K_BASE - _op.K) * (THETA_BASE - _op.theta) / _op.ethAmount / K_BASE / THETA_BASE;
        */
        amountOut = amountIn.mul(_op.erc20Amount).mul(K_BASE.sub(_op.K)).mul(THETA_BASE.sub(_op.theta)).div(_op.ethAmount).div(K_BASE).div(THETA_BASE);
        if (_op.theta != 0) {
            // fee = amountIn * _op.theta / THETA_BASE;
            fee = amountIn.mul(_op.theta).div(THETA_BASE);
        }
        return (amountOut, fee);
    }

    // get estimate amountInNeeded for token0 (WETH) when swapForExact
    function calcInNeededToken0(uint256 amountOut, OraclePrice memory _op) public pure returns (uint256 amountInNeeded) {
        // inverse of calcOutToken1
        // amountOut = amountIn.mul(_op.erc20Amount).mul(K_BASE.sub(_op.K)).mul(THETA_BASE.sub(_op.theta)).div(_op.ethAmount).div(K_BASE).div(THETA_BASE);
        return amountOut.mul(_op.ethAmount).mul(K_BASE).mul(THETA_BASE).div(_op.erc20Amount).div(K_BASE.sub(_op.K)).div(THETA_BASE.sub(_op.theta));
    }

    // get estimate amountInNeeded for token1 (ERC20 token) when swapForExact
    function calcInNeededToken1(uint256 amountOut, OraclePrice memory _op) public pure returns (uint256 amountInNeeded) {
        // inverse of calcOutToken0
        // amountOut = amountIn.mul(_op.ethAmount).mul(K_BASE).mul(THETA_BASE.sub(_op.theta)).div(_op.erc20Amount).div(K_BASE.add(_op.K)).div(THETA_BASE);
        return amountOut.mul(_op.erc20Amount).mul(K_BASE.add(_op.K)).mul(THETA_BASE).div(_op.ethAmount).div(K_BASE).div(THETA_BASE.sub(_op.theta));
    }

    function queryOracle(address token, address to) internal returns (uint256, uint256, uint256, uint256, uint256) {
        return ICoFiXController(ICoFiXFactory(factory).getController()).queryOracle{value: msg.value}(token, to);
    }

}
