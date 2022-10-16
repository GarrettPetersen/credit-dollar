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
- NFTs can be seized if they are LIQUIDATABLE with no recent minimum payments
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
payee: ERC721
creditBuffer: int128
lastUpdate: uint256
maxLevel: uint256
nextLevel: uint256
MONTH_IN_SECONDS: constant(uint256) = 2592000
DECIMAL_MULTIPLIER: constant(uint256) = 10**18

enum Status:
    READY
    BORROWING
    OVERDUE
    LIQUIDATABLE

enum Protocol:
    HEALTHY
    UNHEALTHY
    EMERGENCY

protocolStatus: public(Protocol)

struct lineOfCredit:
    creditLevel: uint256
    status: status
    loanTime: uint256
    lastEvent: uint256
    outstandingDebt: uint256
    outstandingPenalty: uint256
    owner: address
    payee: uint256

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

struct payeeInfo:
    numBorrowers: uint256
    totalRevenue: uint256

payees: HashMap[uint256, payeeInfo]

interface UniswapV3Pool:
    def token0() -> address: view
    def token1() -> address: view
    # [secondsAgo] -> [blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128]
    def observe([uint32]) -> (uint32, int56, uint160): view

event NewLineOfCredit:
    owner: address
    nft: address
    nft_id: uint256
    payee: uint256

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
    payee: uint256
    payee_revenue: uint256

event Liquidation:
    old_owner: address
    liquidator: address
    nft: address
    nft_id: uint256
    amount: uint256
    payee: uint256
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
    self.payees = {}
    self.protocolStatus = Protocol.HEALTHY

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
def _credit_limit(_level: uint256) -> uint256:
    # returns the triangle number of the level * 100
    return DECIMAL_MULTIPLIER * 100 * _level * (_level + 1) / 2

@internal
def _issue_credit() -> bool:
    if self.creditBuffer <= 0:
        self.creditBuffer = 0
        if self.protocolStatus == Protocol.HEALTHY:
            self.protocolStatus = Protocol.UNHEALTHY
        elif self.protocolStatus == Protocol.UNHEALTHY:
            self.protocolStatus = Protocol.EMERGENCY
        return True
    else:
        self.protocolStatus = Protocol.HEALTHY

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
    return True

@internal
def _switchboard():
    time_since_last_update: uint256 = block.timestamp - self.lastUpdate
    if time_since_last_update <= 500:
        return True
    else:
        self.lastUpdate = block.timestamp
        self.cusd.mint(msg.sender, 10 * DECIMAL_MULTIPLIER) # compensate for gas
    
    magic_number: int256 = block.timestamp / 500 % 7
    if magic_number <= 5:
        self.creditBuffer += self._get_uniswap_token_imbalance(magic_number)
    else:
        self._issue_credit()

@internal
def _update_borrow_status(_nft: address, _nft_id: uint256) -> bool:
    current_status: status = self.linesOfCredit[_nft][_nft_id].status
    current_level: uint256 = self.linesOfCredit[_nft][_nft_id].level
    if current_status == Status.READY or current_status == Status.LIQUIDATABLE:
        return True
    time_since_last_update: uint256 = block.timestamp - self.linesOfCredit[_nft][_nft_id].lastEvent
    if time_since_last_update <= MONTH_IN_SECONDS:
        return True
    elif time_since_last_update > MONTH_IN_SECONDS*2:
        if current_status == Status.BORROWING:
            self.linesOfCredit[_nft][_nft_id].outstandingPenalty += 2 * current_level * DECIMAL_MULTIPLIER * 100
        elif current_status == Status.OVERDUE:
            self.linesOfCredit[_nft][_nft_id].outstandingPenalty += current_level * DECIMAL_MULTIPLIER * 100
        self.linesOfCredit[_nft][_nft_id].status = Status.LIQUIDATABLE
        return True
    elif current_status == Status.BORROWING:
        self.linesOfCredit[_nft][_nft_id].penalty += current_level * DECIMAL_MULTIPLIER * 100
        self.linesOfCredit[_nft][_nft_id].status = Status.OVERDUE
        self.linesOfCredit[_nft][_nft_id].lastEvent += MONTH_IN_SECONDS
        return True
    elif current_status == Status.OVERDUE:
        self.linesOfCredit[_nft][_nft_id].penalty += current_level * DECIMAL_MULTIPLIER * 100
        self.linesOfCredit[_nft][_nft_id].status = Status.LIQUIDATABLE
        return True
    else:
        return False

@internal
def _pay_debt(_nft: address, _nft_id: address, _amount: uint256):
    cusd.burnFrom(msg.sender, _amount)
    self.linesOfCredit[_nft][_nft_id].outstandingDebt -= _amount

@internal
def _pay_penalty(_nft: address, _nft_id: uint256, _amount: uint256):
    split: uint256 = _amount / 2
    self.cusd.burnFrom(msg.sender, split)
    self.cusd.transferFrom(
        msg.sender,
        payee.ownerOf(linesOfCredit[_nft][_nft_id].payee),
        split
    )
    self.payees[self.linesOfCredit[_nft][_nft_id].payee].totalRevenue += split
    self.linesOfCredit[_nft][_nft_id].outstandingPenalty -= _amount

@internal
def _close_loan(_nft: address, _nft_id: uint256):
    self._pay_debt(_nft, _nft_id, self.linesOfCredit[_nft][_nft_id].outstandingDebt)
    self._pay_penalty(_nft, _nft_id, self.linesOfCredit[_nft][_nft_id].outstandingPenalty)
    self.linesOfCredit[_nft][_nft_id].status = Status.READY
    self.linesOfCredit[_nft][_nft_id].creditLevel += 1
    ERC721(_nft).transferFrom(
        self,
        self.linesOfCredit[_nft][_nft_id].owner,
        _nft_id
    )

@external
def approveNFT(_nft_address: address, _nft_id: uint256):
    ERC721(_nft_address).approve(self, _nft_id)

@external
def approveCUSD(_amount: uint256):
    self.cusd.approve(self, _amount)

@external
def openLineOfCredit(_nft_address: address, _nft_id: uint256, _payee: uint256) -> bool:
    assert ERC721(_nft_address).ownerOf(_nft_id) == msg.sender
    assert not self.linesOfCredit[_nft_address] or not self.linesOfCredit[_nft_address][_nft_id]
    assert payee(_payee).ownerOf() != empty(address)

    self._switchboard()
    self.cusd.burnFrom(msg.sender, 500 * DECIMAL_MULTIPLIER)
    self.linesOfCredit[_nft_address][_nft_id] = {
        creditLevel: 1,
        status: Status.READY,
        loanTime: block.timestamp,
        lastEvent: block.timestamp,
        outstandingDebt: 0,
        outstandingPenalty: 0,
        owner: msg.sender,
        payee: _payee
    }
    self.payees[_payee].numBorrowers += 1
    log OpenLineOfCredit(msg.sender, _nft_address, _nft_id, _payee)
    return True

@external
def borrow(_nft_address: address, _nft_id: uint256) -> bool:
    assert self.linesOfCredit[_nft_address][_nft_id].status == Status.READY
    assert self.linesOfCredit[_nft_address][_nft_id].owner == msg.sender
    assert self.protocolStatus != Protocol.EMERGENCY

    # You can't take out a loan within 15 days of the start of your last loan (prevents rapid-fire loans)
    assert self.linesOfCredit[_nft_address][_nft_id].loanTime <= block.timestamp - MONTH_IN_SECONDS/2

    borrow_amount: uint256 = self._credit_limit(self.linesOfCredit[_nft_address][_nft_id].creditLevel)
    assert self.creditLevels[credit_level].availableCredit >= borrow_amount
    assert _amount <= self._credit_limit(self.linesOfCredit[_nft_address][_nft_id].creditLevel)
    self._switchboard()
    ERC721(_nft_address).transferFrom(
        msg.sender,
        self,
        _nft_id
    )
    self.linesOfCredit[_nft_address][_nft_id].status = Status.BORROWING
    self.creditLevels[self.linesOfCredit[_nft_address][_nft_id].creditLevel].availableCredit -= borrow_amount
    self.linesOfCredit[_nft_address][_nft_id].outstandingDebt += borrow_amount
    self.linesOfCredit[_nft_address][_nft_id].loanTime = block.timestamp
    self.linesOfCredit[_nft_address][_nft_id].lastEvent = block.timestamp
    self.cusd.mint(msg.sender, borrow_amount)
    log Borrow(msg.sender, _nft_address, _nft_id, borrow_amount)
    return True

@external
def repay(_nft_address: address, _nft_id: uint256, _amount: uint256) -> bool:
    assert _amount > 0
    self._update_borrow_status(_nft_address, _nft_id)
    debt: uint256 = self.linesOfCredit[_nft_address][_nft_id].outstandingDebt
    penalty: uint256 = self.linesOfCredit[_nft_address][_nft_id].outstandingPenalty
    total_owed: uint256 = debt + penalty
    assert total_owed > 0
    min_payment: uint256 = self.linesOfCredit[_nft_address][_nft_id].creditLevel * 100 * DECIMAL_MULTIPLIER
    if _amount >= min_payment:
        # Allows liquidatable NFTs to be saved by the user
        self.linesOfCredit[_nft_address][_nft_id].lastEvent = block.timestamp
        if self.linesOfCredit[_nft_address][_nft_id].status == Status.LIQUIDATABLE:
            self.linesOfCredit[_nft_address][_nft_id].status = Status.OVERDUE

    self._switchboard()
    if _amount >= total_owed:
        self._close_loan(_nft_address, _nft_id)
    elif _amount > debt:
        self._pay_debt(_nft_address, _nft_id, debt)
        self._pay_penalty(_nft_address, _nft_id, _amount - debt)
    else:
        self._pay_debt(_nft_address, _nft_id, _amount)
    return True

@external
def liquidate(_nft_address: address, _nft_id: uint256) -> bool:
    self._update_borrow_status(_nft_address, _nft_id)
    assert self.linesOfCredit[_nft_address][_nft_id].status == Status.LIQUIDATABLE
    self._switchboard()
    old_owner: address = self.linesOfCredit[_nft_address][_nft_id].owner
    self.linesOfCredit[_nft_address][_nft_id].owner = msg.sender
    self._close_loan(_nft_address, _nft_id)
    log Liquidate(old_owner, msg.sender, _nft_address, _nft_id)
    return True

@view
@external
def getPayeeNumBorrowers(_payee: uint256) -> uint256:
    return self.payees[_payee].numBorrowers

@view
@external
def getPayeeTotalRevenue(_payee: uint256) -> uint256:
    return self.payees[_payee].totalRevenue