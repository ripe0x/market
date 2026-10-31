// Local fork only. Gives anvil account 0 two real mainnet NFTs, deposits one as a
// declining listing, and funds a collection bid from account 2 on the other NFT's
// collection, so the UI has a listing to buy and a bid to sell into. The keeper
// matches any same-collection listing and bid it can settle at a profit.
import { createTestClient, createWalletClient, http, parseAbi, parseEther, publicActions, type Address } from "viem";
import { mainnet } from "viem/chains";
import { MARKET, WETH, fixedPrice, listData, marketAbi, type Bid, type Listing } from "../lib/order";

const rpc = process.env.RPC_URL!;
if (!/127\.0\.0\.1|localhost/.test(rpc)) throw new Error("seed runs against a local fork only");
if (MARKET === "0x0000000000000000000000000000000000000000") throw new Error("NEXT_PUBLIC_MARKET_ADDRESS not set");

const t = createTestClient({ chain: mainnet, mode: "anvil", transport: http(rpc) }).extend(publicActions);
const accounts = (await t.request({ method: "eth_accounts" } as any)) as Address[];
const [seller, , bidder] = accounts;
// Anvil's public dev keys carry EIP-7702 delegations on mainnet; make them plain EOAs on this fork.
for (const a of accounts) await t.setCode({ address: a, bytecode: "0x" });
const wallet = (account: Address) => createWalletClient({ account, chain: mainnet, transport: http(rpc) });
const erc721 = parseAbi(["function ownerOf(uint256) view returns (address)", "function transferFrom(address,address,uint256)", "function safeTransferFrom(address,address,uint256,bytes)"]);

// Real mainnet tokens at the pinned fork block (the fixture collections).
const nfts: { nft: Address; tokenId: bigint }[] = [
  { nft: "0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258", tokenId: 48816n },
  { nft: "0x7EEB9b28833934Aa9f79DA82d29AEbFa29b779F3", tokenId: 2066n },
];

for (const n of nfts) {
  const owner = await t.readContract({ address: n.nft, abi: erc721, functionName: "ownerOf", args: [n.tokenId] }).catch(() => null);
  if (!owner) {
    console.log(`skip ${n.nft} ${n.tokenId}: not found`);
    continue;
  }
  if (owner.toLowerCase() !== seller.toLowerCase()) {
    await t.impersonateAccount({ address: owner });
    await t.setBalance({ address: owner, value: parseEther("1") });
    await wallet(owner).writeContract({ address: n.nft, abi: erc721, functionName: "transferFrom", args: [owner, seller, n.tokenId] });
    await t.stopImpersonatingAccount({ address: owner });
  }
}

const now = Number((await t.getBlock()).timestamp);

// Listing: deposit NFT #1 as a declining price (seller keeps NFT #2 to sell into the bid).
const a = nfts[0];
const listing: Listing = {
  seller,
  nft: a.nft,
  tokenId: a.tokenId,
  currency: WETH,
  recipient: seller,
  floor: parseEther("0.15"),
  expiry: now + 7 * 86400,
  price: { start: parseEther("0.3"), end: parseEther("0.15"), startTime: now, endTime: now + 7 * 86400, strategy: "0x0000000000000000000000000000000000000000", data: `0x${"0".repeat(64)}` },
};
await wallet(seller).writeContract({ address: a.nft, abi: erc721, functionName: "safeTransferFrom", args: [seller, MARKET, a.tokenId, listData(listing)] });

// Bid: a whole-collection WETH bid on NFT #2's collection, funded with ETH.
const b = nfts[1];
const budget = parseEther("0.3");
const bid: Bid = {
  buyer: "0x0000000000000000000000000000000000000000",
  recipient: bidder,
  nft: b.nft,
  minTokenId: 0n,
  maxTokenId: (1n << 256n) - 1n,
  currency: WETH,
  budget,
  maxPrice: budget,
  quantity: 1,
  expiry: now + 7 * 86400,
  price: fixedPrice(budget),
};
await wallet(bidder).writeContract({ address: MARKET, abi: marketAbi, functionName: "createBid", args: [bid], value: budget });

console.log(JSON.stringify({ market: MARKET, seller, bidder, listed: `${a.nft}/${a.tokenId}`, bidOn: `${b.nft}/${b.tokenId}` }));
