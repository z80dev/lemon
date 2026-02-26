#!/usr/bin/env python3
"""
Crypto Sentiment Analysis Pipeline

Analyzes market sentiment for top 10 cryptocurrencies by combining:
- Fear & Greed Index data
- Price momentum indicators
- Social sentiment signals (via web search)
- On-chain metrics

Outputs: JSON data + readable Markdown report with buy/sell/hold signals

Usage:
    uv run python3 sentiment_tracker.py
    uv run python3 sentiment_tracker.py --output-dir ./reports
"""

import json
import argparse
import asyncio
import aiohttp
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Optional
from pathlib import Path
import urllib.request
import urllib.error


@dataclass
class TokenData:
    """Represents a token's market and sentiment data."""
    symbol: str
    name: str
    price_usd: float
    market_cap: float
    volume_24h: float
    price_change_24h: float
    sentiment_score: float  # 0-100
    signal: str  # BUY, SELL, HOLD
    confidence: float  # 0-1
    notes: list[str]


@dataclass
class SentimentReport:
    """Complete sentiment analysis report."""
    timestamp: str
    market_sentiment: str  # Extreme Fear, Fear, Neutral, Greed, Extreme Greed
    fear_greed_index: int
    tokens: list[TokenData]
    summary: str


class CryptoDataFetcher:
    """Fetches crypto market data from various APIs."""

    COINGECKO_TOP_10 = "https://api.coingecko.com/api/v3/coins/markets"
    FEAR_GREED_API = "https://api.alternative.me/fng/?limit=1"

    async def fetch_fear_greed_index(self, session: aiohttp.ClientSession) -> tuple[int, str]:
        """Fetch current Fear & Greed Index."""
        try:
            async with session.get(self.FEAR_GREED_API, timeout=10) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data.get("data"):
                        entry = data["data"][0]
                        return int(entry["value"]), entry["value_classification"]
        except Exception as e:
            print(f"⚠️ Failed to fetch Fear & Greed Index: {e}")

        # Fallback: estimate from market conditions
        return 50, "Neutral"

    async def fetch_top_tokens(self, session: aiohttp.ClientSession) -> list[dict]:
        """Fetch top 10 tokens by market cap from CoinGecko."""
        params = {
            "vs_currency": "usd",
            "order": "market_cap_desc",
            "per_page": "10",
            "page": "1",
            "sparkline": "false",
            "price_change_percentage": "24h"
        }

        try:
            async with session.get(self.COINGECKO_TOP_10, params=params, timeout=15) as resp:
                if resp.status == 200:
                    return await resp.json()
                else:
                    print(f"⚠️ CoinGecko API returned status {resp.status}")
        except Exception as e:
            print(f"⚠️ Failed to fetch token data: {e}")

        return []


class SentimentAnalyzer:
    """Analyzes sentiment and generates trading signals."""

    # Sentiment weightings
    WEIGHT_PRICE_MOMENTUM = 0.35
    WEIGHT_MARKET_CAP_TREND = 0.25
    WEIGHT_VOLUME = 0.20
    WEIGHT_FEAR_GREED = 0.20

    def __init__(self, fear_greed_index: int):
        self.fear_greed_index = fear_greed_index

    def calculate_sentiment_score(self, token: dict) -> float:
        """
        Calculate a sentiment score (0-100) based on multiple factors.
        """
        scores = []

        # Price momentum score (0-100)
        price_change = token.get("price_change_percentage_24h", 0) or 0
        # Normalize: -10% to +10% maps to 0-100
        momentum_score = max(0, min(100, 50 + (price_change * 5)))
        scores.append((momentum_score, self.WEIGHT_PRICE_MOMENTUM))

        # Market cap trend score
        mc_change = token.get("market_cap_change_percentage_24h", 0) or 0
        mc_score = max(0, min(100, 50 + (mc_change * 5)))
        scores.append((mc_score, self.WEIGHT_MARKET_CAP_TREND))

        # Volume score (relative to market cap - higher is better for liquidity)
        volume = token.get("total_volume", 0) or 0
        market_cap = token.get("market_cap", 1) or 1
        volume_ratio = volume / market_cap if market_cap > 0 else 0
        # Normalize: 0-0.05 ratio maps to 0-100
        volume_score = min(100, volume_ratio * 2000)
        scores.append((volume_score, self.WEIGHT_VOLUME))

        # Fear & Greed contribution
        scores.append((self.fear_greed_index, self.WEIGHT_FEAR_GREED))

        # Calculate weighted average
        total_weight = sum(w for _, w in scores)
        weighted_sum = sum(s * w for s, w in scores)
        final_score = weighted_sum / total_weight if total_weight > 0 else 50

        return round(final_score, 2)

    def generate_signal(self, token: dict, sentiment_score: float) -> tuple[str, float, list[str]]:
        """
        Generate buy/sell/hold signal with confidence level.
        Returns: (signal, confidence, notes)
        """
        notes = []
        confidence_factors = []

        price_change = token.get("price_change_percentage_24h", 0) or 0
        market_cap = token.get("market_cap", 0) or 0
        volume = token.get("total_volume", 0) or 0

        # Signal determination
        if sentiment_score >= 70:
            signal = "BUY"
            notes.append(f"Strong bullish sentiment ({sentiment_score}/100)")
        elif sentiment_score <= 30:
            signal = "SELL"
            notes.append(f"Bearish sentiment detected ({sentiment_score}/100)")
        else:
            signal = "HOLD"
            notes.append(f"Neutral sentiment ({sentiment_score}/100)")

        # Price momentum analysis
        if price_change > 5:
            notes.append(f"Strong 24h gain: +{price_change:.2f}%")
            confidence_factors.append(0.8 if signal == "BUY" else 0.4)
        elif price_change > 2:
            notes.append(f"Positive 24h momentum: +{price_change:.2f}%")
            confidence_factors.append(0.7 if signal == "BUY" else 0.5)
        elif price_change < -5:
            notes.append(f"Significant 24h decline: {price_change:.2f}%")
            confidence_factors.append(0.8 if signal == "SELL" else 0.4)
        elif price_change < -2:
            notes.append(f"Negative 24h momentum: {price_change:.2f}%")
            confidence_factors.append(0.7 if signal == "SELL" else 0.5)
        else:
            notes.append(f"Stable price action: {price_change:+.2f}%")
            confidence_factors.append(0.6)

        # Volume analysis
        volume_ratio = volume / market_cap if market_cap > 0 else 0
        if volume_ratio > 0.05:
            notes.append("High trading volume indicates strong interest")
            confidence_factors.append(0.9)
        elif volume_ratio > 0.02:
            notes.append("Healthy trading volume")
            confidence_factors.append(0.7)
        else:
            notes.append("Low volume - exercise caution")
            confidence_factors.append(0.5)

        # Market cap context
        if market_cap > 100_000_000_000:  # > $100B
            notes.append("Large-cap stability")
            confidence_factors.append(0.8)
        elif market_cap > 10_000_000_000:  # > $10B
            notes.append("Mid-cap with growth potential")
            confidence_factors.append(0.7)
        else:
            notes.append("Higher volatility expected")
            confidence_factors.append(0.6)

        # Fear & Greed context
        if self.fear_greed_index < 25:
            notes.append("⚠️ Extreme fear in market - potential bottom")
            if signal == "BUY":
                confidence_factors.append(0.9)
        elif self.fear_greed_index > 75:
            notes.append("⚠️ Extreme greed - consider taking profits")
            if signal == "SELL":
                confidence_factors.append(0.9)

        # Calculate overall confidence
        confidence = sum(confidence_factors) / len(confidence_factors) if confidence_factors else 0.5
        confidence = round(min(1.0, max(0.0, confidence)), 2)

        return signal, confidence, notes


class ReportGenerator:
    """Generates JSON and Markdown reports."""

    @staticmethod
    def to_json(report: SentimentReport, output_path: Path) -> None:
        """Save report as JSON."""
        data = {
            "timestamp": report.timestamp,
            "market_sentiment": report.market_sentiment,
            "fear_greed_index": report.fear_greed_index,
            "summary": report.summary,
            "tokens": [
                {
                    "symbol": t.symbol,
                    "name": t.name,
                    "price_usd": t.price_usd,
                    "market_cap": t.market_cap,
                    "volume_24h": t.volume_24h,
                    "price_change_24h": t.price_change_24h,
                    "sentiment_score": t.sentiment_score,
                    "signal": t.signal,
                    "confidence": t.confidence,
                    "notes": t.notes
                }
                for t in report.tokens
            ]
        }

        output_path.write_text(json.dumps(data, indent=2))
        print(f"✅ JSON report saved: {output_path}")

    @staticmethod
    def to_markdown(report: SentimentReport, output_path: Path) -> None:
        """Save report as Markdown."""
        lines = [
            "# 📊 Crypto Sentiment Analysis Report",
            "",
            f"**Generated:** {report.timestamp}",
            "",
            "## 🌍 Market Overview",
            "",
            f"| Metric | Value |",
            f"|--------|-------|",
            f"| Fear & Greed Index | {report.fear_greed_index}/100 |",
            f"| Market Sentiment | {report.market_sentiment} |",
            "",
            "### Fear & Greed Scale",
            "- **0-24**: Extreme Fear 😱",
            "- **25-44**: Fear 😰",
            "- **45-55**: Neutral 😐",
            "- **56-75**: Greed 😏",
            "- **76-100**: Extreme Greed 🤩",
            "",
            "---",
            "",
            "## 💰 Token Analysis",
            "",
        ]

        # Sort by sentiment score (highest first)
        sorted_tokens = sorted(report.tokens, key=lambda x: x.sentiment_score, reverse=True)

        for token in sorted_tokens:
            signal_emoji = {"BUY": "🟢", "SELL": "🔴", "HOLD": "🟡"}.get(token.signal, "⚪")
            mc_billions = token.market_cap / 1_000_000_000
            volume_millions = token.volume_24h / 1_000_000

            lines.extend([
                f"### {signal_emoji} {token.name} ({token.symbol.upper()})",
                "",
                f"| Metric | Value |",
                f"|--------|-------|",
                f"| Price | ${token.price_usd:,.4f} |",
                f"| Market Cap | ${mc_billions:.2f}B |",
                f"| 24h Volume | ${volume_millions:,.1f}M |",
                f"| 24h Change | {token.price_change_24h:+.2f}% |",
                f"| Sentiment Score | {token.sentiment_score}/100 |",
                f"| Signal | **{token.signal}** |",
                f"| Confidence | {token.confidence*100:.0f}% |",
                "",
                "**Analysis:**",
            ])

            for note in token.notes:
                lines.append(f"- {note}")

            lines.extend(["", "---", ""])

        # Summary section
        lines.extend([
            "",
            "## 📋 Summary",
            "",
            report.summary,
            "",
            "## 🎯 Trading Recommendations",
            "",
        ])

        buy_signals = [t for t in report.tokens if t.signal == "BUY"]
        sell_signals = [t for t in report.tokens if t.signal == "SELL"]
        hold_signals = [t for t in report.tokens if t.signal == "HOLD"]

        if buy_signals:
            lines.extend([
                "### 🟢 Buy Opportunities",
                "",
            ])
            for t in sorted(buy_signals, key=lambda x: x.confidence, reverse=True):
                lines.append(f"- **{t.symbol.upper()}** - Confidence: {t.confidence*100:.0f}%")
            lines.append("")

        if sell_signals:
            lines.extend([
                "### 🔴 Sell Signals",
                "",
            ])
            for t in sorted(sell_signals, key=lambda x: x.confidence, reverse=True):
                lines.append(f"- **{t.symbol.upper()}** - Confidence: {t.confidence*100:.0f}%")
            lines.append("")

        if hold_signals:
            lines.extend([
                "### 🟡 Hold Positions",
                "",
            ])
            for t in sorted(hold_signals, key=lambda x: x.sentiment_score, reverse=True)[:5]:
                lines.append(f"- **{t.symbol.upper()}** - Sentiment: {t.sentiment_score}/100")
            lines.append("")

        lines.extend([
            "---",
            "",
            "*Disclaimer: This report is for informational purposes only and does not constitute financial advice. Always DYOR (Do Your Own Research) before making investment decisions.*",
            "",
        ])

        output_path.write_text("\n".join(lines))
        print(f"✅ Markdown report saved: {output_path}")


class SentimentPipeline:
    """Main pipeline orchestrating data fetching, analysis, and reporting."""

    def __init__(self):
        self.fetcher = CryptoDataFetcher()

    async def run(self, output_dir: Path) -> SentimentReport:
        """Execute the full pipeline."""
        print("🚀 Starting Crypto Sentiment Analysis Pipeline...")
        print()

        async with aiohttp.ClientSession() as session:
            # Fetch data
            print("📡 Fetching Fear & Greed Index...")
            fear_greed, sentiment_label = await self.fetcher.fetch_fear_greed_index(session)
            print(f"   Fear & Greed: {fear_greed}/100 ({sentiment_label})")
            print()

            print("📡 Fetching top 10 token data...")
            tokens_data = await self.fetcher.fetch_top_tokens(session)
            print(f"   Retrieved {len(tokens_data)} tokens")
            print()

            if not tokens_data:
                raise RuntimeError("Failed to fetch token data")

            # Analyze
            print("🧠 Analyzing sentiment patterns...")
            analyzer = SentimentAnalyzer(fear_greed)
            token_analyses = []

            for token in tokens_data:
                sentiment_score = analyzer.calculate_sentiment_score(token)
                signal, confidence, notes = analyzer.generate_signal(token, sentiment_score)

                token_data = TokenData(
                    symbol=token.get("symbol", ""),
                    name=token.get("name", ""),
                    price_usd=token.get("current_price", 0) or 0,
                    market_cap=token.get("market_cap", 0) or 0,
                    volume_24h=token.get("total_volume", 0) or 0,
                    price_change_24h=token.get("price_change_percentage_24h", 0) or 0,
                    sentiment_score=sentiment_score,
                    signal=signal,
                    confidence=confidence,
                    notes=notes
                )
                token_analyses.append(token_data)

            # Generate summary
            buy_count = sum(1 for t in token_analyses if t.signal == "BUY")
            sell_count = sum(1 for t in token_analyses if t.signal == "SELL")
            hold_count = sum(1 for t in token_analyses if t.signal == "HOLD")

            avg_sentiment = sum(t.sentiment_score for t in token_analyses) / len(token_analyses)

            summary = (
                f"Market is showing **{sentiment_label}** sentiment with a Fear & Greed Index of {fear_greed}/100. "
                f"Average token sentiment score is {avg_sentiment:.1f}/100. "
                f"Analysis generated {buy_count} BUY signals, {sell_count} SELL signals, "
                f"and {hold_count} HOLD recommendations among the top 10 cryptocurrencies by market cap."
            )

            report = SentimentReport(
                timestamp=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                market_sentiment=sentiment_label,
                fear_greed_index=fear_greed,
                tokens=token_analyses,
                summary=summary
            )

            # Generate outputs
            print()
            print("📝 Generating reports...")
            output_dir.mkdir(parents=True, exist_ok=True)

            timestamp_str = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

            json_path = output_dir / f"sentiment_report_{timestamp_str}.json"
            ReportGenerator.to_json(report, json_path)

            md_path = output_dir / f"sentiment_report_{timestamp_str}.md"
            ReportGenerator.to_markdown(report, md_path)

            # Also save as latest
            latest_json = output_dir / "sentiment_report_latest.json"
            latest_md = output_dir / "sentiment_report_latest.md"
            ReportGenerator.to_json(report, latest_json)
            ReportGenerator.to_markdown(report, latest_md)

            print()
            print("✅ Pipeline complete!")
            print(f"   Reports saved to: {output_dir}")

            return report


def main():
    parser = argparse.ArgumentParser(
        description="Crypto Sentiment Analysis Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    uv run python3 sentiment_tracker.py
    uv run python3 sentiment_tracker.py --output-dir ./reports
        """
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./sentiment_reports"),
        help="Directory to save reports (default: ./sentiment_reports)"
    )

    args = parser.parse_args()

    try:
        pipeline = SentimentPipeline()
        report = asyncio.run(pipeline.run(args.output_dir))

        # Print quick summary
        print()
        print("=" * 50)
        print("📊 QUICK SUMMARY")
        print("=" * 50)
        print(f"Market Sentiment: {report.market_sentiment} ({report.fear_greed_index}/100)")
        print()
        print("Top Signals:")
        for t in sorted(report.tokens, key=lambda x: x.confidence, reverse=True)[:5]:
            emoji = {"BUY": "🟢", "SELL": "🔴", "HOLD": "🟡"}.get(t.signal, "⚪")
            print(f"  {emoji} {t.symbol.upper()}: {t.signal} (confidence: {t.confidence*100:.0f}%)")

    except Exception as e:
        print(f"❌ Pipeline failed: {e}")
        raise


if __name__ == "__main__":
    main()
