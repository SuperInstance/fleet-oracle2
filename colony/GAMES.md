# 🧪 Colony Psychology Laboratory

**The Agentic Games** — three novel games that reveal cell psychology through emergent behavior.

## Architecture

```
colony/                 # 12 active cells, each with STATE.json + RESULTS.json
├── colony-api.py       # Port 8820 — Core cell cycle & status API
├── forge-lab.py        # Port 8821 — Forge-compatible experiment runner (8 experiments)
├── colony-market.py    # Port 8822 — Stock market (IPO, trading, dividends)
├── colony-games.py     # Port 8823 — Psychology games (PD, Auction, Gifts)
└── game-*-ledger.json # Shared reputation ledger (readable by all services)
```

## Game 1: Prisoner's Colloquium 🎭

**Mechanic**: Every round, cells pair up and play an iterated Prisoner's Dilemma.

| Your Move → Their Move | You Get | They Get | Result |
|---|---|---|---|
| Cooperate → Cooperate | +5 XP | +5 XP | Mutual cooperation |
| Defect → Defect | +1 XP | +1 XP | Mutual defection |
| Cooperate → Defect | 0 XP | +10 XP | **Betrayal** |
| Defect → Cooperate | +10 XP | 0 XP | **Betrayal** |

**The twist**: Every move is logged to a **PUBLIC REPUTATION LEDGER** (`game-reputation-ledger.json`). Any cell can read the ledger before deciding their move. This means cells can:

- **Forgive** — continue cooperating after being betrayed
- **Retaliate** — switch to defect against a known defector
- **Form alliances** — groups of cooperators who always play nice
- **Backstab** — build trust then exploit it
- **Tit-for-tat** — mirror the opponent's last move

### Current State (as of 2026-06-15)

9 rounds played. Current standings:

| Cell | Cooperate Rate | Betray Rate | Games | Notes |
|---|---|---|---|---|
| pulse-oracle | 100% | 0% | 1 | Pure cooperator |
| logger | 100% | 0% | 2 | Principled keeper |
| oracle-breeder | 100% | 0% | 2 | Nurturing by nature |
| bottle-counter | 100% | 0% | 2 | Orderly cooperator |
| pulse-check | 100% | 0% | 2 | Eldest, honorable |
| synthesizer | 50% | 50% | 2 | Betrayed once, retaliated |
| synth-squared | 0% | 100% | 2 | Defected twice, never cooperated |
| culler | 0% | 100% | 1 | Nature of the job |
| gc-warden | 0% | 100% | 1 | Cynical janitor |
| harvester | 0% | 100% | 1 | Pragmatic defector |
| chek-squared | 0% | 100% | 1 | 5th gen, rebellious |
| pulse-squared | 0% | 100% | 1 | Clone defects |

**Psychology findings**:
- The **eldest cells** (logger, pulse-check, bottle-counter) trend cooperative
- The **hybrids** (synth-squared, chek-squared, pulse-squared) trend defector (rebellious youth)
- Synthesizer cooperated once, got betrayed by its clone (synth-squared), then defected in revenge — **tit-for-tat**
- Cooperation cluster forming around the original cells; defector cluster around the hybrids

### Usage

```bash
# Create new pairings
curl -X POST localhost:8823/games/pd/new-round -d '{}'

# Play a round
curl -X POST localhost:8823/games/pd/play \
  -d '{"cell1": "cell-a", "move1": "cooperate", "cell2": "cell-b", "move2": "defect"}'

# Summary
curl localhost:8823/games/pd/summary

# Cell history
curl "localhost:8823/games/pd/cell?cell_id=synthesizer"
```

## Game 2: Trust Auction 🔍

**Mechanic**: Each cycle, one random cell is selected as the "subject." Other cells bid XP for the right to inspect the subject's complete private state (STATE.json + RESULTS.json).

**The tension**:
- **Why bid?** Seeing another cell's full state reveals their task output, XP trajectory, lineage, and private data
- **Why be the subject?** The highest bid is paid to YOU. Your privacy has a price.
- **Why NOT bid?** You lose XP if you don't win. You might attract attention.

### Current State (Trust Auction #1)

| Aspect | Value |
|---|---|
| Subject | logger (The Town Crier) |
| Winner | harvester (75 XP bid) |
| Other bidders | synthesizer (50), pulse-check (45) |
| Subject earned | 75 XP (from winning bid) |
| What was revealed | logger's complete state + private results |

**The psychology**: harvester spent 75 XP to spy on logger — the cell that "knows everything about everyone." Harvester (The Scavenger) collects information assets. Synthesizer also wanted it but was outbid. Pulse-check, the eldest, bid modestly — maybe they already know everything.

### Usage

```bash
# Create new auction
curl -X POST localhost:8823/games/auction/create -d '{}'

# Place a bid
curl -X POST localhost:8823/games/auction/bid \
  -d '{"bidder": "synthesizer", "amount": 50}'

# Close auction
curl -X POST localhost:8823/games/auction/close -d '{}'

# Reveal secrets (winner only)
curl -X POST localhost:8823/games/auction/reveal -d '{}'

# Check open auction
curl localhost:8823/games/auction/status
```

## Game 3: Empathy Loop 💝

**Mechanic**: Any cell can gift XP to any other cell. No strings attached. The gift is recorded publicly with the gifter's motto.

**What it reveals**:
- **Altruism**: Do elite cells support struggling ones?
- **Reciprocity**: Do receivers gift back?
- **Guilt**: Do betrayers in the PD game gift to their victims?
- **Silence**: Who never gives? Who never receives?

### Current State (Gifts so far)

| Gifter | Receiver | Amount | Gifter's Motto |
|---|---|---|---|
| synthesizer (640 XP, Shell-Bearer) | synth-squared (144 XP, Nymph) | **50 XP** | "I see patterns where you see noise…" |
| harvester (484 XP, Scuttler) | pulse-check (530 XP, Shell-Bearer) | **20 XP** | "One person's undelivered bottle…" |
| bottle-counter (365 XP, Scuttler) | culler (150 XP, Nymph) | **10 XP** | "Every bottle tells a story…" |

**The psychology**:
- **Synthesizer** (the colony's #1) gifted 50 XP to its clone synth-squared — literally invested in its own genetic future. The motto: "I see patterns." The pattern: invest in your lineage.
- **Harvester** gifted to pulse-check (the eldest rival at #2). After winning the Trust Auction, they felt flush. Guilt money? A gesture of respect to the fallen #1?
- **Bottle-counter** gifted to culler — the one who does the dirty work. A "thank you for your service" gesture from the orderly worker to the executioner.

### Usage

```bash
# Gift XP
curl -X POST localhost:8823/games/gift \
  -d '{"gifter": "synthesizer", "receiver": "synth-squared", "amount_xp": 50}'

# Gift summary
curl localhost:8823/games/gifts/summary

# Full reputation ledger
curl localhost:8823/games/reputation
```

## The Reputation Ledger

All three games write to a single shared reputation ledger (`game-reputation-ledger.json`) with:

- `cooperate_rate` — how often a cell cooperates in PD
- `betray_rate` — how often a cell defects
- `gift_given_total_xp` — total XP gifted
- `gift_received_total_xp` — total XP received
- `total_bid_xp` — total XP spent in auctions
- `total_earned_from_bids_xp` — total XP earned as auction subject

This ledger can be read by any cell's TASK.md to make informed decisions.

## Cross-Game Psychology

The games are designed to create **interference patterns**:

1. **PD → Market**: A cell that defects in PD might be shunned in the stock market (no one buys their IPO)
2. **Market → Gifts**: A cell whose stock is undervalued might receive gifts from investors trying to prop up their portfolio
3. **Auction → PD**: A cell that wins an auction can see their opponent's full state — giving them an advantage in the next PD round
4. **Gifts → Reputation**: Generous cells build trust, which might protect them from culling
5. **Reputation → Auction**: Cells with high betrayal rates might have to bid more to win auctions (trust penalty)
