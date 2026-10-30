// Live OpenSea fulfiller check on an anvil fork of the latest mainnet block.
// Market is deployed at a fresh address, a throwaway seller lists a real NFT, and
// the keeper's production path asks OpenSea for zone data naming that address,
// then simulates and submits the match. Nothing leaves the fork except API reads.
//   OPENSEA_API_KEY=... npm run live:fulfiller -- <nft> <tokenId>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTestClient, createWalletClient, encodeDeployData, http, parseAbi, publicActions, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const [nft, tokenIdArg] = process.argv.slice(2) as [Address, string];
assert.ok(nft && tokenIdArg, "usage: live.ts <nft> <tokenId>");
assert.ok(process.env.OPENSEA_API_KEY, "OPENSEA_API_KEY is required");
const tokenId = BigInt(tokenIdArg);

const root = new URL("../../", import.meta.url).pathname;
const PORT = 8612;
const rpc = `http://127.0.0.1:${PORT}`;
const dir = mkdtempSync(join(tmpdir(), "market-live-"));

const anvil = spawn("anvil", ["--fork-url", "https://mainnet.gateway.tenderly.co", "--port", String(PORT), "--silent"], { stdio: "inherit" });
process.on("exit", () => anvil.kill());
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
const forkBlock = await test.getBlockNumber();

// Deploy before importing lib/, which reads the Market address from env at import time.
const keeperKey = generatePrivateKey();
const keeper = privateKeyToAccount(keeperKey);
const seller = privateKeyToAccount(generatePrivateKey());
const protocol = privateKeyToAccount(generatePrivateKey()).address;
for (const a of [seller.address, keeper.address]) await test.setBalance({ address: a, value: 10n ** 18n });
const artifact = JSON.parse(readFileSync(join(root, "out/Market.sol/Market.json"), "utf8"));
const deployTx = await createWalletClient({ account: keeper, chain: mainnet, transport: http(rpc) }).sendTransaction({
  data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object, args: [protocol] }),
});
const market = (await test.waitForTransactionReceipt({ hash: deployTx })).contractAddress!;
Object.assign(process.env, {
  RPC_URL: rpc,
  NEXT_PUBLIC_MARKET_ADDRESS: market,
  DB_PATH: join(dir, "live.db"),
  KEEPER_PRIVATE_KEY: keeperKey,
  CONFIRMATIONS: "0",
  PROFIT_MARGIN: "0", // feasibility is measured in ECONOMICS.md; this checks the integration
  START_BLOCK: String(forkBlock),
});

const { WETH, OS_CONDUIT, buildListing, seaportDomain, orderTypes, seaportAbi, erc721Abi, matchSplit, toJson } = await import("../lib/order");
const { db } = await import("../lib/server");
const os = await import("../lib/opensea");
const { round } = await import("./run");
const { parseBid, released } = await import("./match");

// Move the NFT from its current holder to the throwaway seller.
const owner = await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] });
await test.impersonateAccount({ address: owner });
await test.setBalance({ address: owner, value: 10n ** 18n });
await createWalletClient({ account: owner, chain: mainnet, transport: http(rpc) }).writeContract({
  address: nft,
  abi: parseAbi(["function transferFrom(address,address,uint256)"]),
  functionName: "transferFrom",
  args: [owner, seller.address, tokenId],
});
await test.stopImpersonatingAccount({ address: owner });
await createWalletClient({ account: seller, chain: mainnet, transport: http(rpc) }).writeContract({
  address: nft,
  abi: erc721Abi,
  functionName: "setApprovalForAll",
  args: [OS_CONDUIT, true],
});

// Price the listing under the live best offer so a match is possible.
const best = await os.bestOffer(await os.collectionSlug(nft), tokenId.toString());
assert.ok(best, "no OpenSea offer for this NFT");
assert.ok(os.supported(best, nft), "best offer is not a supported WETH offer");
const now = (await test.getBlock()).timestamp;
const headline = released(parseBid({ ...best.protocol_data, signature: "0x", extraData: "0x" }), now);
assert.ok(headline, "offer releases nothing");
const listing = buildListing({
  seller: seller.address,
  nft,
  tokenId,
  start: (headline * 95n) / 100n,
  floor: (headline * 80n) / 100n,
  startTime: now - 3600n,
  endTime: now + 3600n,
  counter: 0n,
  salt: 1n,
});
const signature = await seller.signTypedData({ domain: seaportDomain, types: orderTypes, primaryType: "OrderComponents", message: listing });
const { POST } = await import("../src/app/api/listings/route");
const res = await POST(new Request("http://x/api/listings", { method: "POST", body: JSON.stringify({ components: JSON.parse(toJson(listing)), signature }) }));
assert.equal(res.status, 201, JSON.stringify(await res.json()));

// Round 1 fetches zone data for `market`, simulates and submits; round 2 records it.
await round();
const attempt = db().prepare("select * from attempts").get() as any;
assert.ok(attempt, "keeper did not submit; see the log lines above");
const receipt = await test.waitForTransactionReceipt({ hash: attempt.tx as Hex });
assert.equal(receipt.status, "success");
await round();

const wethBalance = (a: Address) =>
  test.readContract({ address: WETH, abi: parseAbi(["function balanceOf(address) view returns (uint256)"]), functionName: "balanceOf", args: [a] });
const newOwner = await test.readContract({ address: nft, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] });
assert.equal(newOwner.toLowerCase(), best.protocol_data.parameters.offerer.toLowerCase());
assert.equal(await wethBalance(market), 0n);
const got = { seller: await wethBalance(seller.address), executorFee: await wethBalance(keeper.address), protocolFee: await wethBalance(protocol) };
// The three payouts sum to what the signed offer released; the split must be exact.
assert.deepEqual(matchSplit(got.seller + got.executorFee + got.protocolFee), got);
const sale = db().prepare("select * from sales").get() as any;
assert.equal(BigInt(sale.seller_proceeds), got.seller);

console.log(
  JSON.stringify({
    ok: true,
    forkBlock: forkBlock.toString(),
    market,
    nft,
    tokenId: tokenId.toString(),
    offer: best.order_hash,
    tx: attempt.tx,
    gasUsed: receipt.gasUsed.toString(),
    headline: headline.toString(),
    ...Object.fromEntries(Object.entries(got).map(([k, v]) => [k, v.toString()])),
  }),
);
process.exit(0);
