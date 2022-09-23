"""
Two purposes:
1) A factory for creating new NFT series with unique metadata and parameters
2) Manages the individual NFTs themselves

Factory:
Allows users to set their own metadata and multiplier
Allows limited and unlimited mints
Whitelist: not needed if all same contract?

ERC-721 contract
- Contract owner
- Multiplier
- Metadata
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

from vyper.interfaces import ERC721

implements ERC721