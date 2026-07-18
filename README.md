# D17 Contracts

![D17 contracts: read it, build it, verify it](./d17-contracts.png)

Solidity source for the D17 factory suite and the contracts created for each
launch. The suite uses Solidity 0.8.24, IR compilation, optimizer runs 1, the
Shanghai EVM target and no metadata bytecode hash.

## Contract set

- `D17Factory`
- `D17TokenFactory`
- `D17LiquidityVaultFactory`
- `D17LaunchFactory`
- `D17LockerFactory`
- `D17Token`
- `D17Launch`
- `D17Locker`
- `D17LiquidityVault`

Interfaces and the transfer helper are under `contracts/interfaces` and
`contracts/lib`.

## Read the system

- [Architecture](./docs/ARCHITECTURE.md)
- [ABI traceability](./docs/ABI_TRACEABILITY.md)
- [Testing](./docs/TESTING.md)
- [Interactive contract explorer](./docs/contract-explorer.html)
- [Security policy](./SECURITY.md)

## Compile and test

Use Node.js 22.13 LTS or Node.js 24+:

```bash
npm ci
npm run compile
npm test
npm run build:abi
npm run check:explorer
```

The local end-to-end suite covers factory wiring, metadata, configuration
bounds, failed launches, all five rounds, refunds, finalization, settlement,
pool creation, late liquidity top-ups, price divergence, token conservation and
adversarial reverts.

## Public deployments

`deployments/sepolia.json` and `deployments/mainnet.json` contain the public
factory addresses, WETH/router addresses and deployment start blocks. The D17
factory addresses are the same on both networks; WETH and router addresses are
network-specific.

Individual launches are created through `D17Factory.createLaunch`. This
repository does not contain a sample mainnet launch or any deployment key.

## Deploying another factory suite

Copy the appropriate example to the `.env` file read by the deployment scripts:

```bash
# Sepolia
cp .env.example .env

# Or Ethereum mainnet
cp .env.mainnet.example .env
```

Supply an RPC endpoint and locally funded deployment wallets in `.env`, inspect
the scripts, then run:

```bash
npm run deploy:factory
npm run verify:factory
```

Mainnet deployment requires the explicit script confirmation. Pin every
component before renouncing factory ownership. Once ownership is renounced,
the recovery path for an incorrect immutable deployment is a new deployment.

## Creating a launch

The applications call `createLaunch` through a browser wallet. Developers who
prefer a local command-line signer can use `npm run create:launch` after
reviewing the script and configuration.

Never commit a private key, seed phrase, populated `.env`, generated wallet
file or deployment credential.



# Anatomy of a Fair Launch: How D17's Contracts Work

*A technical walkthrough of the D17 V14.1 launch suite — the custody model, the five-round
price discovery, the pool that can't be held hostage, and the engineering fights along the
way. Solidity literacy helps but isn't required. All code shown is from the checksummed
V14.1 source; citations are `File.sol:line`.*

---

Token launches fail people in boring, predictable ways. The team keeps a mint key. The
"locked" liquidity has an owner withdraw function. An admin can change the rules after you
deposit. The frontend shows one price and the contract charges another. Or — subtler — the
system works perfectly and still traps you, because some mechanism lets one participant
stall everyone else.

D17 is a hobby-scale, testnet-first launch protocol built around a single idea: **every
promise the launch page makes should be a structural property of the bytecode, not a
policy of the operator.** No admin keys survive deployment. Your money sits in a contract
*you* own — refundable on the published schedule, and otherwise spent only on exactly the
terms you signed up for. And no other participant — lazy, confused, or malicious — can
freeze your outcome.

This post walks through how that actually works in the V14.1 contracts: the architecture,
the math, and three design problems whose solutions are more interesting than the feature
list suggests.

## The cast, and the deployment ritual

Five suite contracts get deployed once per chain:

```text
D17Factory ─────────── entry point, config validation, canonical registry
 ├─ D17LaunchFactory ── deploys one (token, launch, vault) trio per launch
 │    ├─ D17TokenFactory
 │    └─ D17LiquidityVaultFactory
 └─ D17LockerFactory ── deploys a D17Locker for each user (as many as they want)
```

And two kinds of per-instance contracts: each **launch** gets a `D17Token` (the ERC-20),
a `D17Launch` (the state machine), and a `D17LiquidityVault` (which will own the pool);
each **user** gets one or more `D17Locker`s — personal escrow contracts, deployable only
by their own owner (`createLockerFor` reverts unless `msg.sender == lockerOwner`,
D17LockerFactory.sol:24).

The suite is wired with one-shot "pins." Three of the contracts are ownable at deploy
time — `D17Factory`, `D17TokenFactory`, and `D17LiquidityVaultFactory` — and each gets
its factory wiring pinned exactly once, then has its ownership renounced (D17Factory.sol:104-133;
D17TokenFactory.sol:28-41; D17LiquidityVaultFactory.sol:28-41). After that ritual,
**no privileged function survives anywhere in the suite**. There is no upgrade path, no
pause switch, no parameter admin. If the deployment is wrong, the recovery is a new
deployment.

Creating a launch is a single transaction that performs its own authority destruction.
`D17Factory.createLaunch(config)` validates everything (more below), then
`D17LaunchFactory.deployLaunch` runs an eleven-step sequence (D17LaunchFactory.sol:71-133):
deploy the token, deploy the launch, deploy the vault, wire them together, then mint the
entire fixed supply in one breath —

- sale + LP allocation → the launch contract,
- the manual/deployer allocation → the creator's wallet,
- the dead allocation → `0x…dEaD`,

— and immediately call `closeMinting()` and `renounceOwnership()` on the token
(D17LaunchFactory.sol:128-132). The token leaves its deployment transaction with a closed
mint, no owner, and a total supply that can only ever go down (burns). The reference
tokenomics: 100M supply split 25% sale / 10% LP / 10% manual / 55% dead, and the factory
enforces the split *exactly*: `saleTokens + lpTokens + manualDistributionTokens +
deadTokens == tokenSupply` (D17Factory.sol:185-189), with the manual allocation capped at
10% of supply (:190-193) and its recipient hardwired to whoever called `createLaunch` —
there is deliberately no recipient field to phish.

## Your money stays yours: the locker model

Here is the design decision everything else bends around: **committed funds never pool in
a protocol contract before the sale completes.** When you join a round, your ETH is
wrapped to WETH and held *in your own locker* (D17Locker.sol:136-137). The launch contract
only does bookkeeping — it records that your locker committed X to round N. The launch's
WETH balance stays zero through the entire sale.

Two consequences worth savoring:

**First, there are no token approvals — ever.** Commits are plain payable calls through
your locker. D17 never asks you to `approve` anything, which deletes the single most
abused primitive in DeFi phishing. If anything claiming to be D17 requests an approval or
a signature, it's fake, categorically.

**Second, a malicious frontend can't change your terms.** Every locker call takes the
launch address *and* a `rulesHash` — a keccak over 25 fields covering every parameter that
defines the launch: round timings, fees, penalties, allocations, the version ID, the
metadata hash (D17Launch.sol:254-282). Before moving a wei, the locker independently
verifies four things (D17Locker.sol:94-102):

```solidity
require(candidate.D17_LAUNCH_ID() == EXPECTED_LAUNCH_ID, "BAD_LAUNCH_ID");
require(candidate.weth() == weth, "BAD_WETH");
require(candidate.rulesHash() == expectedRulesHash, "BAD_RULES");
require(ID17FactoryView(factory).isCanonicalLaunch(launch, expectedRulesHash), "NOT_CANONICAL");
```

A UI can lie on screen, but the transaction reverts unless the terms it claimed are the
terms on chain, registered in the canonical factory, from the exact contract version your
locker was built for. Your locker stores the hash at first commit, and even the
permissionless assisted-settlement path re-verifies against *your stored hash* — nobody
can settle you against terms you didn't pin.

The honest fine print: this protects you from *switched* terms, not from *bad* terms.
Launch creation is permissionless, so a real, canonical launch with a 50% refund penalty
and a scammy name can exist. The hash guarantees you get exactly what you signed up for —
reading what you sign up for is still on you (and on every UI to display it faithfully).

## Five rounds of price discovery

A launch runs five commitment rounds (contract rounds 0–4, displayed as 1–5), each
followed — except the last — by a refund window.

**Round 1 discovers the anchor.** There's no preset price. Everyone who commits in round 0
shares that round's fixed token allocation pro-rata, which *defines* the anchor price
(a "wad" is an 18-decimal fixed-point number — `WAD == 1e18`):

```solidity
anchorPriceWad = roundRaised[0] * WAD / roundBaseTokenAllocation(0);   // D17Launch.sol:337-341
```

The anchor keeps floating through round 0's own refund window — a refund decrements
`roundRaised[0]`, so an early exit nudges the discovered price for everyone still in
(D17Launch.sol:566). It's only fixed once that window closes.

If round 0 ends below the configured minimum raise (`minPhase1Weth`) or minimum price
(`minAnchorPriceWad`), the launch is simply dead. `launchFailed()` becomes true once
round 0's refund window elapses without a valid anchor (D17Launch.sol:347-349); every
commitment is then refundable in full with no penalty, forever, and trading never opens.
No partial launches, no "we'll make it work."

**Rounds 2–4 sell against anchor-derived targets.** Each round's WETH target is its token
allocation valued at the anchor price (:351-357). Raise exactly the target and the round
sells its full allocation at the anchor. Overfill is allowed — the round still sells only
its allocation, so latecomers push their own round's effective price *above* the anchor
(:367-379). Underfill means the unsold remainder **rolls forward into the final round**
(:381-387). Early conviction is rewarded with the floor price; hesitation competes for
the leftovers.

**Round 5 is the clearing auction.** Its pool — base allocation plus all rollover — sells
pro-rata to whatever WETH shows up, at whatever price that implies. There's no price floor
here: a thin final round clears *below* the anchor, so it's genuinely possible for
early-round buyers to pay more per token than round-5 buyers. That's the deal the design
makes on purpose — the floor price is a reward for round-0/1 conviction, not a guarantee
that later is worse. And round 5 has **no refund window**: the final round is a real
commitment.

The refund schedule across the windows is V14.1's headline fix, and it's a one-line policy
you can read directly:

```solidity
penaltyWeth = round < FREE_REFUND_ROUNDS ? 0 : gross * refundPenaltyBps / BPS;   // :574
```

Display rounds 1–2 refund free; rounds 3–4 charge the launch's configured penalty (capped
at 50%); round 5 is final. Early exploration is cheap, late defection costs, the clearing
round clears.

That one line has a history. Its predecessor — `round == 0 ? 0 : penalty`, charging the
penalty from display round 2 onward — shipped through two contract versions with a fully
green test suite, because the tests faithfully asserted the *wrong* policy. A passing suite
proves the code matches the tests; it says nothing about whether the tests match the
product. That's the kind of bug no amount of coverage catches, and the reason the review
process now reads test assertions against the spec, not just the pass count.

## Settlement: where the money actually goes

After the final round anyone — literally anyone — can call `finalizeLaunch()`. It
snapshots the total committed WETH, locks the final round's token pool, and disposes of
unsold sale tokens (burn or treasury, per config; D17Launch.sol:745-774). Then each locker
settles. Settlement is where your *committed* WETH converts (a penalized refund is the only
other time WETH leaves your locker, and that's your choice during a refund window):

```
gross         = everything your locker committed (post-refunds)
wethForVault  = gross * (10000 - treasuryBps) / 10000      → becomes pool liquidity
treasuryWeth  = gross - wethForVault                        → the fee (≤ 20%)
saleTokens    = your finalized pro-rata share               → to your locker
```

(D17Launch.sol:776-786.) Both the fee and any refund penalties go to a single `treasury`
address, chosen by the launch creator in the config and fixed forever in the rules hash —
so you can see exactly who's paid before you commit.

Your locker doesn't take the launch's word for the numbers, even though they were deployed
together. It rebuilds the expected sale-token total from the launch's own per-round preview
in the same transaction and requires the settlement to return exactly that
(`FINAL_CLAIM_MISMATCH`, D17Locker.sol:254) — a tripwire against a launch whose settlement
path disagrees with its own preview path. Separately, it checks the WETH being pulled
against its own stored commitment ledger and reverts if the launch tries to take more than
you put in (`LOCKED_WETH_BALANCE`, D17Locker.sol:255).

Tokens land in your locker, withdrawable once trading opens. You get a settlement grace
window to do this yourself — its length is the launch's configured `settlementSeconds`
(bounded at 30 days), running from finalization (D17Launch.sol:404-408). After it,
`settleAfterGrace` becomes permissionless, so anyone can complete your settlement *for* you
— your tokens still credit only your locker, only you can withdraw them, and there is **no
deadline, ever**. Missing a window in D17 never costs you what you bought.

## The pool nobody can hold hostage

Now the interesting part. The pool creation design went through five iterations, and the
graveyard explains the survivor.

**The incident.** V13.1 gated pool creation on `allFinalCommitmentsSettled()` — every
single locker had to settle before the pool could exist. On Sepolia, one participant
committed 0.25 WETH and walked away. Pool creation reverted `UNSETTLED_LOCKERS`. Trading
open, token withdrawals — everything downstream — froze for everyone until a third party
manually force-settled the straggler. One forgotten wallet had held an entire launch
hostage. That gate had to die.

But *how* it died matters, because the obvious replacements are all broken:

1. **Create the pool from settled funds; late settlers get tokens plus their pool-share
   WETH back?** Then settling late buys tokens for just the treasury fee — a ~99%
   discount. Every rational participant waits, and the pool starves. (This was actually
   the original research recommendation. It's an exploit with good manners.)
2. **Late pool-share WETH to the treasury?** Now the operator profits every time a user
   is late or confused — a standing incentive to make settlement UX worse. Rejected on
   principle.
3. **Burn it?** No user loses relative to on-time settlers, nobody gains — but the pool
   ends up permanently thinner than the sale implied, and the buyer's liquidity vanishes
   from the system. Rejected.
4. **Pull everyone's WETH into the launch at commit time and fund the pool in one shot?**
   Solves everything mechanically — and was rejected anyway, because pooled custody
   before completion breaks the product's core promise. The locker model is the point.

**The survivor: proportional funding plus a late top-up.** Pool creation itself is
permissionless — `createOfficialPool` can be called by anyone once the grace window opens
(D17LiquidityVault.sol:88), and the amounts come from launch accounting, not from the
caller, so a stranger triggering it can't skim anything (they only set their own slippage
and deadline bounds). At pool creation the launch pairs the WETH that *has* settled with a
*proportional slice* of the LP token allocation:

```solidity
liquidityTokens = lpTokens * settledLiquidityWeth / totalLiquidityWeth();   // :703
```

Divide through and you'll notice the reserve ratio is `lpTokens / totalLiquidityWeth` —
the **canonical launch ratio**, independent of how many people have settled. The pool
opens at the same price whether 60% or 99% of commitments are in. The unused LP tokens
stay reserved in the launch. When a late locker eventually settles — a day or a year
later — its settlement transaction atomically delivers its pool-share WETH *and* its
reserved token slice into the live pair at that same ratio:

```solidity
lateLpTokens = lpTokens * wethForVault / totalLiquidityWeth();              // :656
```

Same denominator, floor division everywhere, so the released tokens can never exceed the
allocation (there's a belt-and-braces `LP_RESERVE_EXCEEDED` check at :657-660; in
practice the accounting closes to within a few wei of dust). The late settler's outcome is
*identical* to an on-time settler's — same tokens, same cost, same fee — and their
liquidity still reaches the official pool. Nobody waits for anyone. Nothing is burned or
diverted. The LP tokens minted from every deposit, initial and late, go to the vault,
which has **no function that can move or burn them** — the pool is locked by the absence
of code, not by a timelock.

One honestly-disclosed wrinkle: a late top-up deposits at the launch ratio, but the pair
may have traded away from it. Uniswap V2 credits LP for the lesser leg and treats the
excess as a donation to the pool's constant product. Most of that donation accrues to the
vault's own locked position; a bounded slice is extractable by arbitrageurs — from the
*locked pool's* book value, never from any user's tokens or refunds. This was measured on
Sepolia against real Uniswap V2 at 5.6% and 20.5% price divergence: reserve deltas exact
to the wei, fees exact, all initial-pool records immutable. The mitigation is operational
and permissionless — anyone can sweep stragglers through `settleAfterGrace` right when the
grace opens, before prices drift.

## The gate on the token itself

Until the pool exists, the ERC-20 refuses to move for almost everyone
(D17Token.sol:231-241): transfers are allowed only *from the launch* (settlements, unsold
disposal) and *from the vault to the pair* (pool creation and top-ups). Everything else —
including the creator moving their own 10% manual allocation — reverts `TRADING_CLOSED`
until `tradingOpen()` flips, which happens at pool creation and nowhere else.

This is defense with three jobs. It stops the creator from seeding a rogue pool at a fake
price before the official one exists. It makes the vault's virgin-pair checks
(`PAIR_ALREADY_LIVE`, `PAIR_PRESEEDED_TOKEN`) unbreakable — an attacker can create the
pair early and even donate WETH into it, but can never get tokens to poison it with, and
donated WETH just ends up absorbed into the official pool's first mint. And since V14.1 it
extends to `burn`: pre-open burns are launch-only (`BURN_BEFORE_OPEN`, D17Token.sol:187),
closing a hole where the creator could quietly shrink the advertised supply before the
launch outcome was known. The unsold-token burn at finalization still works — it's the
launch calling — and after trading opens, any holder can burn freely.

Worth being explicit about the flip side: the gate is a *timing* control, not a vest. The
instant the pool is created, the creator's 10% allocation is fully liquid — there's no
lock-up or schedule on it. The protection is that it can't move until the launch outcome is
real and the official pool is the reference price; what the creator does with it after that
is visible on-chain and up to buyers to price in.

## Engineering in 24,576 bytes

One war story before we wind down, because it shaped everything above. `D17LaunchFactory`
deploys `D17Launch` with `new`, which means the launch's entire creation bytecode lives
*inside* the factory's code. The EVM caps deployed code at 24,576 bytes (Spurious Dragon),
and V14.1's factory weighs in at **24,469 bytes — 107 bytes of headroom.** Every feature in
the late-settlement redesign was paid for in bytes: two convenience getters
(`unsettledCommittedWeth`, `reservedLpTokens`) were deleted and documented as "derive it
yourself from the public counters" (D17Launch.sol:430-433), an event was cut, duplicate
settlement logic was folded into one internal function with a `late` flag, and the
refund-schedule constant is `private` because a public getter costs ~50 bytes the contract
doesn't have — integrators key the schedule off the version ID instead. Constraints make
design honest: everything in the contract earned its bytes.

## What can go wrong, and what can't

The system absorbs most mistakes by reverting. Wrong round number? `ROUND_CLOSED`. Stale
terms hash? `BAD_RULES`. Called the launch instead of your locker? `NOT_D17_LOCKER`. Sent
ETH straight to a contract? It bounces — the three fund-holding contracts (launch, locker,
vault) reject bare ETH explicitly with `DIRECT_ETH_REJECTED` (D17Locker.sol:86-88), and the
rest simply aren't payable, so a stray transfer reverts either way. Double-settle,
double-refund, double-claim: guarded, guarded, guarded.

Three risks are real and worth stating as plainly in a blog post as in a security review:
creating your locker against a counterfeit factory (verify the suite addresses once —
after that, the contract layer defends the terms); joining a canonical-but-predatory
launch without reading its config (the hash pins terms; it doesn't rate them); and
fat-fingering the amount in the *final* round, where there is no refund window and the
purchase is real. Rounds 1–2 forgive amount mistakes for free; rounds 3–4 charge the
penalty; round 5 is a commitment.

## Verifying any of this

You don't have to take a blog post's word for it. Every contract carries a version
constant (`keccak256("D17_LAUNCH_V14_1_REFUND_SCHEDULE_BURN_GATE")` and friends), lockers
cross-reject any other version, and the version ID is the first input of every
`rulesHash` — so terms can't even collide across versions. The exact reviewed source
exists as a checksummed bundle — a SHA-256 per file plus a manifest digest, byte-identical
to the build tree, with a sign-off security review sitting alongside it, so anyone can
confirm the bytes they're reading are the bytes that were reviewed. The local end-to-end suite runs
493 assertions across a full adversarial lifecycle — a failed launch, an 18-locker sale,
refunds in every window, a pool created with deliberate stragglers, late top-ups before
and after price movement, and every double-claim and foreign-caller revert. The refund
schedule and burn gate were then re-proven live on Sepolia (zero penalty in display round
2, exactly 17% in round 3, `BURN_BEFORE_OPEN` from the creator's own wallet).

Current status, honestly: V14.1 is deployed and exercised on Sepolia; Ethereum mainnet
deployment is prepared but not performed; the review so far is internal — there is no
independent third-party audit yet. The hosted product is a testnet showcase, and that's
deliberate: the whole design philosophy is that you shouldn't have to trust the operator,
and that includes not trusting our timeline pressure.

*Source, tests, and documentation live in the D17 repository alongside the
`CONTRACTS_TECHNICAL.md` reference this post summarizes. If you read one file, read
`D17Locker.sol` — 323 lines that hold your money and trust no one, including us.*

