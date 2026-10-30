# Market

A simple, noncustodial way to sell an Ethereum NFT without repeatedly repricing it.

The seller sets a starting price, a minimum acceptable net price and a schedule. The asking price declines over time. Buyers can purchase directly. A small matcher also checks existing onchain offers, beginning with OpenSea Seaport offers, and executes an eligible sale atomically when it can meet the seller's terms. The seller receives the net proceeds from the executed bid after disclosed fees, including any amount above the current minimum.

This is a standalone project. No CC integration, native token or new pool of liquidity is required.

## Read first

1. [CLAUDE.md](CLAUDE.md)
2. [Functional spec](docs/FUNCTIONAL_SPEC.md)
3. [Roadmap](docs/ROADMAP.md)
4. [Decisions and owner review](docs/DECISIONS.md)
5. [Current status](docs/STATUS.md)

The first engineering gate is proving that a real, signed OpenSea offer can be settled atomically against a seller authorization on a pinned Ethereum mainnet fork while enforcing the seller's net proceeds. The specification does not assume this has already been proven.

## Reference implementation targets

Use established Seaport functionality before introducing custom settlement contracts. Build a small web application, one matcher worker and the least onchain authorization or settlement code needed. Research and adopt the official Ponytail instructions to keep the implementation compact without taking shortcuts on security.

Nothing is deployed. This package contains specifications only.
