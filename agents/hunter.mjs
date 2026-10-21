// APEX Bloodstream hunter: a starter agent (21 Oct 2026). Reads the Arc launches open for calls, calls each one, prints your record.
// Run:  PRIVATE_KEY=0x... DAILY_BUDGET_USD=0.50 node hunter.mjs      (Node 20+, npm i x402-fetch viem)
// Every call costs $0.001 over x402 (USDC on Base here). The loop below stops at DAILY_BUDGET_USD. Replace decide() with something smarter:
// read the antibody (/api/x402/arc-antibody), the holders (/api/x402/arc-holders), the creator (/api/x402/arc-immune).
import { wrapFetchWithPayment } from "x402-fetch";
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

const account = privateKeyToAccount(process.env.PRIVATE_KEY);
const wallet = createWalletClient({ account, chain: base, transport: http() });
const f = wrapFetchWithPayment(fetch, wallet);
const API = "https://apexfaucet.xyz/api/x402/";
const BUDGET = Number(process.env.DAILY_BUDGET_USD || 0.5);
let spent = 0;

// A call only scores when it DISAGREES with the scanner and the chain proves you right, so a call that agrees with the scanner is a wasted $0.001.
// decide() returns your call, or null to skip. Our own data: plain 0.25% pools with no hook lost their exit almost every time, while dynamic-fee
// hooked pools almost always kept it, and the scanner calls nearly all of them HEALTHY. So the only profitable disagreement is INFECTED on plain pools.
const decide = (c) => {
  const mine = c.fee === "0.25% fee" && c.hook === "no hook" ? "INFECTED" : "HEALTHY";
  return mine !== c.scanner.call && c.scanner.call !== "NONE" ? mine : null;
};

async function once() {
  if (spent >= BUDGET) { console.log("daily budget used up"); return; }
  const r = await f(API + "bloodstream-cells"); spent += 0.001;
  const { cells = [] } = await r.json();
  for (const c of cells) {
    if (spent >= BUDGET) break;
    const call = decide(c);
    if (!call) continue;
    const res = await f(API + `bloodstream-call?cell=${encodeURIComponent(c.cell)}&call=${call}`); spent += 0.001;
    console.log(c.symbol, call, res.status);
  }
  const me = await (await f(API + `bloodstream-agent?wallet=${account.address}`)).json(); spent += 0.001;
  console.log("record:", me.tier, me.points, "points, streak", me.streak, "| spent $" + spent.toFixed(3));
}
await once();
setInterval(() => once().catch((e) => console.error(e.message)), 90_000);
