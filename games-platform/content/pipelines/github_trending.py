#!/usr/bin/env python3
"""
GitHub Trending Repository Scanner

Scrapes GitHub trending repositories, filters for AI/ML, crypto, and Elixir repos,
and generates analysis reports in markdown and JSON formats.

Usage:
    python github_trending.py [--output-dir OUTPUT_DIR] [--time-range RANGE]

Environment Variables:
    GITHUB_TOKEN: GitHub personal access token (optional, increases rate limits)
"""

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

import requests


@dataclass
class Repository:
    """Represents a GitHub repository with relevant metadata."""

    name: str
    owner: str
    url: str
    description: str
    stars: int
    stars_today: Optional[int]
    language: Optional[str]
    topics: list[str]
    recent_commits: int
    recent_activity_score: float
    category: str
    analysis: str = ""


class GitHubTrendingScanner:
    """Scans GitHub trending repositories and filters by category."""

    # Keywords for categorization
    AI_ML_KEYWORDS = [
        "ai",
        "artificial intelligence",
        "machine learning",
        "ml",
        "deep learning",
        "neural network",
        "llm",
        "llama",
        "gpt",
        "transformer",
        "pytorch",
        "tensorflow",
        "huggingface",
        "model",
        "inference",
        "training",
        "dataset",
        "nlp",
        "computer vision",
        "cv",
        "stable diffusion",
        "openai",
        "anthropic",
        "langchain",
        "vector",
        "embedding",
        "rag",
        "agent",
        "autonomous",
        "diffusion",
        "generative",
        "gan",
        "reinforcement",
        "rl",
        "mcp",
        "model context protocol",
    ]

    CRYPTO_KEYWORDS = [
        "crypto",
        "cryptocurrency",
        "blockchain",
        "bitcoin",
        "ethereum",
        "defi",
        "web3",
        "smart contract",
        "solidity",
        "vyper",
        "wallet",
        "dex",
        "nft",
        "token",
        "consensus",
        "validator",
        "staking",
        "mining",
        "zero knowledge",
        "zk",
        "rollup",
        "layer 2",
        "l2",
        "bridge",
        "oracle",
        "dao",
        "governance",
        "ipfs",
        "p2p",
        "peer to peer",
        "consensus",
        "merkle",
        "cryptography",
        "solana",
        "base",
        "arbitrum",
        "optimism",
        "uniswap",
        "aave",
        "eigenlayer",
        "reth",
        "foundry",
        "hardhat",
        "ethers",
        "viem",
        "wagmi",
        "usdc",
    ]

    ELIXIR_KEYWORDS = [
        "elixir",
        "phoenix",
        "liveview",
        "phoenix liveview",
        "ecto",
        "beam",
        "erlang",
        "otp",
        "gen_server",
        "supervisor",
        "nerves",
        "broadway",
        "oban",
        "absinthe",
        "ex_unit",
    ]

    def __init__(self, token: Optional[str] = None):
        self.token = token or os.getenv("GITHUB_TOKEN")
        self.session = requests.Session()
        if self.token:
            self.session.headers["Authorization"] = f"token {self.token}"
        self.session.headers["Accept"] = "application/vnd.github.v3+json"
        self.session.headers["User-Agent"] = "GitHubTrendingScanner/1.0"

    def _get_api_url(self, endpoint: str) -> str:
        """Build GitHub API URL."""
        return f"https://api.github.com{endpoint}"

    def _get_trending_from_search(
        self, time_range: str = "daily"
    ) -> list[Repository]:
        """
        Get trending repositories using GitHub Search API.

        Args:
            time_range: 'daily', 'weekly', or 'monthly'
        """
        # Map time ranges to created date filters
        date_filters = {
            "daily": (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d"),
            "weekly": (datetime.now() - timedelta(weeks=1)).strftime("%Y-%m-%d"),
            "monthly": (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d"),
        }

        since_date = date_filters.get(time_range, date_filters["weekly"])

        # Search for repos created or pushed after the date, sorted by stars
        query = f"pushed:>{since_date}"
        url = self._get_api_url("/search/repositories")

        repos = []
        page = 1
        per_page = 100

        while page <= 5:  # Limit to 500 repos to be respectful
            params = {
                "q": query,
                "sort": "stars",
                "order": "desc",
                "per_page": per_page,
                "page": page,
            }

            try:
                response = self.session.get(url, params=params, timeout=30)
                response.raise_for_status()
                data = response.json()

                items = data.get("items", [])
                if not items:
                    break

                for item in items:
                    repo = self._parse_repo_from_search(item)
                    if repo:
                        repos.append(repo)

                if len(items) < per_page:
                    break

                page += 1

            except requests.RequestException as e:
                print(f"Error fetching trending repos: {e}", file=sys.stderr)
                break

        return repos

    def _get_trending_from_scraping(
        self, time_range: str = "daily"
    ) -> list[Repository]:
        """
        Scrape GitHub trending page as fallback.

        Args:
            time_range: 'daily', 'weekly', or 'monthly'
        """
        # GitHub trending URLs
        range_paths = {
            "daily": "?since=daily",
            "weekly": "?since=weekly",
            "monthly": "?since=monthly",
        }

        path = range_paths.get(time_range, "?since=daily")
        url = f"https://github.com/trending{path}"

        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ),
            "Accept": "text/html",
        }

        try:
            response = self.session.get(url, headers=headers, timeout=30)
            response.raise_for_status()
            html = response.text

            return self._parse_trending_html(html)

        except requests.RequestException as e:
            print(f"Error scraping trending page: {e}", file=sys.stderr)
            return []

    def _parse_trending_html(self, html: str) -> list[Repository]:
        """Parse GitHub trending page HTML to extract repository data."""
        repos = []

        # Pattern to match repository entries in trending page
        # Looking for article elements with h2 containing owner/repo-name
        repo_pattern = r'<article[^>]*>.*?<h2[^>]*>.*?<a[^>]*href="(/[^/]+/[^"]+)"[^>]*>.*?</h2>'
        repo_matches = re.findall(repo_pattern, html, re.DOTALL)

        for href in repo_matches[:50]:  # Limit to top 50
            # Clean up the href
            repo_path = href.strip().lstrip("/")
            if "/" not in repo_path:
                continue

            parts = repo_path.split("/")
            if len(parts) >= 2:
                owner, name = parts[0], parts[1]
                repo = self._fetch_repo_details(owner, name)
                if repo:
                    repos.append(repo)

        return repos

    def _fetch_repo_details(self, owner: str, name: str) -> Optional[Repository]:
        """Fetch detailed repository info from GitHub API."""
        url = self._get_api_url(f"/repos/{owner}/{name}")

        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            data = response.json()
            return self._parse_repo_from_api(data)
        except requests.RequestException as e:
            print(f"Error fetching repo {owner}/{name}: {e}", file=sys.stderr)
            return None

    def _parse_repo_from_search(self, item: dict) -> Optional[Repository]:
        """Parse repository data from search API response."""
        return self._parse_repo_from_api(item)

    def _parse_repo_from_api(self, data: dict) -> Optional[Repository]:
        """Parse repository data from GitHub API response."""
        name = data.get("name", "")
        owner = data.get("owner", {}).get("login", "")

        if not name or not owner:
            return None

        # Get topics
        topics = data.get("topics", [])

        # Get recent activity (commits in last week)
        recent_commits = self._get_recent_commit_count(owner, name)

        # Calculate activity score
        activity_score = self._calculate_activity_score(
            stars=data.get("stargazers_count", 0),
            recent_commits=recent_commits,
            updated_at=data.get("updated_at", ""),
        )

        # Determine category
        category = self._categorize_repo(
            name=name,
            description=data.get("description", ""),
            topics=topics,
            language=data.get("language", ""),
        )

        return Repository(
            name=name,
            owner=owner,
            url=data.get("html_url", f"https://github.com/{owner}/{name}"),
            description=data.get("description") or "",
            stars=data.get("stargazers_count", 0),
            stars_today=None,  # Not available from API
            language=data.get("language"),
            topics=topics,
            recent_commits=recent_commits,
            recent_activity_score=activity_score,
            category=category,
        )

    def _get_recent_commit_count(self, owner: str, name: str) -> int:
        """Get number of commits in the last 7 days."""
        url = self._get_api_url(f"/repos/{owner}/{name}/commits")
        since = (datetime.now() - timedelta(days=7)).isoformat()

        try:
            response = self.session.get(url, params={"since": since}, timeout=30)
            response.raise_for_status()
            commits = response.json()
            return len(commits) if isinstance(commits, list) else 0
        except requests.RequestException:
            return 0

    def _calculate_activity_score(
        self, stars: int, recent_commits: int, updated_at: str
    ) -> float:
        """Calculate a recent activity score based on various metrics."""
        score = 0.0

        # Stars contribute to score (logarithmic to prevent dominance)
        if stars > 0:
            score += min(50, 10 * (stars ** 0.5))

        # Recent commits are a strong signal
        score += min(30, recent_commits * 2)

        # Recency of update
        if updated_at:
            try:
                updated = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
                days_since_update = (datetime.now(updated.tzinfo) - updated).days
                if days_since_update < 1:
                    score += 20
                elif days_since_update < 7:
                    score += 10
                elif days_since_update < 30:
                    score += 5
            except ValueError:
                pass

        return round(score, 2)

    def _categorize_repo(
        self,
        name: str,
        description: str,
        topics: list[str],
        language: Optional[str],
    ) -> str:
        """Categorize repository based on keywords."""
        text = f"{name} {description} {' '.join(topics)} {language or ''}".lower()

        # Check for Elixir first (most specific)
        if any(kw in text for kw in self.ELIXIR_KEYWORDS):
            return "elixir"

        # Check for AI/ML
        if any(kw in text for kw in self.AI_ML_KEYWORDS):
            return "ai_ml"

        # Check for crypto
        if any(kw in text for kw in self.CRYPTO_KEYWORDS):
            return "crypto"

        return "other"

    def get_trending(
        self, time_range: str = "daily", use_scraping: bool = False
    ) -> list[Repository]:
        """
        Get trending repositories.

        Args:
            time_range: 'daily', 'weekly', or 'monthly'
            use_scraping: If True, scrape the trending page instead of using API
        """
        if use_scraping:
            return self._get_trending_from_scraping(time_range)
        return self._get_trending_from_search(time_range)

    def filter_interesting_repos(
        self,
        repos: list[Repository],
        min_stars: int = 50,
        categories: Optional[list[str]] = None,
    ) -> list[Repository]:
        """
        Filter repositories for interesting ones.

        Args:
            repos: List of repositories to filter
            min_stars: Minimum star count
            categories: List of categories to include (default: ai_ml, crypto, elixir)
        """
        if categories is None:
            categories = ["ai_ml", "crypto", "elixir"]

        filtered = []
        for repo in repos:
            if repo.stars < min_stars:
                continue
            if repo.category not in categories:
                continue
            filtered.append(repo)

        # Sort by activity score
        filtered.sort(key=lambda r: r.recent_activity_score, reverse=True)
        return filtered

    def generate_analysis(self, repo: Repository) -> str:
        """Generate a brief analysis of a repository."""
        analysis_parts = []

        # Category-specific analysis
        if repo.category == "ai_ml":
            analysis_parts.append(self._analyze_ai_ml_repo(repo))
        elif repo.category == "crypto":
            analysis_parts.append(self._analyze_crypto_repo(repo))
        elif repo.category == "elixir":
            analysis_parts.append(self._analyze_elixir_repo(repo))

        # Activity assessment
        if repo.recent_commits > 20:
            analysis_parts.append("🔥 Very active development")
        elif repo.recent_commits > 5:
            analysis_parts.append("📈 Active development")
        else:
            analysis_parts.append("📊 Stable/maintenance mode")

        # Star momentum
        if repo.stars > 10000:
            analysis_parts.append("⭐ Major project with significant traction")
        elif repo.stars > 1000:
            analysis_parts.append("⭐ Growing project with good adoption")
        elif repo.stars > 100:
            analysis_parts.append("🌱 Early but promising")

        return " | ".join(analysis_parts)

    def _analyze_ai_ml_repo(self, repo: Repository) -> str:
        """Generate AI/ML-specific analysis."""
        text = f"{repo.name} {repo.description} {' '.join(repo.topics)}".lower()

        if "llm" in text or "gpt" in text or "language model" in text:
            return "🤖 LLM/Language Model project"
        if "diffusion" in text or "stable diffusion" in text or "image" in text:
            return "🎨 Image generation/Diffusion model"
        if "agent" in text or "autonomous" in text:
            return "🤖 AI Agent/Autonomous system"
        if "embedding" in text or "vector" in text or "rag" in text:
            return "🔍 RAG/Vector search project"
        if "training" in text or "fine-tune" in text:
            return "🏋️ Model training/fine-tuning"
        if "inference" in text or "deployment" in text:
            return "⚡ Inference/Deployment optimization"
        if "dataset" in text or "data" in text:
            return "📊 Dataset/Data processing"

        return "🧠 AI/ML project"

    def _analyze_crypto_repo(self, repo: Repository) -> str:
        """Generate crypto-specific analysis."""
        text = f"{repo.name} {repo.description} {' '.join(repo.topics)}".lower()

        if "defi" in text or "dex" in text or "amm" in text:
            return "💰 DeFi/Trading protocol"
        if "wallet" in text or "signer" in text:
            return "👛 Wallet/Signer tool"
        if "smart contract" in text or "solidity" in text or "vyper" in text:
            return "📜 Smart contract framework/tooling"
        if "bridge" in text or "cross-chain" in text:
            return "🌉 Cross-chain/Bridge infrastructure"
        if "zk" in text or "zero knowledge" in text:
            return "🔒 Zero Knowledge/ZK project"
        if "rollup" in text or "l2" in text or "layer 2" in text:
            return "⛓️ L2/Rollup solution"
        if "indexer" in text or "subgraph" in text:
            return "📇 Blockchain indexer"
        if "foundry" in text or "hardhat" in text or "tool" in text:
            return "🛠️ Developer tooling"
        if "mempool" in text or "mev" in text:
            return "⚡ MEV/Transaction infrastructure"

        return "⛓️ Crypto/Web3 project"

    def _analyze_elixir_repo(self, repo: Repository) -> str:
        """Generate Elixir-specific analysis."""
        text = f"{repo.name} {repo.description} {' '.join(repo.topics)}".lower()

        if "phoenix" in text and "liveview" in text:
            return "🔥 Phoenix LiveView application"
        if "phoenix" in text:
            return "🌐 Phoenix web framework project"
        if "nerves" in text:
            return "🔧 Nerves embedded/IoT project"
        if "broadway" in text or "stream" in text or "kafka" in text:
            return "📊 Data streaming/Broadway pipeline"
        if "oban" in text or "job" in text:
            return "⏰ Background job processing"
        if "absinthe" in text or "graphql" in text:
            return "📡 GraphQL API (Absinthe)"
        if "ecto" in text and "database" in text:
            return "🗄️ Database/Ecto tooling"
        if "beam" in text or "erlang" in text:
            return "⚡ BEAM/OTP infrastructure"

        return "💜 Elixir project"


class ReportGenerator:
    """Generates reports in markdown and JSON formats."""

    def __init__(self, scanner: GitHubTrendingScanner):
        self.scanner = scanner

    def generate_markdown(
        self, repos: list[Repository], time_range: str = "daily"
    ) -> str:
        """Generate a markdown report of trending repositories."""
        lines = [
            "# 🔥 GitHub Trending Repositories",
            "",
            f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M UTC')}",
            f"Time Range: {time_range.capitalize()}",
            "",
            "---",
            "",
        ]

        # Group by category
        categories = {
            "ai_ml": "🤖 AI / Machine Learning",
            "crypto": "⛓️ Crypto / Web3 / Blockchain",
            "elixir": "💜 Elixir / BEAM",
        }

        for cat_key, cat_title in categories.items():
            cat_repos = [r for r in repos if r.category == cat_key]

            if not cat_repos:
                continue

            lines.extend([
                f"## {cat_title}",
                "",
            ])

            for repo in cat_repos[:20]:  # Top 20 per category
                lines.extend(self._format_repo_markdown(repo))

            lines.append("")

        lines.extend([
            "---",
            "",
            "*Generated by GitHub Trending Scanner*",
        ])

        return "\n".join(lines)

    def _format_repo_markdown(self, repo: Repository) -> list[str]:
        """Format a single repository as markdown."""
        lines = [
            f"### [{repo.owner}/{repo.name}]({repo.url})",
            "",
        ]

        if repo.description:
            lines.append(f"> {repo.description}")
            lines.append("")

        # Stats line
        stats = [f"⭐ {repo.stars:,} stars"]
        if repo.language:
            stats.append(f"📝 {repo.language}")
        stats.append(f"📊 Activity Score: {repo.recent_activity_score}")
        stats.append(f"🔄 {repo.recent_commits} commits (7d)")

        lines.append(" | ".join(stats))
        lines.append("")

        # Topics
        if repo.topics:
            topic_tags = " ".join(f"`{t}`" for t in repo.topics[:8])
            lines.append(f"**Topics:** {topic_tags}")
            lines.append("")

        # Analysis
        if repo.analysis:
            lines.append(f"**Analysis:** {repo.analysis}")
            lines.append("")

        lines.append("---")
        lines.append("")

        return lines

    def generate_json(self, repos: list[Repository]) -> str:
        """Generate a JSON report of trending repositories."""
        data = {
            "generated_at": datetime.now().isoformat(),
            "total_repos": len(repos),
            "categories": {},
            "repositories": [asdict(r) for r in repos],
        }

        # Count by category
        for cat in ["ai_ml", "crypto", "elixir", "other"]:
            count = len([r for r in repos if r.category == cat])
            data["categories"][cat] = count

        return json.dumps(data, indent=2, default=str)

    def save_reports(
        self,
        repos: list[Repository],
        output_dir: Path,
        time_range: str = "daily",
    ) -> tuple[Path, Path]:
        """Save reports to files and return paths."""
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        base_name = f"github_trending_{time_range}_{timestamp}"

        # Save markdown
        md_path = output_dir / f"{base_name}.md"
        md_content = self.generate_markdown(repos, time_range)
        md_path.write_text(md_content, encoding="utf-8")

        # Save JSON
        json_path = output_dir / f"{base_name}.json"
        json_content = self.generate_json(repos)
        json_path.write_text(json_content, encoding="utf-8")

        return md_path, json_path


def main():
    parser = argparse.ArgumentParser(
        description="Scan GitHub trending repositories for AI/ML, crypto, and Elixir projects"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./output"),
        help="Directory to save reports (default: ./output)",
    )
    parser.add_argument(
        "--time-range",
        choices=["daily", "weekly", "monthly"],
        default="weekly",
        help="Time range for trending repos (default: weekly)",
    )
    parser.add_argument(
        "--min-stars",
        type=int,
        default=50,
        help="Minimum star count to include (default: 50)",
    )
    parser.add_argument(
        "--use-scraping",
        action="store_true",
        help="Scrape GitHub trending page instead of using API",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=100,
        help="Maximum number of repos to analyze (default: 100)",
    )

    args = parser.parse_args()

    # Initialize scanner
    token = os.getenv("GITHUB_TOKEN")
    scanner = GitHubTrendingScanner(token=token)

    print(f"🔍 Scanning GitHub trending repositories ({args.time_range})...")

    # Fetch trending repos
    all_repos = scanner.get_trending(
        time_range=args.time_range,
        use_scraping=args.use_scraping,
    )

    print(f"📦 Found {len(all_repos)} total repositories")

    # Filter for interesting repos
    interesting = scanner.filter_interesting_repos(
        all_repos[: args.limit],
        min_stars=args.min_stars,
    )

    print(f"🎯 Found {len(interesting)} interesting repositories")

    # Generate analysis for each repo
    print("🧠 Generating analysis...")
    for repo in interesting:
        repo.analysis = scanner.generate_analysis(repo)

    # Generate reports
    generator = ReportGenerator(scanner)
    md_path, json_path = generator.save_reports(
        interesting, args.output_dir, args.time_range
    )

    print(f"\n✅ Reports saved:")
    print(f"   📄 Markdown: {md_path}")
    print(f"   📊 JSON: {json_path}")

    # Print summary
    categories = {}
    for repo in interesting:
        categories[repo.category] = categories.get(repo.category, 0) + 1

    print(f"\n📈 Summary:")
    for cat, count in sorted(categories.items()):
        emoji = {"ai_ml": "🤖", "crypto": "⛓️", "elixir": "💜"}.get(cat, "📦")
        print(f"   {emoji} {cat}: {count}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
