"""
Credit issuer
- current issuance level = the credit level being issued credit right now
- Tracks available credit at each credit level
- Tracks max credit at each credit level
    - max credit = total credit it is possible for all borrowers to borrow at a give credit level
    - credit target = max credit at the current level when the issuer first reached that level
- Update action that can be called once per hour for a small fee
    - Fee increases if called late
    - Issues new credit equal to the amount of CUSD needed to balance the exchange(s)
    - Rotates through credit levels in descending order issuing new credit up to the credit target
    - When credit target is reached, decrement the current issuance level by one and set a new credit target
        - If the issuance level hits 0, loop back to the max level

Info tied to a given ERC721:
- Owner
- Tracks credit level
- Allows borrowing if the issuer has made credit available and minting isn't blocked
- Tracks outstanding debt plus penalties
- Allows repayment of loans and penalties
- Loan repayments are burned
- Penalties split equally between burn, LP, and contract owner
- Tracks last payment or penalty, both of which reset the countdown to future penalties and delinquency
- NFTs cannot be transferred with outstanding debt
- NFTs can be seized if they are delinquent with no recent minimum payments
- On full repayment of debt, increases credit level by one and updates max credit numbers for issuer
"""

"""
Uniswap v3 oracle
- Tracks the price of CUSD

Uniswap pools to start before deploying this contract (decimals):
USDT (6), USDC (6), BUSD (18), DAI (18), FRAX (18), LUSD (18)
"""

from vyper.interfaces import ERC20
from vyper.interfaces import ERC721

founder: address
cusdAddress: address
cusd: ERC20
creditBuffer: int128
lastUpdate: uint256
maxLevel: uint256
nextLevel: uint256

enum status:
    READY
    BORROWING
    OVERDUE
    DELINQUENT

struct lineOfCredit:
    creditLevel: uint256
    multiplier: uint256
    status: status
    lastEvent: uint256
    outstandingDebt: uint256
    outstandingPenalty: uint256
    owner: address
    payee: address

linesOfCredit: HashMap[address, HashMap[uint256,lineOfCredit]]

struct levelCredit:
    maxCredit: uint256
    availableCredit: uint256

creditLevels: HashMap[uint256, levelCredit]

struct exchange:
    exchangeAddress: address
    lastTickCumulative: int56
    lastBlockTimestamp: uint32
    lastSecondsPerLiquidityCumulativeX128: uint160

exchanges: exchange[6]

interface UniswapV3Pool:
    def token0() -> address: view
    def token1() -> address: view
    # [secondsAgo] -> [blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128]
    def observe([uint32]) -> (uint32, int56, uint160): view

event NewLineOfCredit:
    owner: address
    nft: address
    nft_id: uint256
    multiplier: uint256
    payee: address

event Borrow:
    owner: address
    nft: address
    nft_id: uint256
    amount: uint256

event Repay:
    owner: address
    nft: address
    nft_id: uint256
    amount: uint256
    payee: address
    payee_revenue: uint256

event Liquidation:
    old_owner: address
    liquidator: address
    nft: address
    nft_id: uint256
    amount: uint256
    payee: address
    payee_revenue: uint256


@external
def __init__(_cusd_address: address, _exchange_addresses: address[6]):
    self.founder = msg.sender
    self.cusdAddress = _cusd_address
    self.cusd = ERC20(_cusd_address)
    self.creditLevels[1] = {
        maxCredit: 0,
        availableCredit: 0
    }

    for i in range(6):
        self.exchanges[i].exchangeAddress = _exchange_addresses[i]
    


@internal
def _get_uniswap_token_imbalance(i: uint256) -> int128:
    pool: UniswapV3Pool = UniswapV3Pool(exchanges[i].exchangeAddress)
    token0: address = pool.token0()
    token1: address = pool.token1()
    token0_decimals: uint256 = ERC20(token0).decimals()
    token1_decimals: uint256 = ERC20(token1).decimals()
    (blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128) = pool.observe([0])
    timeElapsed: uint32 = (blockTimestamp - exchanges[i].lastBlockTimestamp) % 2**32
    exchanges[i].lastBlockTimestamp = blockTimestamp
    tickCumulativeDelta: int56 = tickCumulative - exchanges[i].lastTickCumulative
    exchanges[i].lastTickCumulative = tickCumulative
    secondsPerLiquidityCumulativeX128Delta: uint160 = secondsPerLiquidityCumulativeX128 - exchanges[i].lastSecondsPerLiquidityCumulativeX128
    exchanges[i].lastSecondsPerLiquidityCumulativeX128 = secondsPerLiquidityCumulativeX128
    target_price_exponent: uint256 = token0_decimals - token1_decimals
    avg_tick: decimal = uint256(tickCumulativeDelta) / timeElapsed
    avg_reciprocal_liquidity: decimal = uint256(secondsPerLiquidityCumulativeX128Delta) / timeElapsed
    avg_sqrt_price_difference_from_target: decimal = (1.0001 ** (avg_tick / 2) - 10**target_price_exponent)
    if token1 == self.cusdAddress:
        return int128(avg_sqrt_price_difference_from_target / avg_reciprocal_liquidity)
    else:
        return int128(1 / (avg_sqrt_price_difference_from_target * avg_reciprocal_liquidity))

@internal
def _credit_limit(_level: uint256, _multiplier: uint256) -> uint256:
    # returns the triangle number of the level
    return _multiplier * _level * (_level + 1) / 2

@internal
def _issue_credit() -> bool:
    if self.creditBuffer <= 0:
        self.creditBuffer = 0
        return True

    for i in range(10):
        credit_to_issue: int128 = self.creditLevels[self.nextLevel].maxCredit - self.creditLevels[self.nextLevel].availableCredit
        if credit_to_issue <= 0:
            self.nextLevel -= 1
            if self.nextLevel == 0:
                self.nextLevel = self.maxLevel
            continue
        elif self.creditBuffer < credit_to_issue:
            self.creditLevels[self.nextLevel].availableCredit += self.creditBuffer
            self.creditBuffer = 0
            return True
        else:
            self.creditLevels[self.nextLevel].availableCredit = self.creditLevels[self.nextLevel].maxCredit
            self.creditBuffer -= credit_to_issue
            self.nextLevel -= 1
            if self.nextLevel == 0:
                self.nextLevel = self.maxLevel

@internal
def _switchboard():
    time_since_last_update: uint256 = block.timestamp - self.lastUpdate
    if time_since_last_update <= 500:
        return True
    else:
        self.lastUpdate = block.timestamp
        self.cusd.mint(msg.sender, 10**19) # compensate for gas
    
    magic_number: int256 = block.timestamp / 500 % 7
    if magic_number <= 5:
        self.creditBuffer += self._get_uniswap_token_imbalance(magic_number)
    else:
        self._issue_credit()

@internal
def _update_borrow_status(_nft: address, _nft_id: uint256) -> bool:
    current_status: status = self.linesOfCredit[_nft][_nft_id].status
    if current_status == READY or current_status == DELINQUENT:
        return True
    time_since_last_update: uint256 = block.timestamp - self.linesOfCredit[_nft][_nft_id].lastEvent
    if time_since_last_update <= 2592000:
        return True
    elif time_since_last_update > 5184000:
        self.linesOfCredit[_nft][_nft_id].status = DELINQUENT
        return True
    elif current_status == BORROWING:
        self.linesOfCredit[_nft][_nft_id].status = OVERDUE
        self.linesOfCredit[_nft][_nft_id].lastEvent += 2592000
        return True
    elif current_status == OVERDUE:
        self.linesOfCredit[_nft][_nft_id].status = DELINQUENT
        return True
    else:
        return False

@external
def approveNFT(_nft_address: address, _nft_id: uint256):
    ERC721(_nft_address).approve(_nft_id, self)

@external
def approveCUSD(_amount: uint256):
    self.cusd.approve(self, _amount)

@external
def openLineOfCredit(_nft_address: address, _nft_id: uint256, _multiplier: uint256, _payee: address) -> bool:
    assert _multiplier in {100, 1000, 10000, 100000}
    assert ERC721(_nft_address).ownerOf(_nft_id) == msg.sender
    assert not self.linesOfCredit[_nft_address] or not self.linesOfCredit[_nft_address][_nft_id]
    assert _payee != ZERO_ADDRESS and _payee != msg.sender
    self.cusd.burnFrom(msg.sender, 5 * _multiplier * 10**18)
    self.linesOfCredit[_nft_address][_nft_id] = {
        creditLevel: 1,
        multiplier: _multiplier,
        status: status.READY,
        lastEvent: block.timestamp,
        outstandingDebt: 0,
        outstandingPenalty: 0,
        owner: msg.sender,
        payee: msg.sender
    }
    log OpenLineOfCredit(msg.sender, _nft_address, _nft_id, _multiplier, _payee)
    return True

@external
def borrow(_nft_address: address, _nft_id: uint256, _amount: uint256) -> bool:
    assert self.linesOfCredit[_nft_address][_nft_id].status == status.READY
    assert self.linesOfCredit[_nft_address][_nft_id].owner == msg.sender
    self._switchboard()
    assert self.creditLevels[credit_level].availableCredit >= _amount
    assert _amount <= self._credit_limit(self.linesOfCredit[_nft_address][_nft_id].creditLevel, self.linesOfCredit[_nft_address][_nft_id].multiplier)
    self.linesOfCredit[_nft_address][_nft_id].status = status.BORROWING
    self.creditLevels[self.linesOfCredit[_nft_address][_nft_id].creditLevel].availableCredit -= _amount
    self.linesOfCredit[_nft_address][_nft_id].outstandingDebt += _amount
    self.linesOfCredit[_nft_address][_nft_id].lastEvent = block.timestamp
    self.cusd.mint(msg.sender, _amount)
    log Borrow(msg.sender, _nft_address, _nft_id, _amount)
    return True
