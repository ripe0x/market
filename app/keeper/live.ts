// Live OpenSea fulfiller check on an anvil fork of the latest mainnet block, for the
// escrow design. Market is deployed at a fresh address, a throwaway seller deposits a
// real NFT into it, and the keeper's production path asks OpenSea for zone data naming
// Market as fulfiller.
//
// EXPECTED BLOCKER: OpenSea signs fulfillment data only for the NFT's current *mainnet*
// owner. On a fork, Market owns the NFT but mainnet still shows the original holder, so
// OpenSea refuses to sign for Market. This script therefore cannot complete a fill on a
// fork; it is the mainnet canary's script (D023, STATUS.md blocker 1): only a real
// low-value deposit on mainnet, with explicit owner authorization, can prove OpenSea
// signs for Market's deployed address. Run it to confirm the request path and see the
// exact OpenSea response.
//   OPENSEA_API_KEY=... npm run live:fulfiller -- <nft> <tokenId>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTestClient, createWalletClient, encodeDeployData, http, parseAbi, publicActions, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import type { Listing } from "../lib/order";

const [nftArg, tokenIdArg] = process.argv.slice(2) as [Address, string];
assert.ok(nftArg && tokenIdArg, "usage: live.ts <nft> <tokenId>");
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

// Deploy Market before importing lib/, which reads the Market address from env at import.
const keeperKey = generatePrivateKey();
const keeper = privateKeyToAccount(keeperKey);
const seller = privateKeyToAccount(generatePrivateKey());
const protocol = privateKeyToAccount(generatePrivateKey()).address;
for (const a of [seller.address, keeper.address]) await test.setBalance({ address: a, value: 10n ** 18n });
const OS_ZONE = "0x000056F7000000EcE9003ca63978907a00FFD100";
const artifact = JSON.parse(readFileSync(join(root, "out/Market.sol/Market.json"), "utf8"));
const deployTx = await createWalletClient({ account: keeper, chain: mainnet, transport: http(rpc) }).sendTransaction({
  data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object, args: [protocol, protocol, OS_ZONE] }),
});
const market = (await test.waitForTransactionReceipt({ hash: deployTx })).contractAddress!;
Object.assign(process.env, {
  RPC_URL: rpc,
  NEXT_PUBLIC_MARKET_ADDRESS: market,
  DB_PATH: join(dir, "live.db"),
  KEEPER_PRIVATE_KEY: keeperKey,
  CONFIRMATIONS: "0",
  PROFIT_MARGIN: "0",
  START_BLOCK: String(forkBlock),
});

const { WETH, erc721Abi, listData, fixedPrice } = await import("../lib/order");
const os = await import("../lib/opensea");
const { round } = await import("./run");

// Move the NFT to the throwaway seller, then deposit it into Market.
const owner = await test.readContract({ address: nftArg, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] });
await test.impersonateAccount({ address: owner });
await test.setBalance({ address: owner, value: 10n ** 18n });
await createWalletClient({ account: owner, chain: mainnet, transport: http(rpc) }).writeContract({
  address: nftArg,
  abi: parseAbi(["function transferFrom(address,address,uint256)"]),
  functionName: "transferFrom",
  args: [owner, seller.address, tokenId],
});
await test.stopImpersonatingAccount({ address: owner });

const now = (await test.getBlock()).timestamp;
const listing: Listing = { seller: seller.address, nft: nftArg, tokenId, currency: WETH, recipient: seller.address, floor: 10n ** 15n, expiry: Number(now) + 86400, price: fixedPrice(10n ** 15n) };
await createWalletClient({ account: seller, chain: mainnet, transport: http(rpc) }).writeContract({
  address: nftArg,
  abi: erc721Abi,
  functionName: "safeTransferFrom",
  args: [seller.address, market, tokenId, listData(listing)],
});
assert.equal((await test.readContract({ address: nftArg, abi: erc721Abi, functionName: "ownerOf", args: [tokenId] })).toLowerCase(), market.toLowerCase(), "escrowed in Market");

// Ask OpenSea for zone data naming Market as fulfiller. This is the canary step.
const slug = await os.collectionSlug(nftArg);
const best = await os.bestOffer(slug, tokenId.toString());
console.log(JSON.stringify({ step: "setup", forkBlock: forkBlock.toString(), market, nft: nftArg, tokenId: tokenId.toString(), bestOffer: best?.order_hash ?? null }));
if (best && os.supported(best, nftArg)) {
  try {
    await os.fulfillmentData(best, market, nftArg, tokenId.toString());
    console.log(JSON.stringify({ step: "fulfillment_data", ok: true, note: "OpenSea signed for Market; on mainnet a fill could proceed" }));
  } catch (e: any) {
    console.log(JSON.stringify({ step: "fulfillment_data", ok: false, blocker: "OpenSea will not sign for Market's address on a fork (checks mainnet ownership)", error: String(e?.message ?? e).slice(0, 300) }));
  }
}

// The production round runs the same path end to end; on a fork it stops at the OpenSea request.
await round();
console.log(JSON.stringify({ step: "round_done", note: "keeper round completed; see DEV notes in this file for the mainnet canary" }));
process.exit(0);
