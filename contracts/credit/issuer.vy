"""
Credit issuer
- Tracks whitelist of contracts allowed to issue credit
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
"""

"""
Uniswap v3 oracle

change in sqrt price needed to reach 1:1 = (x-1)/20000
where x is the change in the price accumulator

Above function uses a linear approximation of 1.0001**x
"""

