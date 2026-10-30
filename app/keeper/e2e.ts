// Keeper integration on an anvil mainnet fork, covering both settlement routes:
//   1. OpenSea fill — a real signed OpenSea offer, with OpenSea's real zone
//      signature, filled from escrow through Market.fillOffer. The fork is pinned
//      one block before the offer's real fill; Market's runtime code is placed at
//      the fulfiller address OpenSea's zone signed for, and the SignedZone is
//      enabled in Market's storage, so the real zone and signer validate.
//   2. Native match — a Market listing matched into a Market bid via matchBid.
// The keeper's production round does the work in both cases.
//   npm run e2e:keeper     (needs anvil and `forge build` output)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTestClient, createWalletClient, decodeFunctionData, encodeAbiParameters, encodeDeployData, http, keccak256, parseAbi, publicActions, toHex, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import type { Bid, Listing } from "../lib/order";

const root = new URL("../../", import.meta.url).pathname;
const fixture = JSON.parse(readFileSync(join(root, "test/fixtures/item_offer.json"), "utf8"));
const PORT = 8611;
const rpc = `http://127.0.0.1:${PORT}`;
const fulfiller = fixture.from as Address; // the address OpenSea's zone signature names
const dir = mkdtempSync(join(tmpdir(), "market-e2e-"));

// Module-level config in lib/ reads env at import time. Market lives at the fulfiller.
const keeperKey = generatePrivateKey();
Object.assign(process.env, {
  RPC_URL: rpc,
  NEXT_PUBLIC_MARKET_ADDRESS: fulfiller,
  DB_PATH: join(dir, "e2e.db"),
  KEEPER_PRIVATE_KEY: keeperKey,
  DEV_OFFERS_FILE: join(dir, "offers.json"),
  CONFIRMATIONS: "0",
  PROFIT_MARGIN: "0", // this 0.06 WETH sale is below the default margin; feasibility is in ECONOMICS.md
  START_BLOCK: String(fixture.block - 1),
});

const anvil = spawn("anvil", ["--fork-url", "https://mainnet.gateway.tenderly.co", "--fork-block-number", String(fixture.block - 1), "--port", String(PORT), "--silent"], { stdio: "inherit" });
const done = () => anvil.kill();
process.on("exit", done);

const test = createTestClient({ chain: mainnet, mode: "anvil", transport: http(rpc) }).extend(publicActions);
for (let i = 0; ; i++) {
  try {
    await test.getBlockNumber();
    break;
  } catch {
    if (i > 100) throw new Error("anvil did not start");
    await new Promise((r) => setTimeout(r, 200));
  }
}

const { WETH, OS_ZONE, erc721Abi, listData, marketAbi, seaportAbi, fixedPrice } = await import("../lib/order");
const { db } = await import("../lib/server");
const { round } = await import("./run");

const wethAbi = parseAbi(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function deposit() payable"]);
const bal = (a: Address) => test.readContract({ address: WETH, abi: wethAbi, functionName: "balanceOf", args: [a] });

// Decode the real matchAdvancedOrders calldata the offer was filled with.
const { args } = decodeFunctionData({ abi: seaportAbi, data: fixture.input as Hex });
const orders = (args as any)[0] as any[];
const resolvers = (args as any)[1] as any[];
const stringify = (x: unknown) => JSON.parse(JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
// The offer is the order whose offerer is not the fulfiller (the other is OpenSea's mirror).
const offerOrder = orders.find((o) => o.parameters.offerer.toLowerCase() !== fulfiller.toLowerCase()) ?? orders[0];
const bidder = offerOrder.parameters.offerer as Address;
const nft = offerOrder.parameters.consideration[0].token as Address;
const tokenId = BigInt(offerOrder.parameters.consideration[0].identifierOrCriteria);
// WETH the offer releases to Market = offered amount minus its WETH fee consideration.
let available = BigInt(offerOrder.parameters.offer[0].endAmount);
for (const c of offerOrder.parameters.consideration.slice(1)) available -= BigInt(c.endAmount);

// Throwaway accounts.
const seller = privateKeyToAccount(generatePrivateKey());
const keeper = privateKeyToAccount(keeperKey);
const protocol = privateKeyToAccount(generatePrivateKey()).address;
for (const a of [seller.address, keeper.address]) await test.setBalance({ address: a, value: 10n ** 18n });

// Move the NFT from its actual current owner to the throwaway seller.
const nftOwner = await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] });
await test.impersonateAccount({ address: nftOwner });
await test.setBalance({ address: nftOwner, value: 10n ** 18n });
await createWalletClient({ account: nftOwner, chain: mainnet, transport: http(rpc) }).writeContract({ address: nft, abi: parseAbi(["function transferFrom(address,address,uint256)"]), functionName: "transferFrom", args: [nftOwner, seller.address, tokenId] });
await test.stopImpersonatingAccount({ address: nftOwner });

// Sweep any stray WETH out of the fulfiller address so Market starts empty.
await test.impersonateAccount({ address: fulfiller });
await test.setBalance({ address: fulfiller, value: 10n ** 18n });
const stray = await bal(fulfiller);
if (stray) await createWalletClient({ account: fulfiller, chain: mainnet, transport: http(rpc) }).writeContract({ address: WETH, abi: wethAbi, functionName: "transfer", args: [(protocol.replace(/.$/, "0")) as Address, stray] });
await test.stopImpersonatingAccount({ address: fulfiller });

// Deploy Market (its immutables are baked into runtime code at deploy), place that
// code at the fulfiller, and enable the SignedZone in the fulfiller's own storage
// (setCode copies code, not storage). zones mapping is slot 2.
const artifact = JSON.parse(readFileSync(join(root, "out/Market.sol/Market.json"), "utf8"));
const deployer = createWalletClient({ account: keeper, chain: mainnet, transport: http(rpc) });
const deployTx = await deployer.sendTransaction({ data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object, args: [protocol, protocol, OS_ZONE] }) });
const deployed = (await test.waitForTransactionReceipt({ hash: deployTx })).contractAddress!;
await test.setCode({ address: fulfiller, bytecode: (await test.getCode({ address: deployed }))! });
const zoneSlot = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [OS_ZONE, 2n]));
await test.setStorageAt({ address: fulfiller, index: zoneSlot, value: toHex(1n, { size: 32 }) });
assert.equal(await test.readContract({ address: fulfiller, abi: marketAbi, functionName: "zones", args: [OS_ZONE] }), true, "zone enabled");

// ---- Phase 1: OpenSea fill from escrow ----
const sellerWallet = createWalletClient({ account: seller, chain: mainnet, transport: http(rpc) });
const now = (await test.getBlock()).timestamp;
const ask = available / 2n; // comfortably below the net proceeds
const listing: Listing = { seller: seller.address, nft, tokenId, currency: WETH, recipient: seller.address, floor: ask, expiry: Number(now) + 86400, price: fixedPrice(ask) };
const depositHash = await sellerWallet.writeContract({ address: nft, abi: erc721Abi, functionName: "safeTransferFrom", args: [seller.address, fulfiller, tokenId, listData(listing)] });
await test.waitForTransactionReceipt({ hash: depositHash });
assert.equal((await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] })).toLowerCase(), fulfiller.toLowerCase(), "escrowed");

// The keeper's production round reads this dev file in place of a live OpenSea call,
// in the real matchAdvancedOrders shape, and normalizes it like any OpenSea response.
writeFileSync(process.env.DEV_OFFERS_FILE!, JSON.stringify([{ nft, tokenId: tokenId.toString(), input: { orders: stringify(orders), criteriaResolvers: stringify(resolvers) } }]));

await round(); // sync + submit fillOffer
const fill = db().prepare("select * from attempts where kind = 'fill'").get() as any;
assert.ok(fill, "keeper submitted a fillOffer; see the log lines above");
const fillReceipt = await test.waitForTransactionReceipt({ hash: fill.tx });
assert.equal(fillReceipt.status, "success", "fillOffer reverted");
await round(); // record the sale

assert.equal((await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] })).toLowerCase(), bidder.toLowerCase(), "nft to bidder");
assert.equal(await bal(fulfiller), 0n, "Market holds no WETH");
const sale = db().prepare("select * from sales where listing_id is not null").get() as any;
assert.ok(sale, "sale indexed");
assert.equal(await bal(seller.address), BigInt(sale.proceeds), "seller paid its proceeds");
assert.equal(await bal(keeper.address), BigInt(sale.executor_fee), "keeper paid the executor fee");
assert.equal(await bal(protocol), BigInt(sale.protocol_fee), "protocol paid its fee");
assert.equal(BigInt(sale.proceeds) + BigInt(sale.protocol_fee) + BigInt(sale.executor_fee), available, "split sums to what the offer released");

// ---- Phase 2: native match (listing + bid) ----
const nftArtifact = JSON.parse(readFileSync(join(root, "out/Mocks.sol/MockNFT.json"), "utf8"));
const mockTx = await deployer.sendTransaction({ data: encodeDeployData({ abi: nftArtifact.abi, bytecode: nftArtifact.bytecode.object, args: [] }) });
const mock = (await test.waitForTransactionReceipt({ hash: mockTx })).contractAddress!;

const seller2 = privateKeyToAccount(generatePrivateKey());
const buyer2 = privateKeyToAccount(generatePrivateKey());
for (const a of [seller2.address, buyer2.address]) await test.setBalance({ address: a, value: 10n ** 18n });
const mintId = 1n;
await createWalletClient({ account: keeper, chain: mainnet, transport: http(rpc) }).writeContract({ address: mock, abi: parseAbi(["function mint(address,uint256)"]), functionName: "mint", args: [seller2.address, mintId] });

const price2 = 10n ** 16n; // 0.01 WETH per NFT
const now2 = (await test.getBlock()).timestamp;
const listing2: Listing = { seller: seller2.address, nft: mock, tokenId: mintId, currency: WETH, recipient: seller2.address, floor: price2 / 2n, expiry: Number(now2) + 86400, price: fixedPrice(price2 / 2n) };
const deposit2 = await createWalletClient({ account: seller2, chain: mainnet, transport: http(rpc) }).writeContract({ address: mock, abi: erc721Abi, functionName: "safeTransferFrom", args: [seller2.address, fulfiller, mintId, listData(listing2)] });
await test.waitForTransactionReceipt({ hash: deposit2 });

const bid2: Bid = { buyer: "0x0000000000000000000000000000000000000000", recipient: buyer2.address, nft: mock, minTokenId: 0n, maxTokenId: (1n << 256n) - 1n, currency: WETH, budget: price2, maxPrice: price2, quantity: 1, expiry: Number(now2) + 86400, price: fixedPrice(price2) };
const bidHash = await createWalletClient({ account: buyer2, chain: mainnet, transport: http(rpc) }).writeContract({ address: fulfiller, abi: marketAbi, functionName: "createBid", args: [bid2], value: price2 });
await test.waitForTransactionReceipt({ hash: bidHash });

await round(); // sync + submit matchBid
const match = db().prepare("select * from attempts where kind = 'match'").get() as any;
assert.ok(match, "keeper submitted a matchBid");
const matchReceipt = await test.waitForTransactionReceipt({ hash: match.tx });
assert.equal(matchReceipt.status, "success", "matchBid reverted");
await round();

assert.equal((await test.readContract({ address: mock, abi: erc721Abi, functionName: "ownerOf", args: [mintId] })).toLowerCase(), buyer2.address.toLowerCase(), "nft to bid recipient");
const matchSale = db().prepare("select * from sales where bid_id is not null").get() as any;
assert.ok(matchSale, "match sale indexed");
assert.equal(await bal(seller2.address), BigInt(matchSale.proceeds), "seller2 paid at the bid price");
assert.equal(await bal(keeper.address), BigInt(sale.executor_fee) + BigInt(matchSale.executor_fee), "keeper earned both executor fees");

console.log(
  JSON.stringify({
    ok: true,
    block: fixture.block - 1,
    fillOffer: { tx: fill.tx, gasUsed: fillReceipt.gasUsed.toString(), available: available.toString(), proceeds: sale.proceeds, executorFee: sale.executor_fee, protocolFee: sale.protocol_fee },
    matchBid: { tx: match.tx, gasUsed: matchReceipt.gasUsed.toString(), proceeds: matchSale.proceeds, executorFee: matchSale.executor_fee },
  }),
);
done();
process.exit(0);
