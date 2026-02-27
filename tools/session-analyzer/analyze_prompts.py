"""Phase 2a: TF-IDF clustering on user prompts."""

from __future__ import annotations

import re
from pathlib import Path

import polars as pl
from sklearn.cluster import MiniBatchKMeans
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics import silhouette_score


def _preprocess(text: str) -> str:
    """Lowercase, strip paths/UUIDs/hashes, remove noise."""
    text = text.lower()
    # Strip file paths
    text = re.sub(r"[/\\][\w._\-/\\]+\.\w+", " PATH ", text)
    text = re.sub(r"[/\\][\w._\-/\\]{3,}", " PATH ", text)
    # Strip UUIDs
    text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", " UUID ", text)
    # Strip hex hashes
    text = re.sub(r"\b[0-9a-f]{7,40}\b", " HASH ", text)
    # Strip numbers
    text = re.sub(r"\b\d+\b", " NUM ", text)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _auto_k(n_samples: int) -> list[int]:
    """Generate candidate k values based on dataset size."""
    if n_samples < 50:
        return [3, 5, 8]
    if n_samples < 200:
        return [5, 10, 15, 20]
    if n_samples < 1000:
        return [10, 20, 30, 40]
    return [20, 30, 40, 50, 60]


def _label_from_terms(terms: list[str]) -> str:
    """Create a cluster label from top TF-IDF terms."""
    # Filter out placeholder tokens
    filtered = [t for t in terms if t not in ("path", "uuid", "hash", "num")]
    return " / ".join(filtered[:4]) if filtered else "misc"


def run_prompt_clustering(output_dir: Path) -> pl.DataFrame:
    """Cluster prompts by TF-IDF similarity. Returns clusters DataFrame."""
    prompts_path = output_dir / "prompts.parquet"
    if not prompts_path.exists():
        raise FileNotFoundError(f"Run extraction first: {prompts_path}")

    df = pl.read_parquet(prompts_path)
    if len(df) == 0:
        empty = pl.DataFrame(schema={
            "cluster_id": pl.UInt32,
            "label": pl.Utf8,
            "count": pl.UInt32,
            "example_prompts": pl.List(pl.Utf8),
            "top_terms": pl.List(pl.Utf8),
            "sources": pl.List(pl.Utf8),
        })
        empty.write_parquet(output_dir / "clusters.parquet")
        return empty

    # Preprocess
    texts = df["text"].to_list()
    processed = [_preprocess(t) for t in texts]

    # Filter out very short prompts
    valid_mask = [len(p) > 10 for p in processed]
    valid_texts = [p for p, v in zip(processed, valid_mask) if v]
    valid_indices = [i for i, v in enumerate(valid_mask) if v]

    if len(valid_texts) < 5:
        # Too few prompts to cluster
        clusters_data = [{
            "cluster_id": 0,
            "label": "all prompts",
            "count": len(valid_texts),
            "example_prompts": [texts[i][:200] for i in valid_indices[:5]],
            "top_terms": [],
            "sources": df["source"].unique().to_list(),
        }]
        result = pl.DataFrame(clusters_data)
        result.write_parquet(output_dir / "clusters.parquet")
        return result

    # TF-IDF
    vectorizer = TfidfVectorizer(
        max_features=5000,
        ngram_range=(1, 3),
        min_df=2,
        max_df=0.8,
        stop_words="english",
    )
    tfidf_matrix = vectorizer.fit_transform(valid_texts)
    feature_names = vectorizer.get_feature_names_out()

    # Find best k via silhouette score
    candidates = _auto_k(len(valid_texts))
    candidates = [k for k in candidates if k < len(valid_texts)]

    best_k = candidates[0]
    best_score = -1.0

    for k in candidates:
        km = MiniBatchKMeans(n_clusters=k, random_state=42, batch_size=256, n_init=3)
        labels = km.fit_predict(tfidf_matrix)
        if len(set(labels)) > 1:
            score = silhouette_score(tfidf_matrix, labels, sample_size=min(5000, len(valid_texts)))
            if score > best_score:
                best_score = score
                best_k = k

    # Final clustering
    km = MiniBatchKMeans(n_clusters=best_k, random_state=42, batch_size=256, n_init=3)
    labels = km.fit_predict(tfidf_matrix)

    # Add cluster labels back to prompts DataFrame
    cluster_col = [None] * len(df)
    for idx_pos, orig_idx in enumerate(valid_indices):
        cluster_col[orig_idx] = int(labels[idx_pos])
    df = df.with_columns(pl.Series("cluster_id", cluster_col, dtype=pl.UInt32))

    # Build cluster summaries
    clusters_data = []
    for cid in range(best_k):
        mask = labels == cid
        cluster_indices = [valid_indices[i] for i, m in enumerate(mask) if m]
        count = len(cluster_indices)
        if count == 0:
            continue

        # Top terms from cluster centroid
        centroid = km.cluster_centers_[cid]
        top_term_indices = centroid.argsort()[-10:][::-1]
        top_terms = [feature_names[i] for i in top_term_indices]

        # Sample prompts
        sample_indices = cluster_indices[:5]
        examples = [texts[i][:200] for i in sample_indices]

        # Sources represented
        sources = list(set(df["source"][i] for i in cluster_indices))

        clusters_data.append({
            "cluster_id": cid,
            "label": _label_from_terms(top_terms),
            "count": count,
            "example_prompts": examples,
            "top_terms": top_terms[:10],
            "sources": sorted(sources),
        })

    clusters_data.sort(key=lambda x: x["count"], reverse=True)

    clusters_df = pl.DataFrame(clusters_data, schema={
        "cluster_id": pl.UInt32,
        "label": pl.Utf8,
        "count": pl.UInt32,
        "example_prompts": pl.List(pl.Utf8),
        "top_terms": pl.List(pl.Utf8),
        "sources": pl.List(pl.Utf8),
    })
    clusters_df.write_parquet(output_dir / "clusters.parquet")

    # Also save prompts with cluster assignments
    df.write_parquet(output_dir / "prompts_clustered.parquet")

    return clusters_df
