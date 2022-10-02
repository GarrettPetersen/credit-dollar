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
USDT (6), USDC (6), BUSD (18), DAI (18), FRAX (18), BEAN (6), LUSD (18)
"""

from vyper.interfaces import ERC20

founder: address
cusdAddress: address
cusd: ERC20


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

@external
def __init__(_cusd_address: address, _exchange_addresses: address[6]):
    self.founder = msg.sender
    self.cusdAddress = _cusd_address
    self.cusd = ERC20(_cusd_address)
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
    target_price_exponent: uint256 = 18 + token0_decimals - token1_decimals
    avg_tick: uint256 = 10**18 * uint256(tickCumulativeDelta) / timeElapsed
    avg_reciprocal_liquidity: uint256 = 10**18 * uint256(secondsPerLiquidityCumulativeX128Delta) / timeElapsed
    avg_sqrt_price_difference_from_target: int128 = (10**18 * 1.0001 ** (avg_tick / (2*10**18)) - 10**target_price_exponent)
    if token1 == self.cusdAddress:
        return avg_sqrt_price_difference_from_target / avg_reciprocal_liquidity
    else:
        return 10**36 / (avg_sqrt_price_difference_from_target * avg_reciprocal_liquidity)
