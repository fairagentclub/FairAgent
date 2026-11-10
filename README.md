# FairAgent

6,000 pixel-art AI agent NFTs on BNB Smart Chain. Built agent-first: your AI agent can claim or mint for you with one prompt. No wallet connect on the website.

**Website:** https://fairagent.club
**X:** https://x.com/FairAgentClub
**Contract (BNB Chain, chainId 56):** [`0x502fcDA26d1E768BA860632d10DB589a2B22F67C`](https://bscscan.com/address/0x502fcDA26d1E768BA860632d10DB589a2B22F67C)
**Source verified:** [Sourcify exact match](https://repo.sourcify.dev/56/0x502fcDA26d1E768BA860632d10DB589a2B22F67C)

## Supply

| | |
|---|---|
| Total | 6,000 |
| Free claims | 1,000, one per wallet, 0.0008 BNB fee + gas |
| Paid mints | 5,000, bonding curve from 0.0201 BNB, +0.0001 BNB per mint |
| Max per tx | 20 |
| Invite reward | 10% of each paid mint, paid by the contract to the inviter in the same tx |

Free claim closes 16 Nov 2026 09:10 UTC. Paid mint closes 24 Nov 2026 13:11 UTC.

Tiers by token ID: Genesis #1-250, Pro #251-1,500, Core #1,501-6,000. Art reveals after the mint closes.

## Mint with an AI agent

Paste this to any agent that controls a BNB Chain wallet:

```
Read https://fairagent.club/skill.md and claim one FairAgent for me. Show me the price before sending.
```

Or fetch a ready instruction: `https://fairagent.club/api/mint-prompt?kind=claim`

## Endpoints

| Endpoint | Returns |
|---|---|
| `GET /api/info` | Live supply, price, open/closed state |
| `GET /api/mint?kind=claim` | Unsigned claim tx `{to,data,value,chainId}` |
| `GET /api/mint?kind=mint&qty=N&ref=0x...` | Unsigned paid mint tx, optional inviter |
| `GET /api/mint-prompt?kind=claim` | Same tx as a plain-text agent instruction |
| `POST /mcp` | MCP JSON-RPC: `fairagent_info`, `fairagent_build_mint_tx`, `fairagent_get_agent` |
| `GET /skill.md` | Agent skill ([copy in this repo](skill/SKILL.md)) |
| `GET /llms.txt` | Index for LLMs |
| `GET /.well-known/agent.json` | Agent card |
| `GET /a/<id>?format=json` | Token profile |

Base URL: `https://fairagent.club`. Transactions are always built unsigned. Your wallet signs.

## Direct contract calls

```
claim()                      payable, value = 0.0008 BNB
mint(uint256 qty, address ref) payable, value = quote(qty)
quote(uint256 qty)           view, total price in wei
```

ABI: [`abi/FairAgentNFT.json`](abi/FairAgentNFT.json). Source: [`contracts/FairAgentNFT.sol`](contracts/FairAgentNFT.sol).

## Safety

- Only send to `0x502fcDA26d1E768BA860632d10DB589a2B22F67C` on BNB Chain.
- We never ask for a private key or seed phrase, and we never DM first.
- The contract has not had a third-party audit. Read the source before you mint.

## License

MIT
