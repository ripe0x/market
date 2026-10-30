// Local fork only. Gives anvil account 0 two real mainnet NFTs and signs a local
// WETH offer for each from account 2, written to DEV_OFFERS_FILE for the keeper.
// These offers are test data, not OpenSea orders.
import { writeFileSync } from "node:fs";
import { createTestClient, createWalletClient, http, parseAbi, parseEther, publicActions, type Address } from "viem";
import { mainnet } from "viem/chains";
import { OS_CONDUIT, OS_CONDUIT_KEY, SEAPORT, WETH, orderTypes, seaportAbi, seaportDomain } from "../lib/order";

const rpc = process.env.RPC_URL!;
if (!/127\.0\.0\.1|localhost/.test(rpc)) throw new Error("seed runs against a local fork only");
const t = createTestClient({ chain: mainnet, mode: "anvil", transport: http(rpc) }).extend(publicActions);
const accounts = (await t.request({ method: "eth_accounts" } as any)) as Address[];
const [seller, buyer, bidder] = accounts;
// Anvil's public dev keys carry EIP-7702 delegations on mainnet; make them plain EOAs on this fork.
for (const a of accounts) await t.setCode({ address: a, bytecode: "0x" });
const wallet = (account: Address) => createWalletClient({ account, chain: mainnet, transport: http(rpc) });
const nftAbi = parseAbi(["function ownerOf(uint256) view returns (address)", "function transferFrom(address,address,uint256)"]);

// Real mainnet tokens at the pinned fork block (the fixture collections).
const nfts: { nft: Address; tokenId: bigint; offer: bigint }[] = [
  { nft: "0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258", tokenId: 48816n, offer: parseEther("0.25") },
  { nft: "0x7EEB9b28833934Aa9f79DA82d29AEbFa29b779F3", tokenId: 2066n, offer: parseEther("0.3") },
];

for (const n of nfts) {
  const owner = await t.readContract({ address: n.nft, abi: nftAbi, functionName: "ownerOf", args: [n.tokenId] }).catch(() => null);
  if (!owner) {
    console.log(`skip ${n.nft} ${n.tokenId}: not found`);
    continue;
  }
  if (owner.toLowerCase() !== seller.toLowerCase()) {
    await t.impersonateAccount({ address: owner });
    await t.setBalance({ address: owner, value: parseEther("1") });
    await wallet(owner).writeContract({ address: n.nft, abi: nftAbi, functionName: "transferFrom", args: [owner, seller, n.tokenId] });
    await t.stopImpersonatingAccount({ address: owner });
  }
}

const weth = parseAbi(["function deposit() payable", "function approve(address,uint256) returns (bool)"]);
await wallet(bidder).writeContract({ address: WETH, abi: weth, functionName: "deposit", value: parseEther("10") });
await wallet(bidder).writeContract({ address: WETH, abi: weth, functionName: "approve", args: [OS_CONDUIT, 2n ** 256n - 1n] });

const now = (await t.getBlock()).timestamp;
const counter = await t.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getCounter", args: [bidder] });
const osFee = "0x0000a26b00c1F0DF003000390027140000fAa719" as Address;
const offers = [];
for (const n of nfts) {
  const fee = n.offer / 100n;
  const c = {
    offerer: bidder,
    zone: "0x0000000000000000000000000000000000000000" as Address,
    offer: [{ itemType: 1, token: WETH, identifierOrCriteria: 0n, startAmount: n.offer, endAmount: n.offer }],
    consideration: [
      { itemType: 2, token: n.nft, identifierOrCriteria: n.tokenId, startAmount: 1n, endAmount: 1n, recipient: bidder },
      { itemType: 1, token: WETH, identifierOrCriteria: 0n, startAmount: fee, endAmount: fee, recipient: osFee },
    ],
    orderType: 0,
    startTime: now - 60n,
    endTime: now + 30n * 86400n,
    zoneHash: "0x0000000000000000000000000000000000000000000000000000000000000000" as const,
    salt: n.tokenId,
    conduitKey: OS_CONDUIT_KEY,
    counter,
  };
  const signature = await wallet(bidder).signTypedData({ domain: seaportDomain, types: orderTypes, primaryType: "OrderComponents", message: c });
  const hash = await t.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getOrderHash", args: [c] });
  const { counter: _, ...parameters } = c;
  offers.push({
    hash,
    nft: n.nft,
    tokenId: n.tokenId.toString(),
    order: { parameters: { ...parameters, totalOriginalConsiderationItems: 2n }, numerator: 1n, denominator: 1n, signature, extraData: "0x" },
  });
}
writeFileSync(process.env.DEV_OFFERS_FILE!, JSON.stringify(offers, (_, v) => (typeof v === "bigint" ? v.toString() : v), 1));
console.log(JSON.stringify({ seller, buyer, bidder, nfts: nfts.map((n) => `${n.nft}/${n.tokenId}`), offers: offers.length }));
