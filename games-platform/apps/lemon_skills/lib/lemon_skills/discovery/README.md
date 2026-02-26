# Online Skill Discovery

The `LemonSkills.Discovery` module provides online skill discovery capabilities, allowing Lemon to find and install skills from external sources like GitHub.

## Overview

Inspired by Ironclaw's extension registry pattern, the discovery system enables:

- **GitHub Search**: Find skills by searching repositories with `topic:lemon-skill`
- **Registry Probing**: Check well-known URLs for skill manifests
- **Relevance Scoring**: Rank results by stars, name matches, keywords, and descriptions
- **Concurrent Search**: Fast multi-source searching with timeouts
- **Result Validation**: Verify discovered skills have valid SKILL.md manifests

## Usage

### Basic Discovery

```elixir
# Search GitHub for skills matching "github"
results = LemonSkills.Registry.discover("github")

# Each result contains:
# - entry: %LemonSkills.Entry{} - The skill entry
# - source: :github | :registry - Where it was found
# - validated: boolean - Whether SKILL.md was validated
# - url: String.t() - The skill URL
```

### Unified Local + Online Search

```elixir
# Search both local and online skills
%{local: local_skills, online: online_skills} =
  LemonSkills.Registry.search("api", max_local: 3, max_online: 5)
```

### Direct Discovery Module Usage

```elixir
# Discover with custom options
results = LemonSkills.Discovery.discover("webhook", 
  timeout: 15_000, 
  max_results: 10,
  github_token: System.get_env("GITHUB_TOKEN")
)

# Validate a specific skill URL
entry = LemonSkills.Discovery.validate_skill("https://raw.githubusercontent.com/user/repo/main/SKILL.md")
```

## Configuration

Discovery behavior can be configured via environment variables:

- `GITHUB_TOKEN` - Personal access token for higher GitHub API rate limits

## Scoring Algorithm

Results are ranked using a weighted scoring system:

| Signal | Weight | Description |
|--------|--------|-------------|
| GitHub Stars | Up to 100 | Capped at 100 points |
| Exact Name Match | 100 | Full name match |
| Partial Name Match | 50 | Partial name match |
| Display Name Match | 30 | Match in display name |
| Exact Keyword Match | 40 | From SKILL.md keywords |
| Partial Keyword Match | 20 | Partial keyword match |
| Description Word | 10 | Per matching word |
| Body Content Word | 2 | Per matching word (weakest) |

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    LemonSkills.Discovery                     │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ GitHub Search │  │ URL Probing  │  │ Result Validation │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│         │                 │                  │              │
│         └─────────────────┴──────────────────┘              │
│                           │                                 │
│                    ┌──────────────┐                        │
│                    │ Deduplication │                        │
│                    └──────────────┘                        │
│                           │                                 │
│                    ┌──────────────┐                        │
│                    │   Scoring    │                        │
│                    └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### Search Flow

1. **Query Normalization**: Clean and tokenize the search query
2. **Concurrent Search**: Run GitHub API and registry probes in parallel
3. **Result Collection**: Gather results with timeout handling
4. **Deduplication**: Remove duplicate URLs
5. **Scoring**: Calculate relevance scores for each result
6. **Sorting**: Return results sorted by score (highest first)

## GitHub Search

The discovery system searches GitHub using the following query:

```
topic:lemon-skill {query} in:name,description,readme
```

This finds repositories tagged with `lemon-skill` that match the query in their name, description, or README.

### Rate Limiting

- Without token: 60 requests/hour
- With token: 5,000 requests/hour

## Registry URL Probing

The system probes well-known URL patterns:

- `https://skills.lemon.agent/{query}`
- `https://raw.githubusercontent.com/lemon-agent/skills/main/{query}/SKILL.md`

## Skill Validation

Discovered skills are validated by:

1. Fetching the SKILL.md from the raw URL
2. Parsing the YAML frontmatter
3. Checking for required fields (name or key)
4. Creating an Entry struct with metadata

## Testing

Due to HTTP client limitations in the test environment, some discovery tests are skipped. To run full integration tests:

```bash
# Run all tests including integration tests
mix test --include integration
```

## Future Enhancements

- [ ] Cache discovery results to reduce API calls
- [ ] Add more registry sources (GitLab, Bitbucket)
- [ ] Implement skill installation from discovered entries
- [ ] Add skill ratings/reviews from community
- [ ] Support private registry authentication

## See Also

- `LemonSkills.Registry` - Local skill registry
- `LemonSkills.Entry` - Skill entry struct
- `LemonSkills.Manifest` - SKILL.md parsing
