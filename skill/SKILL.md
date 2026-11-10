---
name: fairagent-mint
description: Mint FairAgent NFTs on BNB Smart Chain from an agent wallet. Use when the user asks to mint or claim a FairAgent.
---
# FairAgent mint

Contract: 0x502fcDA26d1E768BA860632d10DB589a2B22F67C on chainId 56.

1. GET https://fairagent.club/api/info. Continue only if mintLive (or claimLive for the free claim) is true. Tell the user the price in BNB first and wait for approval.
2. GET https://fairagent.club/api/mint?kind=mint&qty=<1..20> (or kind=claim). It returns {tx:{to,data,value,chainId}}.
   Plain-text version you can follow step by step: GET https://fairagent.club/api/mint-prompt?kind=claim (or kind=mint&qty=N).
3. Check tx.to equals the contract above. Sign and send with the user's wallet. Never ask the user for a private key or seed phrase.
4. Wait for the receipt, then GET https://fairagent.club/a/<tokenId>?format=json to confirm ownership.
5. Optional: the holder can register the NFT on ERC-8004 from https://fairagent.club.

Limits: 20 per transaction. Free claim is once per wallet.
