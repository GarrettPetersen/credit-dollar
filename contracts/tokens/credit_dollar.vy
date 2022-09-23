# ERC20 for credit dollar (CUSD)
"""
This contract contains:
- Standard ERC20 functions
- Flashmint, with revenues split equally between burn, LP, and contract owner
- One-time pre-mint to founder
- Prevents minting below a certain token price to maintain peg (need uniswap interface for this? or get from issuer?)
- allows minting only if the issuer has available credit at the given level
"""

from vyper.interfaces import ERC20

implements: ERC20

INIT_SUPPLY: constant(unit256) = 10000000000000000000000000

founder: address
minter: address

totalSupply: public(uint256)
name: public(string[13])
symbol: public(string[4])
balances: Hashmap[address, uint256]
allowances: Hashmap[address, Hashmap[address, uint256]]

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Approval:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

@external
def __init__():
    self.totalSupply = INIT_SUPPLY
    self.name = "Credit Dollar"
    self.symbol = "CUSD"
    self.founder = msg.sender
    self.minter = self.founder
    self.balances[self.founder] = self.totalSupply

@view
@external
def decimals() -> uint256:
    return 18

@internal
def _transferCoins(_src: address, _dst: address, _amount: uint256):
	assert _src != empty(address), "PLW::_transferCoins: cannot transfer from the zero address"
	assert _dst != empty(address), "PLW::_transfersCoins: cannot transfer to the zero address"
	self.balances[_src] -= _amount
	self.balances[_dst] += _amount

@external
def transfer(_to: address, _value: uint256) -> bool:
	assert self.balances[msg.sender] >= _value, "PLW::transfer: Not enough coins"
	self._transferCoins(msg.sender, _to, _value)
	log Transfer(msg.sender, _to, _value)
	return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
	allowance: uint256 = self.allowances[_from][msg.sender]
	assert self.balances[_from] >= _value and allowance >= _value
	self._transferCoins(_from, _to, _value)
	self.allowances[_from][msg.sender] -= _value
	log Transfer(_from, _to, _value)
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
    assert msg.sender == self.minter
	self.totalSupply += _value
	self.balances[_account] += _value
	log Transfer(empty(address), _account, _value)
	return True

@external
def setMinter(_account: address) -> bool:
    assert msg.sender == self.founder
    assert self.founder == self.minter # can only be called once
    self.minter = _account
    return True