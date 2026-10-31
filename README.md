# Market

Sell an Ethereum NFT at a price that falls until it sells.

The seller signs a Seaport listing: a start price, a floor, and how long the fall takes. The NFT stays in the seller's wallet. Anyone can buy at the current price. A keeper also sells the listing into existing OpenSea offers when one covers the current price; the seller then gets everything the offer pays beyond its own fees, minus 0.5%.

## How it works

- `contracts/Market.sol` is the listing's Seaport zone and its only fulfiller. Seaport skips zone checks only when the zone itself calls, so a listing restricted to Market can only fill through `Market.buy` or `Market.matchOffer`. Market holds no approvals, no funds between transactions, and has no owner.
- `app/` is a Next.js app (browse, sell, listing, yours) and the keeper (`app/keeper/run.ts`), sharing one SQLite file.

## Start

```bash
git submodule update --init && (cd app && npm ci)
```

```bash
scripts/fork.sh
```

Opens a local mainnet fork with Market deployed, two seeded NFTs and local test offers, the app on http://localhost:3000 and the keeper.

## Docs

1. [Functional spec](docs/FUNCTIONAL_SPEC.md)
2. [Phase 0 evidence](docs/PHASE0_EVIDENCE.md)
3. [Decisions and owner review](docs/DECISIONS.md)
4. [Security](docs/SECURITY.md)
5. [Economics](docs/ECONOMICS.md)
6. [Operations](docs/OPERATIONS.md)
7. [Status](docs/STATUS.md)

Nothing is deployed. Not audited.
