#!/usr/bin/env python3
"""
RSS Feed Ingestion Pipeline for Crypto News
Fetches, parses, deduplicates, and summarizes articles from major crypto news sources.
"""

import json
import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Dict, Any, Optional
from dataclasses import dataclass, asdict
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

import feedparser
import requests


# Crypto news RSS feeds
RSS_FEEDS = {
    "coindesk": "https://www.coindesk.com/arc/outboundfeeds/rss/",
    "theblock": "https://www.theblock.co/rss.xml",
    "decrypt": "https://decrypt.co/feed",
    "cointelegraph": "https://cointelegraph.com/rss",
}

# Common crypto tokens and projects for entity extraction
KNOWN_TOKENS = {
    "bitcoin", "btc", "ethereum", "eth", "solana", "sol", "cardano", "ada",
    "polkadot", "dot", "avalanche", "avax", "chainlink", "link", "polygon",
    "matic", "arbitrum", "arb", "optimism", "op", "base", "uniswap", "uni",
    "aave", "compound", "maker", "mkr", "dai", "usdc", "usdt", "tether",
    "bnb", "binance", "coinbase", "kraken", "ftx", "ripple", "xrp", "litecoin",
    "ltc", "dogecoin", "doge", "shiba", "shib", "pepe", "bonk", "jupiter",
    "jup", "raydium", "orca", "meteora", "pump", "pumpfun", "hyperliquid",
    "hype", "virtuals", "aixbt", "luna", "terra", "cosmos", "atom", "near",
    "sui", "sei", "injective", "inj", "celestia", "tia", "dydx", "gmx",
    "lido", "steth", "rocketpool", "reth", "eigenlayer", "eigen", "pendle",
    "etherfi", "renzo", "kelp", "swell", "puffer", "zircuit", "scroll",
    "zksync", "starknet", "strk", "linea", "mantle", "mnt", "mode",
}

KNOWN_PROJECTS = {
    "ethereum", "solana", "cardano", "polkadot", "avalanche", "chainlink",
    "polygon", "arbitrum", "optimism", "base", "uniswap", "aave", "compound",
    "makerdao", "tether", "circle", "binance", "coinbase", "kraken", "ftx",
    "ripple", "litecoin", "dogecoin", "shibainu", "pepe", "bonk", "jupiter",
    "raydium", "orca", "meteora", "pumpfun", "hyperliquid", "virtuals",
    "aixbt", "terra", "cosmos", "nearprotocol", "sui", "sei", "injective",
    "celestia", "dydx", "gmx", "lido", "rocketpool", "eigenlayer", "pendle",
    "etherfi", "renzo", "kelp", "swell", "puffer", "zircuit", "scroll",
    "zksync", "starknet", "linea", "mantle", "mode", "opensea", "blur",
    "magiceden", "tensor", "looksrare", "x2y2", "foundation", "superrare",
    "zora", "manifold", "thirdweb", "alchemy", "infura", "quicknode",
    "chainalysis", "nansen", "dune", "defillama", "coingecko", "coinmarketcap",
    "messari", "theblock", "coindesk", "decrypt", "cointelegraph", "bankless",
    "dlnews", "blockworks", "cryptobriefing", "ambcrypto", "beincrypto",
}

KNOWN_PEOPLE = {
    "vitalikbuterin", "satoshi", "nakamoto", "cz", "changpengzhao",
    "brianarmstrong", "sbf", "sambankmanfried", "garygensler", "elonmusk",
    "michaelsaylor", "anthonypompliano", "cathiewood", "raoulpal",
    "haydenadams", "stani", "andre cronje", "danielesesta", "dokwon",
    "do kwon", "suzhu", "kylesamani", "anatolyyakovenko", "amritkumar",
    "sandeepnailwal", "jaynti kanani", "juanbenet", "gavwood", "robert habermeier",
    "sergeynazarov", "stani kulechov", "rune christensen", "hayden adams",
}


@dataclass
class Article:
    """Represents a parsed RSS article."""
    id: str
    title: str
    link: str
    source: str
    published: Optional[str]
    summary: str
    content: str
    authors: List[str]
    tags: List[str]
    entities: Dict[str, List[str]]
    fetched_at: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class EntityExtractor:
    """Extracts crypto-related entities from article text."""

    def __init__(self):
        self.token_pattern = re.compile(
            r'\$([a-zA-Z]{2,10})|\b(' + '|'.join(re.escape(t) for t in KNOWN_TOKENS) + r')\b',
            re.IGNORECASE
        )
        self.project_pattern = re.compile(
            r'\b(' + '|'.join(re.escape(p) for p in KNOWN_PROJECTS) + r')\b',
            re.IGNORECASE
        )
        self.people_pattern = re.compile(
            r'\b(' + '|'.join(re.escape(p.replace(' ', '')) for p in KNOWN_PEOPLE) + r')\b',
            re.IGNORECASE
        )
        # Additional pattern for capitalized project names (heuristic)
        self.capitalized_pattern = re.compile(r'\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b')

    def extract(self, text: str) -> Dict[str, List[str]]:
        """Extract tokens, projects, and people from text."""
        text_lower = text.lower()
        text_no_spaces = text_lower.replace(' ', '')

        # Extract tokens (with $ prefix or known tokens)
        tokens = set()
        for match in self.token_pattern.finditer(text):
            token = match.group(1) or match.group(2)
            if token:
                tokens.add(token.upper())

        # Extract projects
        projects = set()
        for match in self.project_pattern.finditer(text_lower):
            projects.add(match.group(0).title())

        # Extract people
        people = set()
        for match in self.people_pattern.finditer(text_no_spaces):
            # Map back to proper name format
            name = match.group(0).lower()
            for known in KNOWN_PEOPLE:
                if known.replace(' ', '') == name:
                    people.add(known.title())
                    break

        # Extract potential projects from capitalized words
        for match in self.capitalized_pattern.finditer(text):
            word = match.group(1)
            if len(word) > 3 and word.lower() not in {'bitcoin', 'ethereum'}:
                # Filter out common false positives
                if word.lower() not in {'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all'}:
                    projects.add(word)

        return {
            "tokens": sorted(list(tokens)),
            "projects": sorted(list(projects)),
            "people": sorted(list(people)),
        }


class RSSIngester:
    """Main RSS ingestion pipeline."""

    def __init__(self, output_dir: Optional[Path] = None):
        self.output_dir = output_dir or Path.home() / "dev" / "lemon" / "content" / "data" / "rss"
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.entity_extractor = EntityExtractor()
        self.seen_ids: set = set()

    def _generate_id(self, article: Dict[str, Any]) -> str:
        """Generate unique ID for deduplication."""
        content = f"{article.get('title', '')}{article.get('link', '')}"
        return hashlib.sha256(content.encode()).hexdigest()[:16]

    def _parse_date(self, entry: Any) -> Optional[str]:
        """Extract and normalize publication date."""
        # Try various date fields
        for field in ['published', 'updated', 'created']:
            if hasattr(entry, field) and getattr(entry, field):
                date_str = getattr(entry, field)
                try:
                    # Parse and convert to ISO format
                    parsed = datetime(*entry.get(field + '_parsed', ())[:6], tzinfo=timezone.utc)
                    return parsed.isoformat()
                except (TypeError, ValueError):
                    return date_str
        return None

    def _extract_content(self, entry: Any) -> str:
        """Extract full content from entry."""
        # Try content field first
        if hasattr(entry, 'content') and entry.content:
            return entry.content[0].value if isinstance(entry.content, list) else str(entry.content)
        # Fall back to summary/description
        if hasattr(entry, 'summary') and entry.summary:
            return entry.summary
        if hasattr(entry, 'description') and entry.description:
            return entry.description
        return ""

    def _clean_html(self, html: str) -> str:
        """Remove HTML tags from text."""
        # Simple HTML tag removal
        clean = re.sub(r'<[^>]+>', ' ', html)
        # Normalize whitespace
        clean = re.sub(r'\s+', ' ', clean).strip()
        return clean

    def fetch_feed(self, source: str, url: str) -> List[Article]:
        """Fetch and parse a single RSS feed."""
        articles = []
        try:
            print(f"Fetching {source}...")
            feed = feedparser.parse(url)

            for entry in feed.entries:
                article_id = self._generate_id({
                    'title': entry.get('title', ''),
                    'link': entry.get('link', '')
                })

                # Skip duplicates
                if article_id in self.seen_ids:
                    continue
                self.seen_ids.add(article_id)

                # Extract content
                raw_content = self._extract_content(entry)
                clean_content = self._clean_html(raw_content)
                clean_summary = self._clean_html(entry.get('summary', ''))

                # Extract entities
                full_text = f"{entry.get('title', '')} {clean_content}"
                entities = self.entity_extractor.extract(full_text)

                # Parse authors
                authors = []
                if hasattr(entry, 'author') and entry.author:
                    authors.append(entry.author)
                if hasattr(entry, 'authors') and entry.authors:
                    authors.extend([a.get('name', '') for a in entry.authors if isinstance(a, dict)])

                # Parse tags/categories
                tags = []
                if hasattr(entry, 'tags') and entry.tags:
                    tags = [t.get('term', '') for t in entry.tags if isinstance(t, dict)]
                if hasattr(entry, 'category') and entry.category:
                    tags.append(entry.category)

                article = Article(
                    id=article_id,
                    title=self._clean_html(entry.get('title', 'Untitled')),
                    link=entry.get('link', ''),
                    source=source,
                    published=self._parse_date(entry),
                    summary=clean_summary[:500] if clean_summary else clean_content[:500],
                    content=clean_content,
                    authors=list(set(a for a in authors if a)),
                    tags=list(set(t for t in tags if t)),
                    entities=entities,
                    fetched_at=datetime.now(timezone.utc).isoformat(),
                )
                articles.append(article)

            print(f"  ✓ Fetched {len(articles)} articles from {source}")

        except Exception as e:
            print(f"  ✗ Error fetching {source}: {e}")

        return articles

    def fetch_all(self) -> List[Article]:
        """Fetch all configured RSS feeds."""
        all_articles = []
        for source, url in RSS_FEEDS.items():
            articles = self.fetch_feed(source, url)
            all_articles.extend(articles)
        return all_articles

    def generate_digest(self, articles: List[Article]) -> Dict[str, Any]:
        """Generate a daily digest summary."""
        now = datetime.now(timezone.utc)

        # Aggregate entities
        all_tokens = set()
        all_projects = set()
        all_people = set()

        for article in articles:
            all_tokens.update(article.entities.get('tokens', []))
            all_projects.update(article.entities.get('projects', []))
            all_people.update(article.entities.get('people', []))

        # Group articles by source
        by_source = {}
        for article in articles:
            by_source.setdefault(article.source, []).append({
                "title": article.title,
                "link": article.link,
                "published": article.published,
                "entities": article.entities,
            })

        # Top mentioned tokens
        token_counts = {}
        for article in articles:
            for token in article.entities.get('tokens', []):
                token_counts[token] = token_counts.get(token, 0) + 1

        # Top mentioned projects
        project_counts = {}
        for article in articles:
            for project in article.entities.get('projects', []):
                project_counts[project] = project_counts.get(project, 0) + 1

        digest = {
            "generated_at": now.isoformat(),
            "date": now.strftime("%Y-%m-%d"),
            "summary": {
                "total_articles": len(articles),
                "sources": {source: len(items) for source, items in by_source.items()},
                "unique_tokens": len(all_tokens),
                "unique_projects": len(all_projects),
                "unique_people": len(all_people),
            },
            "top_tokens": sorted(token_counts.items(), key=lambda x: x[1], reverse=True)[:20],
            "top_projects": sorted(project_counts.items(), key=lambda x: x[1], reverse=True)[:20],
            "entities": {
                "tokens": sorted(list(all_tokens)),
                "projects": sorted(list(all_projects)),
                "people": sorted(list(all_people)),
            },
            "articles_by_source": by_source,
            "all_articles": [a.to_dict() for a in articles],
        }

        return digest

    def save_digest(self, digest: Dict[str, Any]) -> Path:
        """Save digest to JSON file."""
        date_str = digest['date']
        filename = f"digest_{date_str}.json"
        filepath = self.output_dir / filename

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(digest, f, indent=2, ensure_ascii=False)

        return filepath

    def save_raw_articles(self, articles: List[Article]) -> Path:
        """Save raw articles to JSON file."""
        now = datetime.now(timezone.utc)
        filename = f"articles_{now.strftime('%Y%m%d_%H%M%S')}.json"
        filepath = self.output_dir / filename

        data = {
            "fetched_at": now.isoformat(),
            "count": len(articles),
            "articles": [a.to_dict() for a in articles],
        }

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        return filepath

    def run(self) -> Dict[str, Any]:
        """Run the full ingestion pipeline."""
        print("=" * 60)
        print("RSS Feed Ingestion Pipeline")
        print(f"Started at: {datetime.now(timezone.utc).isoformat()}")
        print("=" * 60)

        # Fetch all feeds
        print("\n📡 Fetching RSS feeds...")
        articles = self.fetch_all()

        if not articles:
            print("\n⚠️ No articles fetched. Check your internet connection.")
            return {"success": False, "error": "No articles fetched"}

        print(f"\n📊 Total unique articles: {len(articles)}")

        # Generate digest
        print("\n📝 Generating digest...")
        digest = self.generate_digest(articles)

        # Save outputs
        print("\n💾 Saving outputs...")
        digest_path = self.save_digest(digest)
        raw_path = self.save_raw_articles(articles)

        print(f"  ✓ Digest saved: {digest_path}")
        print(f"  ✓ Raw articles saved: {raw_path}")

        # Print summary
        print("\n" + "=" * 60)
        print("DIGEST SUMMARY")
        print("=" * 60)
        print(f"Date: {digest['date']}")
        print(f"Total Articles: {digest['summary']['total_articles']}")
        print(f"Sources: {digest['summary']['sources']}")
        print(f"Unique Tokens: {digest['summary']['unique_tokens']}")
        print(f"Unique Projects: {digest['summary']['unique_projects']}")
        print(f"Unique People: {digest['summary']['unique_people']}")

        if digest['top_tokens']:
            print(f"\nTop Tokens: {', '.join(f'{t}({c})' for t, c in digest['top_tokens'][:10])}")

        if digest['top_projects']:
            print(f"Top Projects: {', '.join(f'{p}({c})' for p, c in digest['top_projects'][:10])}")

        print("\n" + "=" * 60)

        return {
            "success": True,
            "articles_count": len(articles),
            "digest_path": str(digest_path),
            "raw_path": str(raw_path),
            "digest": digest,
        }


def main():
    """Main entry point."""
    ingester = RSSIngester()
    result = ingester.run()
    return result


if __name__ == "__main__":
    main()
