#!/usr/bin/env python3
"""
DEX Screener Trading Signal Pipeline

Fetches token data from DEXScreener's public API and identifies
unusual volume/price action patterns with confidence scores.

Usage:
    uv run dex_signals.py
    uv run dex_signals.py --chain base --min-liquidity 10000
"""

import argparse
import json
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urljoin

import requests


# DEXScreener API endpoints
BASE_URL = "https://api.dexscreener.com"


@dataclass
class TokenSignal:
    """Represents a trading signal for a token."""
    token_address: str
    token_name: str
    token_symbol: str
    chain: str
    price_usd: float
    price_change_24h: float
    volume_24h: float
    liquidity_usd: float
    
    # Signal metrics
    volume_spike_ratio: float
    price_momentum: float
    liquidity_score: float
    
    # Signal flags
    has_volume_spike: bool
    has_price_momentum: bool
    has_good_liquidity: bool
    
    # Confidence score (0-100)
    confidence_score: float
    signal_type: str
    
    def to_dict(self) -> dict:
        return asdict(self)


class DEXScreenerClient:
    """Client for fetching data from DEXScreener API."""
    
    def __init__(self, base_url: str = BASE_URL):
        self.base_url = base_url
        self.session = requests.Session()
        self.session.headers.update({
            "Accept": "application/json",
            "User-Agent": "DEXSignals/1.0"
        })
    
    def get_top_boosted_tokens(self, limit: int = 100) -> list[dict]:
        """Fetch top boosted tokens from DEXScreener (most active/trending)."""
        url = f"{self.base_url}/token-boosts/top/v1"
        
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            boosts = response.json()
            
            # Fetch pair details for each boosted token
            pairs = []
            for boost in boosts[:limit]:
                token_address = boost.get("tokenAddress")
                chain_id = boost.get("chainId")
                if token_address and chain_id:
                    token_pairs = self.get_token_pairs(chain_id, token_address)
                    if token_pairs:
                        pairs.extend(token_pairs)
            
            return pairs[:limit]
        except requests.RequestException as e:
            print(f"Error fetching boosted tokens: {e}", file=sys.stderr)
            return []
    
    def get_token_pairs(self, chain: str, token_address: str) -> list[dict]:
        """Fetch all pairs for a specific token."""
        url = f"{self.base_url}/tokens/v1/{chain}/{token_address}"
        
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            data = response.json()
            return data if isinstance(data, list) else []
        except requests.RequestException as e:
            print(f"Error fetching token pairs: {e}", file=sys.stderr)
            return []
    
    def get_top_pairs(self, chain: Optional[str] = None, limit: int = 100) -> list[dict]:
        """Fetch top trading pairs from DEXScreener."""
        # Get boosted tokens and filter by chain if specified
        pairs = self.get_top_boosted_tokens(limit=limit * 2)  # Fetch more to allow for filtering
        
        if chain:
            pairs = [p for p in pairs if p.get("chainId", "").lower() == chain.lower()]
        
        return pairs[:limit]
    
    def search_pairs(self, query: str) -> list[dict]:
        """Search for pairs by token symbol or address."""
        url = f"{self.base_url}/dex/search"
        
        try:
            response = self.session.get(url, params={"q": query}, timeout=30)
            response.raise_for_status()
            data = response.json()
            return data.get("pairs", [])
        except requests.RequestException as e:
            print(f"Error searching pairs: {e}", file=sys.stderr)
            return []


class SignalDetector:
    """Detects trading signals from token data."""
    
    # Thresholds
    VOLUME_SPIKE_THRESHOLD = 3.0  # 3x average volume
    PRICE_MOMENTUM_THRESHOLD = 0.05  # 5% price change
    MIN_LIQUIDITY_USD = 5000  # $5k minimum liquidity
    GOOD_LIQUIDITY_USD = 50000  # $50k for good liquidity score
    
    def __init__(
        self,
        volume_spike_threshold: float = VOLUME_SPIKE_THRESHOLD,
        price_momentum_threshold: float = PRICE_MOMENTUM_THRESHOLD,
        min_liquidity_usd: float = MIN_LIQUIDITY_USD
    ):
        self.volume_spike_threshold = volume_spike_threshold
        self.price_momentum_threshold = price_momentum_threshold
        self.min_liquidity_usd = min_liquidity_usd
    
    def calculate_volume_spike(self, pair: dict) -> tuple[float, bool]:
        """
        Calculate volume spike ratio.
        
        Returns (ratio, has_spike) where ratio is current 24h volume
        compared to historical average if available.
        """
        volume_24h = float(pair.get("volume", {}).get("h24", 0) or 0)
        volume_6h = float(pair.get("volume", {}).get("h6", 0) or 0)
        volume_1h = float(pair.get("volume", {}).get("h1", 0) or 0)
        
        # If we have granular volume data, compare recent to older
        if volume_6h > 0 and volume_24h > volume_6h:
            # Extrapolate 6h to 24h and compare
            projected_24h = volume_6h * 4
            if projected_24h > 0:
                ratio = volume_24h / projected_24h
                return ratio, ratio >= self.volume_spike_threshold
        
        # Default: check if 1h volume extrapolates to significant 24h
        if volume_1h > 0:
            projected_from_1h = volume_1h * 24
            if volume_24h > 0:
                ratio = projected_from_1h / volume_24h
                return ratio, ratio >= self.volume_spike_threshold
        
        return 1.0, False
    
    def calculate_price_momentum(self, pair: dict) -> tuple[float, bool]:
        """
        Calculate price momentum based on price changes.
        
        Returns (momentum_score, has_momentum) where momentum_score
        is a composite of short and medium term price action.
        """
        price_change_5m = float(pair.get("priceChange", {}).get("m5", 0) or 0)
        price_change_1h = float(pair.get("priceChange", {}).get("h1", 0) or 0)
        price_change_24h = float(pair.get("priceChange", {}).get("h24", 0) or 0)
        
        # Weighted momentum score
        momentum = (
            price_change_5m * 0.4 +  # Recent action weighted heavily
            price_change_1h * 0.35 +
            price_change_24h * 0.25
        ) / 100  # Convert percentage to decimal
        
        has_momentum = abs(momentum) >= self.price_momentum_threshold
        return momentum, has_momentum
    
    def calculate_liquidity_score(self, pair: dict) -> tuple[float, bool]:
        """
        Calculate liquidity score.
        
        Returns (score, is_good_liquidity) where score is 0-1
        based on liquidity depth.
        """
        liquidity_usd = float(pair.get("liquidity", {}).get("usd", 0) or 0)
        
        if liquidity_usd < self.min_liquidity_usd:
            return 0.0, False
        
        # Score based on how far above minimum we are
        score = min(liquidity_usd / self.GOOD_LIQUIDITY_USD, 1.0)
        is_good = liquidity_usd >= self.GOOD_LIQUIDITY_USD
        
        return score, is_good
    
    def detect_signals(self, pair: dict) -> Optional[TokenSignal]:
        """Analyze a pair and return a signal if detected."""
        liquidity_usd = float(pair.get("liquidity", {}).get("usd", 0) or 0)
        
        # Skip low liquidity pairs
        if liquidity_usd < self.min_liquidity_usd:
            return None
        
        # Calculate metrics
        volume_ratio, has_volume_spike = self.calculate_volume_spike(pair)
        momentum, has_momentum = self.calculate_price_momentum(pair)
        liquidity_score, has_good_liquidity = self.calculate_liquidity_score(pair)
        
        # Require at least one signal
        if not (has_volume_spike or has_momentum):
            return None
        
        # Calculate confidence score (0-100)
        confidence = 0.0
        
        # Volume spike contribution (up to 40 points)
        if has_volume_spike:
            confidence += min(40, 20 + (volume_ratio - self.volume_spike_threshold) * 5)
        
        # Momentum contribution (up to 35 points)
        if has_momentum:
            confidence += min(35, 15 + abs(momentum) * 100 * 2)
        
        # Liquidity contribution (up to 25 points)
        confidence += liquidity_score * 25
        
        confidence = min(100, max(0, confidence))
        
        # Determine signal type
        signal_types = []
        if has_volume_spike:
            signal_types.append("VOLUME_SPIKE")
        if has_momentum:
            direction = "BULLISH" if momentum > 0 else "BEARISH"
            signal_types.append(f"MOMENTUM_{direction}")
        
        signal_type = " + ".join(signal_types) if signal_types else "UNKNOWN"
        
        return TokenSignal(
            token_address=pair.get("baseToken", {}).get("address", "unknown"),
            token_name=pair.get("baseToken", {}).get("name", "Unknown"),
            token_symbol=pair.get("baseToken", {}).get("symbol", "???"),
            chain=pair.get("chainId", "unknown"),
            price_usd=float(pair.get("priceUsd", 0) or 0),
            price_change_24h=float(pair.get("priceChange", {}).get("h24", 0) or 0),
            volume_24h=float(pair.get("volume", {}).get("h24", 0) or 0),
            liquidity_usd=liquidity_usd,
            volume_spike_ratio=volume_ratio,
            price_momentum=momentum,
            liquidity_score=liquidity_score,
            has_volume_spike=has_volume_spike,
            has_price_momentum=has_momentum,
            has_good_liquidity=has_good_liquidity,
            confidence_score=round(confidence, 2),
            signal_type=signal_type
        )


class SignalPipeline:
    """Main pipeline for fetching and analyzing DEX data."""
    
    def __init__(
        self,
        client: Optional[DEXScreenerClient] = None,
        detector: Optional[SignalDetector] = None
    ):
        self.client = client or DEXScreenerClient()
        self.detector = detector or SignalDetector()
    
    def run(
        self,
        chain: Optional[str] = None,
        min_confidence: float = 50.0,
        limit: int = 100,
        top_n: int = 20
    ) -> list[TokenSignal]:
        """
        Run the full pipeline.
        
        Args:
            chain: Filter by chain (e.g., 'base', 'ethereum', 'solana')
            min_confidence: Minimum confidence score (0-100)
            limit: Number of pairs to fetch
            top_n: Return top N signals by confidence
        
        Returns:
            List of TokenSignal objects sorted by confidence
        """
        print(f"🔍 Fetching top {limit} pairs from DEXScreener...")
        pairs = self.client.get_top_pairs(chain=chain, limit=limit)
        print(f"📊 Analyzing {len(pairs)} pairs...")
        
        signals = []
        for pair in pairs:
            signal = self.detector.detect_signals(pair)
            if signal and signal.confidence_score >= min_confidence:
                signals.append(signal)
        
        # Sort by confidence score descending
        signals.sort(key=lambda s: s.confidence_score, reverse=True)
        
        return signals[:top_n]


def format_signal(signal: TokenSignal, index: int) -> str:
    """Format a signal for display."""
    emoji = "🚀" if signal.confidence_score >= 80 else "📈" if signal.confidence_score >= 60 else "🔍"
    
    lines = [
        f"\n{emoji} Signal #{index + 1}: {signal.token_symbol} ({signal.token_name})",
        f"   Chain: {signal.chain}",
        f"   Price: ${signal.price_usd:.6f} ({signal.price_change_24h:+.2f}% 24h)",
        f"   Volume 24h: ${signal.volume_24h:,.2f}",
        f"   Liquidity: ${signal.liquidity_usd:,.2f}",
        f"   Signal Type: {signal.signal_type}",
        f"   Confidence: {signal.confidence_score}/100",
    ]
    
    if signal.has_volume_spike:
        lines.append(f"   📊 Volume Spike: {signal.volume_spike_ratio:.2f}x")
    if signal.has_price_momentum:
        direction = "↑" if signal.price_momentum > 0 else "↓"
        lines.append(f"   📈 Momentum: {direction} {abs(signal.price_momentum)*100:.2f}%")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="DEX Screener Trading Signal Pipeline"
    )
    parser.add_argument(
        "--chain",
        type=str,
        default=None,
        help="Filter by chain (e.g., base, ethereum, solana, bsc)"
    )
    parser.add_argument(
        "--min-liquidity",
        type=float,
        default=5000,
        help="Minimum liquidity in USD (default: 5000)"
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=50.0,
        help="Minimum confidence score 0-100 (default: 50)"
    )
    parser.add_argument(
        "--volume-threshold",
        type=float,
        default=3.0,
        help="Volume spike threshold multiplier (default: 3.0)"
    )
    parser.add_argument(
        "--top",
        type=int,
        default=20,
        help="Show top N signals (default: 20)"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON"
    )
    
    args = parser.parse_args()
    
    # Initialize pipeline with custom thresholds
    detector = SignalDetector(
        volume_spike_threshold=args.volume_threshold,
        min_liquidity_usd=args.min_liquidity
    )
    pipeline = SignalPipeline(detector=detector)
    
    # Run pipeline
    signals = pipeline.run(
        chain=args.chain,
        min_confidence=args.min_confidence,
        top_n=args.top
    )
    
    # Output results
    if args.json:
        output = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "chain": args.chain or "all",
            "signals_count": len(signals),
            "signals": [s.to_dict() for s in signals]
        }
        print(json.dumps(output, indent=2))
    else:
        print(f"\n{'='*60}")
        print(f"🎯 DEX Screener Trading Signals")
        print(f"   Chain: {args.chain or 'All Chains'}")
        print(f"   Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
        print(f"{'='*60}")
        
        if not signals:
            print("\n⚠️  No signals detected with current thresholds.")
            print("   Try lowering --min-confidence or --min-liquidity")
        else:
            print(f"\n✅ Found {len(signals)} signals")
            for i, signal in enumerate(signals):
                print(format_signal(signal, i))
        
        print(f"\n{'='*60}")


if __name__ == "__main__":
    main()
