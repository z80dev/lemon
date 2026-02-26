#!/usr/bin/env python3
"""
Polymarket Event Scanner

Scans Polymarket for interesting trading opportunities:
- High volume markets
- Markets near resolution
- Markets with large price swings (24h)
- Potential arbitrage between correlated markets

Uses the public Polymarket Gamma API (no auth required).

Note: The public Gamma API returns historical/archived markets.
For live market data, you may need API key access or use the
CLOB API with proper authentication.

Usage:
    python polymarket_scanner.py

Output:
    - Console report with top opportunities
    - JSON files: polymarket_scan_YYYYMMDD_HHMMSS.json
                  polymarket_scan_latest.json
"""

import json
import sys
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from urllib.parse import urlencode


# Polymarket Gamma API endpoints
GAMMA_API_BASE = "https://gamma-api.polymarket.com"
MARKETS_ENDPOINT = f"{GAMMA_API_BASE}/markets"
EVENTS_ENDPOINT = f"{GAMMA_API_BASE}/events"


@dataclass
class Market:
    """Represents a Polymarket market."""
    id: str
    slug: str
    question: str
    description: str
    volume_24h: float = 0.0
    volume_total: float = 0.0
    liquidity: float = 0.0
    yes_price: float = 0.5
    no_price: float = 0.5
    spread: float = 0.0
    end_date: Optional[str] = None
    resolution_date: Optional[str] = None
    category: str = ""
    tags: list = field(default_factory=list)
    outcomes: list = field(default_factory=list)
    active: bool = True
    closed: bool = False
    created_at: Optional[str] = None
    
    @property
    def implied_probability(self) -> float:
        """Return the implied probability (yes price)."""
        return self.yes_price
    
    @property
    def days_to_resolution(self) -> Optional[float]:
        """Calculate days until resolution."""
        if not self.end_date:
            return None
        try:
            # Handle various date formats
            end = self._parse_date(self.end_date)
            if end:
                return (end - datetime.now()).total_seconds() / 86400
        except Exception:
            pass
        return None
    
    def _parse_date(self, date_str: str) -> Optional[datetime]:
        """Parse various date formats."""
        formats = [
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d",
        ]
        for fmt in formats:
            try:
                return datetime.strptime(date_str.replace("+00:00", "Z"), fmt)
            except ValueError:
                continue
        return None


@dataclass
class MarketOpportunity:
    """Represents a scored market opportunity."""
    market: Market
    score: float
    signals: list = field(default_factory=list)
    
    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "market": {
                "id": self.market.id,
                "slug": self.market.slug,
                "question": self.market.question,
                "description": self.market.description[:200] + "..." if len(self.market.description) > 200 else self.market.description,
                "volume_24h": self.market.volume_24h,
                "volume_total": self.market.volume_total,
                "liquidity": self.market.liquidity,
                "yes_price": self.market.yes_price,
                "no_price": self.market.no_price,
                "spread": self.market.spread,
                "implied_probability": self.market.implied_probability,
                "end_date": self.market.end_date,
                "days_to_resolution": self.market.days_to_resolution,
                "category": self.market.category,
            },
            "score": round(self.score, 2),
            "signals": self.signals,
        }


class PolymarketScanner:
    """Scanner for Polymarket trading opportunities."""
    
    def __init__(self):
        self.markets: list[Market] = []
    
    def _fetch_json(self, url: str) -> dict | list:
        """Fetch JSON from URL using standard library."""
        headers = {
            "User-Agent": "PolymarketScanner/1.0",
            "Accept": "application/json",
        }
        req = urllib.request.Request(url, headers=headers)
        
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                data = response.read().decode("utf-8")
                return json.loads(data)
        except urllib.error.HTTPError as e:
            print(f"HTTP Error: {e.code} - {e.reason}")
            raise
        except urllib.error.URLError as e:
            print(f"URL Error: {e.reason}")
            raise
        except json.JSONDecodeError as e:
            print(f"JSON Decode Error: {e}")
            raise
    
    def fetch_markets(
        self,
        limit: int = 100,
        active: bool = True,
        closed: bool = False,
    ) -> list[Market]:
        """
        Fetch markets from Polymarket Gamma API.
        
        Args:
            limit: Maximum number of markets to fetch
            active: Only fetch active markets
            closed: Include closed markets
        """
        # Build params - keep it simple to avoid 422 errors
        params = {"limit": limit}
        if active and not closed:
            params["active"] = "true"
        if closed:
            params["closed"] = "true"
        
        url = f"{MARKETS_ENDPOINT}?{urlencode(params)}"
        print(f"Fetching markets from: {url}")
        
        try:
            data = self._fetch_json(url)
            
            # API returns a list directly
            if isinstance(data, list):
                markets_data = data
            elif isinstance(data, dict):
                markets_data = data.get("markets", [])
            else:
                markets_data = []
            
            self.markets = []
            for m in markets_data:
                if isinstance(m, dict):
                    parsed = self._parse_market(m)
                    if parsed:
                        self.markets.append(parsed)
            
            # Sort by total volume descending (since many markets have 0 24h volume)
            self.markets.sort(key=lambda x: x.volume_total, reverse=True)
            
            print(f"Fetched {len(self.markets)} markets")
            return self.markets
            
        except Exception as e:
            print(f"Error fetching markets: {e}")
            return []
    
    def _parse_market(self, data: dict) -> Optional[Market]:
        """Parse a market from API response."""
        try:
            # Parse outcomes from JSON string if needed
            outcomes_raw = data.get("outcomes", "[]")
            if isinstance(outcomes_raw, str):
                try:
                    outcomes = json.loads(outcomes_raw)
                except json.JSONDecodeError:
                    outcomes = []
            else:
                outcomes = outcomes_raw
            
            # Parse outcome prices from JSON string if needed
            outcome_prices_raw = data.get("outcomePrices", "[]")
            if isinstance(outcome_prices_raw, str):
                try:
                    outcome_prices = json.loads(outcome_prices_raw)
                except json.JSONDecodeError:
                    outcome_prices = []
            else:
                outcome_prices = outcome_prices_raw
            
            yes_price = 0.5
            no_price = 0.5
            
            # Extract prices from outcomePrices array
            if outcomes and outcome_prices and len(outcomes) == len(outcome_prices):
                for i, outcome in enumerate(outcomes):
                    if outcome.lower() == "yes" and i < len(outcome_prices):
                        yes_price = float(outcome_prices[i])
                    elif outcome.lower() == "no" and i < len(outcome_prices):
                        no_price = float(outcome_prices[i])
            else:
                # Fallback to direct price fields
                yes_price = float(data.get("yesPrice", data.get("yes_price", 0.5)))
                no_price = float(data.get("noPrice", data.get("no_price", 0.5)))
            
            # Calculate spread
            spread = abs(yes_price + no_price - 1.0)
            
            return Market(
                id=str(data.get("id", "")),
                slug=data.get("slug", ""),
                question=data.get("question", data.get("title", "Unknown")),
                description=data.get("description", ""),
                volume_24h=float(data.get("volume24hr", data.get("volume_24h", 0))),
                volume_total=float(data.get("volume", data.get("volume_total", 0))),
                liquidity=float(data.get("liquidity", 0)),
                yes_price=yes_price,
                no_price=no_price,
                spread=spread,
                end_date=data.get("endDate", data.get("end_date")),
                resolution_date=data.get("resolutionDate", data.get("resolution_date")),
                category=data.get("category", ""),
                tags=data.get("tags", []),
                outcomes=outcomes,
                active=data.get("active", True),
                closed=data.get("closed", False),
                created_at=data.get("createdAt", data.get("created_at")),
            )
        except (KeyError, ValueError, TypeError) as e:
            print(f"Error parsing market: {e}")
            return None
    
    def find_high_volume_markets(self, min_volume_total: float = 50000) -> list[MarketOpportunity]:
        """Find markets with high total volume."""
        opportunities = []
        
        for market in self.markets:
            if market.volume_total >= min_volume_total:
                # Score based on total volume
                score = min(100, (market.volume_total / 1000000) * 10)  # 1M = 10 points
                signals = [f"High total volume: ${market.volume_total:,.0f}"]
                
                # Add 24h volume if available
                if market.volume_24h > 0:
                    signals.append(f"24h volume: ${market.volume_24h:,.0f}")
                    score += min(20, (market.volume_24h / 100000))
                
                # Bonus for high liquidity relative to volume
                if market.liquidity > 0:
                    liq_ratio = market.volume_total / market.liquidity
                    if liq_ratio > 5:
                        score += 5
                        signals.append(f"High turnover ratio: {liq_ratio:.1f}x")
                
                opportunities.append(MarketOpportunity(market, score, signals))
        
        return sorted(opportunities, key=lambda x: x.score, reverse=True)
    
    def find_near_resolution_markets(self, days_threshold: int = 7) -> list[MarketOpportunity]:
        """Find markets that are close to resolution."""
        opportunities = []
        
        for market in self.markets:
            days = market.days_to_resolution
            if days is not None and 0 <= days <= days_threshold:
                # Score based on proximity to resolution
                score = (days_threshold - days) / days_threshold * 50  # Max 50 points
                signals = [f"Resolves in {days:.1f} days"]
                
                # Bonus for high volume near resolution
                if market.volume_24h > 50000:
                    score += 10
                    signals.append("Active trading near resolution")
                
                # Bonus for price uncertainty (near 0.5)
                if 0.3 <= market.yes_price <= 0.7:
                    score += 15
                    signals.append(f"Uncertain outcome (price: {market.yes_price:.2f})")
                
                opportunities.append(MarketOpportunity(market, score, signals))
        
        return sorted(opportunities, key=lambda x: x.score, reverse=True)
    
    def find_price_swings(self, swing_threshold: float = 0.15) -> list[MarketOpportunity]:
        """
        Find markets with large price swings.
        
        Note: This uses spread as a proxy for volatility since historical
        price data isn't available in the basic endpoint.
        """
        opportunities = []
        
        for market in self.markets:
            signals = []
            score = 0.0
            
            # Large bid-ask spread indicates volatility/uncertainty
            if market.spread > 0.05:
                score += market.spread * 100  # 0.1 spread = 10 points
                signals.append(f"Wide spread: {market.spread:.3f}")
            
            # Price far from 0.5 with high volume suggests strong conviction
            price_deviation = abs(market.yes_price - 0.5)
            if price_deviation > 0.3 and market.volume_24h > 100000:
                score += price_deviation * 50
                signals.append(f"Strong directional conviction: {market.yes_price:.2f}")
            
            # High volume with price in middle range (information uncertainty)
            if 0.4 <= market.yes_price <= 0.6 and market.volume_24h > 200000:
                score += 20
                signals.append("High volume on uncertain outcome")
            
            if signals:
                opportunities.append(MarketOpportunity(market, score, signals))
        
        return sorted(opportunities, key=lambda x: x.score, reverse=True)
    
    def find_arbitrage_opportunities(self) -> list[MarketOpportunity]:
        """
        Find potential arbitrage between correlated markets.
        
        Looks for:
        - Markets with similar questions but different prices
        - Markets that should be inverses but aren't
        """
        opportunities = []
        
        # Group markets by category for correlation analysis
        by_category: dict[str, list[Market]] = {}
        for market in self.markets:
            cat = market.category or "Uncategorized"
            by_category.setdefault(cat, []).append(market)
        
        # Look for similar markets in same category
        for category, markets in by_category.items():
            if len(markets) < 2:
                continue
            
            # Compare pairs of markets
            for i, m1 in enumerate(markets):
                for m2 in markets[i+1:]:
                    # Skip if prices are too different (not correlated)
                    price_diff = abs(m1.yes_price - m2.yes_price)
                    
                    # Look for similar questions with divergent prices
                    if self._questions_similar(m1.question, m2.question) and price_diff > 0.1:
                        score = price_diff * 50  # 0.2 diff = 10 points
                        signals = [
                            f"Similar markets with {price_diff:.1%} price divergence",
                            f"Market 1: {m1.yes_price:.2f}",
                            f"Market 2: {m2.yes_price:.2f}",
                        ]
                        opportunities.append(MarketOpportunity(m1, score, signals))
                    
                    # Look for potential inverse relationships
                    sum_prices = m1.yes_price + m2.yes_price
                    if 0.8 < sum_prices < 1.2 and price_diff > 0.15:
                        score = abs(1.0 - sum_prices) * 100
                        signals = [
                            f"Potential inverse correlation (sum={sum_prices:.2f})",
                            f"Price divergence: {price_diff:.1%}",
                        ]
                        opportunities.append(MarketOpportunity(m1, score, signals))
        
        return sorted(opportunities, key=lambda x: x.score, reverse=True)[:20]
    
    def _questions_similar(self, q1: str, q2: str) -> bool:
        """Check if two questions are similar (simple heuristic)."""
        # Normalize
        q1_lower = q1.lower()
        q2_lower = q2.lower()
        
        # Check for shared keywords
        keywords1 = set(q1_lower.split())
        keywords2 = set(q2_lower.split())
        
        # Remove common stop words
        stop_words = {"will", "the", "a", "an", "in", "on", "at", "by", "to", "of", "for", "?"}
        keywords1 -= stop_words
        keywords2 -= stop_words
        
        # Calculate overlap
        if not keywords1 or not keywords2:
            return False
        
        overlap = len(keywords1 & keywords2)
        total = len(keywords1 | keywords2)
        
        return overlap / total > 0.5 if total > 0 else False
    
    def generate_report(self) -> dict:
        """Generate a comprehensive scan report."""
        print("\n" + "="*60)
        print("POLYMARKET EVENT SCANNER REPORT")
        print("="*60)
        print(f"Generated: {datetime.now().isoformat()}")
        print(f"Markets analyzed: {len(self.markets)}")
        print("="*60)
        
        # Run all scans
        high_volume = self.find_high_volume_markets()
        near_resolution = self.find_near_resolution_markets()
        price_swings = self.find_price_swings()
        arbitrage = self.find_arbitrage_opportunities()
        
        report = {
            "generated_at": datetime.now().isoformat(),
            "markets_analyzed": len(self.markets),
            "high_volume_markets": [o.to_dict() for o in high_volume[:10]],
            "near_resolution_markets": [o.to_dict() for o in near_resolution[:10]],
            "price_swing_markets": [o.to_dict() for o in price_swings[:10]],
            "arbitrage_opportunities": [o.to_dict() for o in arbitrage[:10]],
            "top_opportunities": self._rank_all_opportunities(
                high_volume, near_resolution, price_swings, arbitrage
            ),
        }
        
        # Print summary
        self._print_summary(report)
        
        return report
    
    def _rank_all_opportunities(
        self,
        high_volume: list[MarketOpportunity],
        near_resolution: list[MarketOpportunity],
        price_swings: list[MarketOpportunity],
        arbitrage: list[MarketOpportunity],
    ) -> list[dict]:
        """Combine and rank all opportunities."""
        all_ops = []
        
        for op in high_volume:
            all_ops.append(("high_volume", op))
        for op in near_resolution:
            all_ops.append(("near_resolution", op))
        for op in price_swings:
            all_ops.append(("price_swings", op))
        for op in arbitrage:
            all_ops.append(("arbitrage", op))
        
        # Sort by score and deduplicate by market ID
        seen_ids = set()
        unique_ops = []
        for category, op in sorted(all_ops, key=lambda x: x[1].score, reverse=True):
            if op.market.id not in seen_ids:
                seen_ids.add(op.market.id)
                unique_ops.append({
                    "category": category,
                    **op.to_dict(),
                })
        
        return unique_ops[:20]
    
    def _print_summary(self, report: dict):
        """Print a human-readable summary."""
        print("\n📊 HIGH VOLUME MARKETS")
        print("-" * 40)
        for op in report["high_volume_markets"][:5]:
            m = op["market"]
            print(f"  • {m['question'][:60]}...")
            print(f"    Score: {op['score']} | Total Vol: ${m['volume_total']:,.0f} | Price: {m['yes_price']:.2f}")
            for sig in op["signals"][:2]:
                print(f"    → {sig}")
            print()
        
        print("\n⏰ NEAR RESOLUTION")
        print("-" * 40)
        for op in report["near_resolution_markets"][:5]:
            m = op["market"]
            days = m.get("days_to_resolution")
            days_str = f"{days:.1f}d" if days else "unknown"
            print(f"  • {m['question'][:60]}...")
            print(f"    Score: {op['score']} | Resolves: {days_str} | Price: {m['yes_price']:.2f}")
            for sig in op["signals"][:2]:
                print(f"    → {sig}")
            print()
        
        print("\n📈 PRICE ACTIVITY")
        print("-" * 40)
        for op in report["price_swing_markets"][:5]:
            m = op["market"]
            print(f"  • {m['question'][:60]}...")
            print(f"    Score: {op['score']} | Price: {m['yes_price']:.2f} | Spread: {m['spread']:.3f}")
            for sig in op["signals"][:2]:
                print(f"    → {sig}")
            print()
        
        print("\n🔄 ARBITRAGE OPPORTUNITIES")
        print("-" * 40)
        for op in report["arbitrage_opportunities"][:5]:
            m = op["market"]
            print(f"  • {m['question'][:60]}...")
            print(f"    Score: {op['score']} | Category: {m['category']}")
            for sig in op["signals"][:3]:
                print(f"    → {sig}")
            print()
        
        print("\n🏆 TOP OVERALL OPPORTUNITIES")
        print("-" * 40)
        for i, op in enumerate(report["top_opportunities"][:10], 1):
            m = op["market"]
            print(f"  {i}. [{op['category']}] Score: {op['score']}")
            print(f"     {m['question'][:70]}...")
            print(f"     Price: {m['yes_price']:.2f} | Vol24h: ${m['volume_24h']:,.0f}")
            print()
    
    def save_report(self, report: dict, filename: str = "polymarket_scan.json"):
        """Save the report to a JSON file."""
        with open(filename, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\n💾 Report saved to: {filename}")


def main():
    """Main entry point."""
    print("🎯 Polymarket Event Scanner")
    print("=" * 60)
    
    scanner = PolymarketScanner()
    
    # Fetch markets
    markets = scanner.fetch_markets(limit=200)
    
    if not markets:
        print("❌ No markets fetched. Exiting.")
        sys.exit(1)
    
    # Generate report
    report = scanner.generate_report()
    
    # Save to JSON
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"polymarket_scan_{timestamp}.json"
    scanner.save_report(report, filename)
    
    # Also save as latest
    scanner.save_report(report, "polymarket_scan_latest.json")
    
    print("\n✅ Scan complete!")


if __name__ == "__main__":
    main()
