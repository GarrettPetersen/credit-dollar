"""
ERC20 for credit dollar (CUSD)
This contract contains:
- Standard ERC20 functions
- Flashmint, with profits going to founder
- One-time pre-mint to founder
- only allows the minter (issuer contract) to mint
"""

from vyper.interfaces import ERC20
from vyper.interfaces import ERC20Detailed

implements: ERC20
implements: ERC20Detailed

contract ERC20Borrower():
    def erc20DeFi(cusd_amount: uint256, interest: uint256): nonpayable

INIT_SUPPLY: constant(unit256) = 10000000000000000000000000
INTEREST_FACTOR: constant(uint256) = 8 # 8 / 10000 = 0.08%

founder: address
minter: address

totalSupply: public(uint256)
name: public(string[13])
symbol: public(string[4])
balances: Hashmap[address, uint256]
allowances: Hashmap[address, Hashmap[address, uint256]]
interestFactor: public(uint256)

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Approval:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Flash:
    borrower: indexed(address)
    amount: uint256
    interest: uint256

@external
def __init__():
    self.totalSupply = INIT_SUPPLY
    self.name = "Credit Dollar"
    self.symbol = "CUSD"
    self.interestFactor = INTEREST_FACTOR
    self.founder = msg.sender
    self.minter = self.founder
    self.balances[self.founder] = self.totalSupply
    log Transfer(empty(address), self.founder, self.totalSupply)

@view
@external
def decimals() -> uint256:
    return 18

@internal
def _transferCoins(_src: address, _dst: address, _amount: uint256):
	assert _src != empty(address), "CUSD::_transferCoins: cannot transfer from the zero address"
	assert _dst != empty(address), "CUSD::_transfersCoins: cannot transfer to the zero address"
	self.balances[_src] -= _amount
	self.balances[_dst] += _amount

@internal
def _burn(_src: address, _amount: uint256):
    assert _src != empty(address), "CUSD::_burn: cannot burn from the zero address"
    self.balances[_src] -= _amount
    self.totalSupply -= _amount

@internal
def _mint(_dst: address, _amount: uint256):
    assert _dst != empty(address), "CUSD::_mint: cannot mint to the zero address"
    self.balances[_dst] += _amount
    self.totalSupply += _amount

@external
def transfer(_to: address, _value: uint256) -> bool:
	assert self.balances[msg.sender] >= _value, "CUSD::transfer: Not enough coins"
	self._transferCoins(msg.sender, _to, _value)
	log Transfer(msg.sender, _to, _value)
	return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
	allowance: uint256 = self.allowances[_from][msg.sender]
	assert self.balances[_from] >= _value and allowance >= _value, "CUSD::transferFrom: Not enough coins"
	self._transferCoins(_from, _to, _value)
	self.allowances[_from][msg.sender] -= _value
	log Transfer(_from, _to, _value)
	return True

@external
def burn(_value: uint256) -> bool:
    assert self.balances[msg.sender] >= _value, "CUSD::burn: Not enough coins"
    self._burn(msg.sender, _value)
    log Transfer(msg.sender, empty(address), _value)
    return True

@external
def burnFrom(_from: address, _value: uint256) -> bool:
    allowance: uint256 = self.allowances[_from][msg.sender]
    assert self.balances[_from] >= _value and allowance >= _value, "CUSD::burnFrom: Not enough coins"
    self._burn(_from, _value)
    self.allowances[_from][msg.sender] -= _value
    log Transfer(_from, empty(address), _value)
    return True

@view
@external
def balanceOf(_owner: address) -> uint256:
	return self.balances[_owner]

@view
@external
def allowance(_owner: address, _spender: address) -> uint256:
	return self.allowances[_owner][_spender]

@external 
def approve(_spender: address, _value: uint256) -> bool:
	self.allowances[msg.sender][_spender] = _value
	log Approval(msg.sender, _spender, _value)
	return True

@external
def increaseAllowance(spender: address, _value: uint256) -> bool:
    assert spender != empty(address)
    self.allowances[msg.sender][spender] += _value
    log Approval(msg.sender, spender, self.allowances[msg.sender][spender])
    return True

@external
def decreaseAllowance(spender: address, _value: uint256) -> bool:
    assert spender != empty(address)
    self.allowances[msg.sender][spender] -= _value
    log Approval(msg.sender, spender, self.allowances[msg.sender][spender])
    return True

@external
def mint(_account: address, _value: uint256) -> bool:
    assert msg.sender == self.minter, "CUSD::mint: only minter can mint"
	self._mint(_account, _value)
	log Transfer(empty(address), _account, _value)
	return True

@external
def setMinter(_account: address) -> bool:
    assert msg.sender == self.founder, "CUSD::setMinter: only founder can set minter"
    assert self.founder == self.minter, "CUSD::setMinter: minter already set"
    self.minter = _account # intended to set minting to the issuer contract
    return True

@view
@external
def getInterestFactor() -> uint256:
    return self.interestFactor

@external
def flashMint(_amount: uint256) -> int256:
    assert _amount > 0, "CUSD::flashMint: amount must be greater than 0"
    interest: uint256 = _amount * self.interestFactor / 10000
    self._mint(msg.sender, _amount)
    # user can do anything here, so long as they repay the loan with interest
    ERC20Borrower(msg.sender).erc20DeFi(_amount, interest)
    self._burn(msg.sender, _amount)
    self._transferCoins(msg.sender, self.owner, interest)
    log Flash(msg.sender, _amount, interest)
    return interest
    