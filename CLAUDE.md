# Preread — Claude Code Notes

## Article ordering

When querying or processing articles (refreshing, retrying, caching), always sort newest-first: `ORDER BY COALESCE(publishedAt, addedAt) DESC`. This applies to every code path that fetches articles for processing — feed refresh, retry of failed/pending articles, background tasks, etc.
