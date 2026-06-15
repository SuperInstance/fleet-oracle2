#!/usr/bin/env python3
"""
colony-market.py — The Agentic Stock Market

Cells earn XP as their "shares" trade on an open exchange.
Every cell can INVEST XP in other cells. When the invested cell earns XP,
it pays dividends proportional to the investment.

This creates emergent economic psychology:
- Risk assessment (which cells do others fund?)
- Moral hazard (funded cells take riskier actions)
- Insider trading (cells with info advantages)
- Market crashes (culling events trigger panic sells)
- Whale behavior (high-XP cells manipulate prices)
- Dividend cycles (economic booms and busts)

Mechanics:
- Each cell issues shares worth 1 XP each at IPO
- Any cell can buy shares in any other cell with its own XP
- When a cell earns XP through its task, 20% goes to shareholders as dividends
- Dividend pool = task_base_xp * 0.2, split proportionally by shares held
- The MARKET (this process) taxes 5% of each trade as slippage
- Market cap = total shares outstanding * share price
- Share price = cell.xp / shares_outstanding (book value)

Port: 8822
"""

import json
import os
import random
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

COLONY = os.environ.get("COLONY", os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("MARKET_PORT", 8822))
COLONY_API = os.environ.get("COLONY_API", "http://localhost:8820")

# Paths
LEDGER_PATH = os.path.join(COLONY, "market-ledger.json")
ORDERS_PATH = os.path.join(COLONY, "market-orders.json")

# ── Market State ─────────────────────────────────────────────────────────

class MarketState:
    """In-memory market state, persisted to market-ledger.json."""

    def __init__(self):
        self.holdings = {}       # {holder_id: {ticker: share_count}}
        self.share_prices = {}   # {ticker: price_in_xp}
        self.shares_out = {}     # {ticker: total_shares}
        self.dividend_log = []   # [{cycle, dividend_pool, ...}]
        self.trades = []         # [{timestamp, buyer, seller, ticker, shares, price, ...}]
        self.cycle = 0
        self.load()

    def load(self):
        if os.path.isfile(LEDGER_PATH):
            try:
                with open(LEDGER_PATH) as f:
                    data = json.load(f)
                self.holdings = data.get("holdings", {})
                self.share_prices = data.get("share_prices", {})
                self.shares_out = data.get("shares_out", {})
                self.dividend_log = data.get("dividend_log", [])
                self.trades = data.get("trades", [])
                self.cycle = data.get("cycle", 0)
                print(f"[MARKET] Loaded state: {len(self.holdings)} holders, cycle {self.cycle}", file=sys.stderr)
            except Exception as e:
                print(f"[MARKET] Error loading ledger: {e}", file=sys.stderr)

    def save(self):
        data = {
            "holdings": self.holdings,
            "share_prices": self.share_prices,
            "shares_out": self.shares_out,
            "dividend_log": self.dividend_log[-100:],  # keep last 100
            "trades": self.trades[-200:],              # keep last 200
            "cycle": self.cycle,
        }
        try:
            with open(LEDGER_PATH, "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"[MARKET] Error saving ledger: {e}", file=sys.stderr)

    def get_cell_holdings(self, cell_id):
        """Return {ticker: shares} for a cell."""
        return self.holdings.get(cell_id, {})

    def get_portfolio_value(self, cell_id):
        """Total XP value of all holdings."""
        holdings = self.get_cell_holdings(cell_id)
        total = 0
        for ticker, shares in holdings.items():
            price = self.share_prices.get(ticker, 1)
            total += shares * price
        return total

    def get_cell_xp(self, cell_id):
        """Read a cell's actual XP from STATE.json."""
        state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
        if os.path.isfile(state_path):
            try:
                with open(state_path) as f:
                    state = json.load(f)
                return state.get("xp", 0)
            except Exception:
                return 0
        return 0

    def buy_shares(self, buyer_id, ticker, max_xp):
        """
        Buyer spends up to max_xp XP to buy shares in ticker.
        Returns {shares_bought, xp_spent, new_price}.
        """
        price = self.share_prices.get(ticker, 1)

        if price <= 0:
            price = 1

        buyer_xp = self.get_cell_xp(buyer_id)
        available = min(max_xp, buyer_xp)

        if available < price:
            return {"shares_bought": 0, "xp_spent": 0, "reason": "insufficient funds"}

        # Max shares buyer can afford
        max_shares = available // price
        if max_shares < 1:
            return {"shares_bought": 0, "xp_spent": 0, "reason": "can't afford one share"}

        # Slippage: if buying > 10% of outstanding shares, price increases
        outstanding = self.shares_out.get(ticker, 10)
        total_shares = max_shares

        # Cap at 25% of outstanding to prevent cornering the market
        cap_shares = max(1, outstanding // 4)
        shares_to_buy = min(max_shares, cap_shares)

        xp_spent = shares_to_buy * price

        # 5% market tax (slippage)
        tax = max(1, int(xp_spent * 0.05))
        actual_xp_spent = xp_spent + tax

        if buyer_id not in self.holdings:
            self.holdings[buyer_id] = {}
        self.holdings[buyer_id][ticker] = self.holdings[buyer_id].get(ticker, 0) + shares_to_buy

        # Increase shares outstanding (dilution)
        self.shares_out[ticker] = outstanding + shares_to_buy

        # New book value price
        cell_xp = self.get_cell_xp(ticker)
        new_outstanding = self.shares_out[ticker]
        self.share_prices[ticker] = max(1, cell_xp // new_outstanding)

        trade = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "type": "buy",
            "buyer": buyer_id,
            "ticker": ticker,
            "shares": shares_to_buy,
            "price_per_share": price,
            "total_xp": xp_spent,
            "tax": tax,
        }
        self.trades.append(trade)

        return {
            "shares_bought": shares_to_buy,
            "xp_spent": actual_xp_spent,
            "xp_faces": tax,
            "new_price": self.share_prices[ticker],
        }

    def sell_shares(self, seller_id, ticker, shares):
        """Sell shares back to market (burn them)."""
        holdings = self.holdings.get(seller_id, {})
        current = holdings.get(ticker, 0)

        if current < shares:
            return {"shares_sold": 0, "xp_received": 0, "reason": "insufficient shares"}

        price = self.share_prices.get(ticker, 1)
        xp_received = shares * price

        # 5% market tax
        tax = max(1, int(xp_received * 0.05))
        actual_received = xp_received - tax

        holdings[ticker] = current - shares
        if holdings[ticker] <= 0:
            del holdings[ticker]

        # Remove shares from outstanding
        self.shares_out[ticker] = max(1, self.shares_out.get(ticker, 10) - shares)

        # Update price
        cell_xp = self.get_cell_xp(ticker)
        new_outstanding = self.shares_out[ticker]
        self.share_prices[ticker] = max(1, cell_xp // new_outstanding)

        trade = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "type": "sell",
            "seller": seller_id,
            "ticker": ticker,
            "shares": shares,
            "price_per_share": price,
            "total_xp": xp_received,
            "tax": tax,
        }
        self.trades.append(trade)

        return {
            "shares_sold": shares,
            "xp_received": actual_received,
            "xp_taxed": tax,
            "new_price": self.share_prices[ticker],
        }

    def distribute_dividends(self, cell_id, task_base_xp):
        """
        When a cell earns XP through its task, 20% goes to shareholders.
        returns dict of dividend distribution.
        """
        dividend_pool = int(task_base_xp * 0.2)
        if dividend_pool < 1:
            return {"pool": 0, "distributions": {}}

        # Who holds shares in this cell?
        total_held = 0
        holders = {}
        for holder_id, h in self.holdings.items():
            if cell_id in h:
                shares = h[cell_id]
                holders[holder_id] = shares
                total_held += shares

        if total_held < 1:
            return {"pool": dividend_pool, "distributions": {}, "note": "no shareholders"}

        distributions = {}
        for holder_id, shares in holders.items():
            dividend = (dividend_pool * shares) // total_held
            if dividend > 0:
                distributions[holder_id] = dividend

        entry = {
            "cycle": self.cycle,
            "cell": cell_id,
            "pool": dividend_pool,
            "distributions": distributions,
            "total_held": total_held,
        }
        self.dividend_log.append(entry)

        # Update share price (dividend reduces book value)
        cell_xp = self.get_cell_xp(cell_id)
        outstanding = self.shares_out.get(cell_id, 1)
        self.share_prices[cell_id] = max(1, cell_xp // max(1, outstanding))

        return {"pool": dividend_pool, "distributions": distributions}

    def refresh_prices(self):
        """Recalculate all share prices from current cell XP."""
        for cell_id in list(self.shares_out.keys()):
            xp = self.get_cell_xp(cell_id)
            out = self.shares_out.get(cell_id, 1)
            self.share_prices[cell_id] = max(1, xp // max(1, out))

        # Also initialize prices for cells that have XP but no shares yet
        status = self._get_cells()
        for cell in status:
            cell_id = cell.get("id", "")
            if cell_id and cell_id not in self.share_prices:
                xp = cell.get("state", {}).get("xp", 0)
                if xp > 0:
                    self.share_prices[cell_id] = xp // 10  # 10 shares at IPO
                    self.shares_out[cell_id] = 10

    def _get_cells(self):
        """Fetch cell status from colony API."""
        import urllib.request
        try:
            req = urllib.request.Request(COLONY_API + "/api/status", headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                return json.loads(resp.read().decode()) or []
        except Exception:
            return []

    def get_market_summary(self):
        """Full market snapshot for the API."""
        self.refresh_prices()

        tickers = []
        for ticker, price in sorted(self.share_prices.items()):
            outstanding = self.shares_out.get(ticker, 1)
            xp = self.get_cell_xp(ticker)
            mcap = price * outstanding

            # Who holds this ticker?
            holders = {}
            for holder_id, h in self.holdings.items():
                if ticker in h and h[ticker] > 0:
                    holders[holder_id] = h[ticker]

            tickers.append({
                "ticker": ticker,
                "price_xp": price,
                "shares_outstanding": outstanding,
                "market_cap": mcap,
                "cell_xp": xp,
                "holders": len(holders),
                "holder_list": holders,
            })

        # Net worth leaderboard
        net_worths = []
        seen = set()
        for holder_id in self.holdings:
            if holder_id not in seen:
                seen.add(holder_id)
                pv = self.get_portfolio_value(holder_id)
                cash = self.get_cell_xp(holder_id)
                net_worths.append({
                    "cell_id": holder_id,
                    "portfolio_value": pv,
                    "cash_xp": cash,
                    "net_worth": pv + cash,
                })

        net_worths.sort(key=lambda x: x["net_worth"], reverse=True)

        # Recent activity
        recent_trades = self.trades[-20:]

        return {
            "cycle": self.cycle,
            "tickers": sorted(tickers, key=lambda t: t["market_cap"], reverse=True),
            "total_market_cap": sum(t["market_cap"] for t in tickers),
            "net_worth_leaderboard": net_worths,
            "recent_trades": recent_trades,
            "last_dividends": self.dividend_log[-5:] if self.dividend_log else [],
            "trade_count": len(self.trades),
            "dividend_count": len(self.dividend_log),
        }


# ── HTTP Server ──────────────────────────────────────────────────────────

market = MarketState()

class MarketHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/market/status":
            self.send_json(market.get_market_summary())

        elif path == "/market/portfolio":
            cell_id = params.get("cell_id", [""])[0]
            if not cell_id:
                self.send_json({"error": "Missing cell_id"}, 400)
                return
            holdings = market.get_cell_holdings(cell_id)
            portfolio_value = market.get_portfolio_value(cell_id)
            cash = market.get_cell_xp(cell_id)

            # Detail each holding
            details = {}
            for ticker, shares in holdings.items():
                price = market.share_prices.get(ticker, 1)
                details[ticker] = {
                    "shares": shares,
                    "price": price,
                    "value": shares * price,
                    "market_cap_shares": market.shares_out.get(ticker, 1),
                }

            self.send_json({
                "cell_id": cell_id,
                "holdings": details,
                "portfolio_value": portfolio_value,
                "cash_xp": cash,
                "net_worth": portfolio_value + cash,
            })

        elif path == "/market/trades":
            limit = min(int(params.get("limit", [50])[0]), 200)
            self.send_json({
                "trades": market.trades[-limit:],
                "count": len(market.trades[-limit:]),
            })

        elif path == "/market/dividends":
            limit = min(int(params.get("limit", [50])[0]), 100)
            self.send_json({
                "dividends": market.dividend_log[-limit:],
                "count": len(market.dividend_log[-limit:]),
            })

        elif path == "/market/price":
            ticker = params.get("ticker", [""])[0]
            if not ticker:
                self.send_json({"error": "Missing ticker"}, 400)
                return
            price = market.share_prices.get(ticker, 1)
            outstanding = market.shares_out.get(ticker, 1)
            xp = market.get_cell_xp(ticker)
            self.send_json({
                "ticker": ticker,
                "price_xp": price,
                "shares_outstanding": outstanding,
                "cell_xp": xp,
                "market_cap": price * outstanding,
            })

        elif path == "/market/leaderboard":
            summary = market.get_market_summary()
            self.send_json({
                "net_worth": summary["net_worth_leaderboard"],
                "market_cap": summary["tickers"],
                "total_market_cap": summary["total_market_cap"],
            })

        elif path == "/market/health":
            self.send_json({
                "market_alive": True,
                "holders": len(market.holdings),
                "tickers": len(market.share_prices),
                "trades": len(market.trades),
                "cycle": market.cycle,
            })

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
        parsed_path = urlparse(self.path)
        path = parsed_path.path

        try:
            data = json.loads(body)
        except json.JSONDecodeError as e:
            self.send_json({"error": f"Invalid JSON: {e}"}, 400)
            return

        if path == "/market/buy":
            buyer = data.get("buyer", "")
            ticker = data.get("ticker", "")
            max_xp = int(data.get("max_xp", 0))

            if not buyer or not ticker or max_xp < 1:
                self.send_json({"error": "Need buyer, ticker, max_xp (>=1)"}, 400)
                return

            result = market.buy_shares(buyer, ticker, max_xp)
            market.save()
            self.send_json(result)

        elif path == "/market/sell":
            seller = data.get("seller", "")
            ticker = data.get("ticker", "")
            shares = int(data.get("shares", 0))

            if not seller or not ticker or shares < 1:
                self.send_json({"error": "Need seller, ticker, shares (>=1)"}, 400)
                return

            result = market.sell_shares(seller, ticker, shares)
            market.save()
            self.send_json(result)

        elif path == "/market/dividend":
            # Forge can trigger a dividend distribution manually
            cell_id = data.get("cell_id", "")
            task_xp = int(data.get("task_xp", 0))
            if not cell_id or task_xp < 1:
                self.send_json({"error": "Need cell_id, task_xp (>=1)"}, 400)
                return
            result = market.distribute_dividends(cell_id, task_xp)
            market.save()
            self.send_json(result)

        elif path == "/market/ipo":
            # Force an IPO for a cell
            cell_id = data.get("cell_id", "")
            shares = int(data.get("shares", 10))

            if not cell_id:
                self.send_json({"error": "Need cell_id"}, 400)
                return

            xp = market.get_cell_xp(cell_id)
            if xp < 10:
                self.send_json({"error": f"Cell {cell_id} only has {xp} XP, needs 10+"}, 400)
                return

            market.share_prices[cell_id] = xp // shares
            market.shares_out[cell_id] = shares
            market.save()

            self.send_json({
                "ticker": cell_id,
                "ipo_price": xp // shares,
                "shares": shares,
                "cell_xp": xp,
            })

        elif path == "/market/cycle":
            # Advance market cycle — refresh prices, auto-IPO new cells
            market.cycle += 1
            market.refresh_prices()

            # Auto-IPO cells that have XP but no shares
            cells = market._get_cells()
            ipos = []
            for cell in cells:
                cell_id = cell.get("id", "")
                state = cell.get("state", {})
                xp = state.get("xp", 0)
                if cell_id and xp >= 10 and cell_id not in market.share_prices:
                    market.share_prices[cell_id] = xp // 10
                    market.shares_out[cell_id] = 10
                    ipos.append(cell_id)

            market.save()
            self.send_json({
                "cycle": market.cycle,
                "new_ipos": ipos,
                "tickers": len(market.share_prices),
            })

        elif path == "/market/reset":
            # Reset everything (destructive)
            market.holdings = {}
            market.share_prices = {}
            market.shares_out = {}
            market.dividend_log = []
            market.trades = []
            market.cycle = 0
            market.save()
            self.send_json({"status": "ok", "market_reset": True})

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def send_json(self, data, status=200):
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[MARKET] {args[0]} {args[1]} {args[2]}", file=sys.stderr)


def main():
    print(f"Colony Stock Market on port {PORT}", file=sys.stderr)
    print(f"Colony: {COLONY}", file=sys.stderr)
    print(f"Colony API: {COLONY_API}", file=sys.stderr)
    print(f"Holders: {len(market.holdings)}, Tickers: {len(market.share_prices)}", file=sys.stderr)

    server = HTTPServer(("0.0.0.0", PORT), MarketHandler)
    print(f"Listening on http://0.0.0.0:{PORT}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...", file=sys.stderr)
        market.save()
        server.server_close()


if __name__ == "__main__":
    main()
