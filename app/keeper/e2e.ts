// Keeper integration on an anvil mainnet fork with a real signed OpenSea item offer.
// The fork is pinned one block before the offer's real fill. Market's runtime code
// is placed at the fulfiller address OpenSea's zone signature names, so OpenSea's
// real zone and signer validate it. The keeper's production path then finds,
// simulates, submits and records the sale.
//   npm run e2e:keeper     (needs anvil and `forge build` output)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTestClient, createWalletClient, decodeFunctionData, http, parseAbi, publicActions, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const root = new URL("../../", import.meta.url).pathname;
const fixture = JSON.parse(readFileSync(join(root, "test/fixtures/item_offer.json"), "utf8"));
const PORT = 8611;
const rpc = `http://127.0.0.1:${PORT}`;
const fulfiller = fixture.from as Address;
const dir = mkdtempSync(join(tmpdir(), "market-e2e-"));

// Module-level config in lib/ reads env at import time.
const keeperKey = generatePrivateKey();
Object.assign(process.env, {
  RPC_URL: rpc,
  NEXT_PUBLIC_MARKET_ADDRESS: fulfiller,
  DB_PATH: join(dir, "e2e.db"),
  KEEPER_PRIVATE_KEY: keeperKey,
  DEV_OFFERS_FILE: join(dir, "offers.json"),
  CONFIRMATIONS: "0",
  PROFIT_MARGIN: "0", // this 0.06 WETH sale is below the default margin; tested separately
  START_BLOCK: String(fixture.block - 2),
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

const { WETH, SEAPORT, OS_CONDUIT, buildListing, seaportDomain, orderTypes, seaportAbi, erc721Abi, matchSplit, toJson } = await import("../lib/order");
const { db } = await import("../lib/server");
const { round } = await import("./run");
const { parseBid, released } = await import("./match");

const wethAbi = parseAbi(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)"]);
const { args } = decodeFunctionData({ abi: seaportAbi, data: fixture.input as Hex });
const bidJson = JSON.parse(JSON.stringify((args as any)[0][0], (_, v) => (typeof v === "bigint" ? v.toString() : v)));
const bid = parseBid(bidJson);
const nft = bid.parameters.consideration[0].token;
const tokenId = bid.parameters.consideration[0].identifierOrCriteria;

// Seller and keeper are throwaway in-memory accounts.
const seller = privateKeyToAccount(generatePrivateKey());
const keeper = privateKeyToAccount(keeperKey);
const protocol = privateKeyToAccount(generatePrivateKey()).address;
for (const a of [seller.address, keeper.address]) await test.setBalance({ address: a, value: 10n ** 18n });

// While the fulfiller is still an EOA: move its NFT to the seller, sweep its WETH, approve Seaport as Market's constructor does.
await test.impersonateAccount({ address: fulfiller });
await test.setBalance({ address: fulfiller, value: 10n ** 18n });
const asFulfiller = createWalletClient({ account: fulfiller, chain: mainnet, transport: http(rpc) });
await asFulfiller.writeContract({ address: nft, abi: parseAbi(["function transferFrom(address,address,uint256)"]), functionName: "transferFrom", args: [fulfiller, seller.address, tokenId] });
const stray = await test.readContract({ address: WETH, abi: wethAbi, functionName: "balanceOf", args: [fulfiller] });
if (stray) await asFulfiller.writeContract({ address: WETH, abi: wethAbi, functionName: "transfer", args: [protocol.replace(/.$/, "0") as Address, stray] });
await asFulfiller.writeContract({ address: WETH, abi: wethAbi, functionName: "approve", args: [SEAPORT, 2n ** 256n - 1n] });
await test.stopImpersonatingAccount({ address: fulfiller });

// Deploy Market (immutables are inlined in runtime code), then place that code at the fulfiller.
const artifact = JSON.parse(readFileSync(join(root, "out/Market.sol/Market.json"), "utf8"));
const deployer = createWalletClient({ account: keeper, chain: mainnet, transport: http(rpc) });
const { encodeDeployData } = await import("viem");
const deployTx = await deployer.sendTransaction({ data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object, args: [protocol] }) });
const deployed = (await test.waitForTransactionReceipt({ hash: deployTx })).contractAddress!;
await test.setCode({ address: fulfiller, bytecode: (await test.getCode({ address: deployed }))! });

// Seller approves the OpenSea conduit and signs a declining listing.
const sellerWallet = createWalletClient({ account: seller, chain: mainnet, transport: http(rpc) });
await sellerWallet.writeContract({ address: nft, abi: erc721Abi, functionName: "setApprovalForAll", args: [OS_CONDUIT, true] });
const now = (await test.getBlock()).timestamp;
const available = released(bid, now)!;
const listing = buildListing({
  seller: seller.address,
  nft,
  tokenId,
  start: (available * 12n) / 10n,
  floor: (available * 6n) / 10n,
  startTime: now - 86400n,
  endTime: now + 86400n,
  counter: await test.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getCounter", args: [seller.address] }),
  salt: 1n,
});
const signature = await seller.signTypedData({ domain: seaportDomain, types: orderTypes, primaryType: "OrderComponents", message: listing });
const hash = (await test.readContract({ address: SEAPORT, abi: seaportAbi, functionName: "getOrderHash", args: [listing] })).toLowerCase();
db().prepare("insert into listings values (?,?,?,?,?,?,?)").run(hash, seller.address.toLowerCase(), nft.toLowerCase(), tokenId.toString(), toJson(listing), signature, Date.now());
writeFileSync(process.env.DEV_OFFERS_FILE!, JSON.stringify([{ hash: "fixture", nft, tokenId: tokenId.toString(), order: bidJson }]));

// Round 1 submits; anvil automines. Round 2 records the receipt and the sale.
await round();
const attempt = db().prepare("select * from attempts").get() as any;
assert.ok(attempt, "keeper submitted");
const receipt = await test.waitForTransactionReceipt({ hash: attempt.tx });
assert.equal(receipt.status, "success");
await round();

const split = matchSplit(available);
const bal = (a: Address) => test.readContract({ address: WETH, abi: wethAbi, functionName: "balanceOf", args: [a] });
assert.equal(await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] }), bid.parameters.offerer);
assert.equal(await bal(seller.address), split.seller);
assert.equal(await bal(keeper.address), split.executorFee);
assert.equal(await bal(protocol), split.protocolFee);
assert.equal(await bal(fulfiller), 0n);
assert.equal((db().prepare("select status from attempts").get() as any).status, "confirmed");
const sale = db().prepare("select * from sales").get() as any;
assert.equal(sale.hash, hash);
assert.equal(BigInt(sale.seller_proceeds), split.seller);

console.log(JSON.stringify({ ok: true, block: fixture.block - 1, tx: attempt.tx, gasUsed: receipt.gasUsed.toString(), available: available.toString(), ...Object.fromEntries(Object.entries(split).map(([k, v]) => [k, v.toString()])) }));
done();
process.exit(0);
