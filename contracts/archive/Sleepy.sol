// SPDX-License-Identifier: MIT
/**

   o__ __o      o                                                   
   /v     v\    <|>                                                  
  />       <\   / \                                                  
 _\o____        \o/    o__  __o     o__  __o   \o_ __o     o      o  
      \_\__o__   |    /v      |>   /v      |>   |    v\   <|>    <|> 
            \   / \  />      //   />      //   / \    <\  < >    < > 
  \         /   \o/  \o    o/     \o    o/     \o/     /   \o    o/  
   o       o     |    v\  /v __o   v\  /v __o   |     o     v\  /v   
   <\__ __/>    / \    <\/> __/>    <\/> __/>  / \ __/>      <\/>    
                                               \o/            /      
                                                |            o       
                                               / \        __/>       

                    o__ __o      o                 o       o         
                   /v     v\    <|>               <|>     <|>        
                  />       <\   / \               < >     / >        
                 _\o____        \o/    o__ __o     |      \o__ __o   
                      \_\__o__   |    /v     v\    o__/_   |     v\  
                            \   / \  />       <\   |      / \     <\ 
                  \         /   \o/  \         /   |      \o/     o/ 
                   o       o     |    o       o    o       |     <|  
                   <\__ __/>    / \   <\__ __/>    <\__   / \    / \ 
                                                     
                                                     
 */

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './Pauser.sol';

contract Token is Context, IERC20, Ownable, Pauseable {
    using SafeMath for uint256;
    using Address for address;

    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) private _timeOfLastTransfer;
    mapping(address => bool) private _isExcluded;
    mapping(address => bool) private _blacklist;
    address[] private _excluded;

    string private constant _NAME = 'Sleepy Sloth';
    string private constant _SYMBOL = 'SLEEPY';
    uint8 private constant _DECIMALS = 8;
    bool private timeLimited = true;

    address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public pair; // Set upon launch
    uint256 private constant _MAX = ~uint256(0);
    uint256 private constant _DECIMALFACTOR = 10**uint256(_DECIMALS);
    uint256 private constant _GRANULARITY = 100;

    uint256 private _tTotal = 1000000000000000 * _DECIMALFACTOR;
    uint256 private _rTotal = (_MAX - (_MAX % _tTotal));

    uint256 private _tFeeTotal;
    uint256 private _tBurnTotal;

    uint256 private _TAX_FEE = 0;
    uint256 private _BURN_FEE = 0;
    uint256 private transferTime = 180; // 180 seconds to start

    uint256 private maxTxSize = 7500000000000 * _DECIMALFACTOR;

    /** Black list for bots */
    modifier isBlackedListed(address sender, address recipient) {
        require(
            _blacklist[sender] == false && _blacklist[recipient] == false,
            'BEP20: Account is blacklisted from transferring'
        );
        _;
    }

    modifier isPausedOverride() {
        if (pauser() != _msgSender() && router != _msgSender()) {
            // Ensure we can fill pool
            require(_paused == false, 'Pauseable: Contract is paused');
        }
        _;
    }

    /** This is only to stop bots on initial launch. After which we don't care to much and will turn timeLimited off */
    function isTimeLimited(address sender, address recipient) internal {
        if (timeLimited && recipient != owner() && sender != owner()) {
            address toDisable;
            if (sender == pair) {
                toDisable = recipient;
            } else if (recipient == pair) {
                toDisable = sender;
            }

            if (
                toDisable == pair ||
                toDisable == router ||
                toDisable == address(0)
            ) return; // Do nothing as we don't want to disable router

            if (_timeOfLastTransfer[toDisable] == 0) {
                _timeOfLastTransfer[toDisable] = block.timestamp;
            } else {
                require(
                    block.timestamp - _timeOfLastTransfer[toDisable] >
                        transferTime,
                    'BEP20: Time since last transfer must be greater then time to transfer'
                );
                _timeOfLastTransfer[toDisable] = block.timestamp;
            }
        }
    }

    constructor() public {
        _rOwned[_msgSender()] = _rTotal;
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() public pure returns (string memory) {
        return _NAME;
    }

    function symbol() public pure returns (string memory) {
        return _SYMBOL;
    }

    function decimals() public pure returns (uint8) {
        return _DECIMALS;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount)
        public
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                'BEP20: transfer amount exceeds allowance'
            )
        );
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue,
                'BEP20: decreased allowance below zero'
            )
        );
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function totalBurn() public view returns (uint256) {
        return _tBurnTotal;
    }

    function deliver(uint256 tAmount) public {
        address sender = _msgSender();
        require(
            !_isExcluded[sender],
            'Excluded addresses cannot call this function'
        );
        (uint256 rAmount, , , , , ) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee)
        public
        view
        returns (uint256)
    {
        require(tAmount <= _tTotal, 'Amount must be less than supply');
        if (!deductTransferFee) {
            (uint256 rAmount, , , , , ) = _getValues(tAmount);
            return rAmount;
        } else {
            (, uint256 rTransferAmount, , , , ) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount)
        public
        view
        returns (uint256)
    {
        require(
            rAmount <= _rTotal,
            'Amount must be less than total reflections'
        );
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function excludeAccount(address account) external onlyOwner() {
        require(!_isExcluded[account], 'Account is already excluded');
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeAccount(address account) external onlyOwner() {
        require(_isExcluded[account], 'Account is already included');
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) private {
        require(owner != address(0), 'BEP20: approve from the zero address');
        require(spender != address(0), 'BEP20: approve to the zero address');

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) private isPausedOverride isBlackedListed(sender, recipient) {
        isTimeLimited(sender, recipient);
        require(sender != address(0), 'BEP20: transfer from the zero address');
        require(recipient != address(0), 'BEP20: transfer to the zero address');
        require(amount > 0, 'Transfer amount must be greater than zero');

        if (sender != owner() && recipient != owner())
            require(
                amount <= maxTxSize,
                'Transfer amount exceeds the maxTxAmount.'
            );

        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
    }

    function _transferStandard(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        uint256 currentRate = _getRate();
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tBurn
        ) = _getValues(tAmount);
        uint256 rBurn = tBurn.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _reflectFee(rFee, rBurn, tFee, tBurn);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        uint256 currentRate = _getRate();
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tBurn
        ) = _getValues(tAmount);
        uint256 rBurn = tBurn.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _reflectFee(rFee, rBurn, tFee, tBurn);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        uint256 currentRate = _getRate();
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tBurn
        ) = _getValues(tAmount);
        uint256 rBurn = tBurn.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _reflectFee(rFee, rBurn, tFee, tBurn);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferBothExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        uint256 currentRate = _getRate();
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tBurn
        ) = _getValues(tAmount);
        uint256 rBurn = tBurn.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _reflectFee(rFee, rBurn, tFee, tBurn);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _reflectFee(
        uint256 rFee,
        uint256 rBurn,
        uint256 tFee,
        uint256 tBurn
    ) private {
        _rTotal = _rTotal.sub(rFee).sub(rBurn);
        _tFeeTotal = _tFeeTotal.add(tFee);
        _tBurnTotal = _tBurnTotal.add(tBurn);
        _tTotal = _tTotal.sub(tBurn);
    }

    function _getValues(uint256 tAmount)
        private
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (uint256 tTransferAmount, uint256 tFee, uint256 tBurn) =
            _getTValues(tAmount, _TAX_FEE, _BURN_FEE);
        uint256 currentRate = _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) =
            _getRValues(tAmount, tFee, tBurn, currentRate);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tBurn);
    }

    function _getTValues(
        uint256 tAmount,
        uint256 taxFee,
        uint256 burnFee
    )
        private
        pure
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 tFee = ((tAmount.mul(taxFee)).div(_GRANULARITY)).div(100);
        uint256 tBurn = ((tAmount.mul(burnFee)).div(_GRANULARITY)).div(100);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tBurn);
        return (tTransferAmount, tFee, tBurn);
    }

    function _getRValues(
        uint256 tAmount,
        uint256 tFee,
        uint256 tBurn,
        uint256 currentRate
    )
        private
        pure
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rBurn = tBurn.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rBurn);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (
                _rOwned[_excluded[i]] > rSupply ||
                _tOwned[_excluded[i]] > tSupply
            ) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _getTaxFee() private view returns (uint256) {
        return _TAX_FEE;
    }

    function _setTaxFee(uint256 taxFee) external onlyOwner() {
        require(taxFee >= 50 && taxFee <= 1000, 'taxFee should be in 1 - 10');
        _TAX_FEE = taxFee;
    }

    function _setBurnFee(uint256 burnFee) external onlyOwner() {
        require(
            burnFee >= 50 && burnFee <= 1000,
            'burnFee should be in 1 - 10'
        );
        _BURN_FEE = burnFee;
    }

    function _setMaxTxSize(uint256 _maxTxSize) external onlyOwner() {
        maxTxSize = _maxTxSize * _DECIMALFACTOR;
    }

    function _setTimeLimited(bool _timeLimited) external onlyOwner() {
        timeLimited = _timeLimited;
    }

    function _setBlackListedAddress(address account, bool blacklisted)
        external
        onlyOwner()
    {
        _blacklist[account] = blacklisted;
    }

    function _setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function _setPair(address _pair) external onlyOwner {
        pair = _pair;
    }

    function setTransferTime(uint256 _transferTime) external onlyOwner {
        transferTime = _transferTime;
    }
}
