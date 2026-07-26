#!/usr/bin/env nu

# Build the SELECT query for a given tag against v_freshrss_entries.
# Columns returned (tab-separated):
#   title | link | date | feed_name | category_name | author | snippet
def freshrss-query [tag: string] {
    "SELECT
    title,
    replace(link, '&amp;', '&'),
    to_char(to_timestamp(date), 'Mon DD YYYY'),
    feed_name,
    COALESCE(category_name, ''),
    COALESCE(author, ''),
    COALESCE(
        NULLIF(btrim(replace(replace(NULLIF(entry_attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''),
        NULLIF(btrim(replace(replace(regexp_replace(COALESCE(content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''),
        ''
    )
FROM v_freshrss_entries
WHERE tag_name = '" + $tag + "'
  AND link IS NOT NULL AND link != ''
ORDER BY date DESC;"
}

# Build the shared "- [title](link) — date" + optional "    - feed | category | author"
# lines from a raw tab-separated entry row's parsed parts. Shared by
# entry-to-markdown and entry-from-avro, which differ only in what
# additional bullet lines they append (raw content snippet vs. LLM summary
# bullets).
def entry-header-lines [parts: list] {
    let title = ($parts | get 0)
        | str replace --all --regex '\|\|.*$' ''
        | str replace --all --regex ' • From .*$' ''
        | str trim
        | str replace --all '&amp;' '&'
        | str replace --all '&lt;'  '<'
        | str replace --all '&gt;'  '>'
    let link   = ($parts | get 1)
    let date   = ($parts | get 2)
    let feed   = ($parts | get 3)
    let cat    = ($parts | get 4)
    let author = ($parts | get 5) | str replace --regex '^;+' ''

    let author_display = if ($author == $feed) { "" } else { $author }
    let meta = ([$feed, $cat, $author_display] | filter { |p| ($p | str trim) != "" } | str join " | ")
    let base = [$"- [($title)]\(($link)\) — ($date)"]
    if ($meta | str trim) != "" { $base | append $"    - ($meta)" } else { $base }
}

# Convert a raw tab-separated entry row into a formatted markdown list item string.
def entry-to-markdown [l: string] {
    let parts = ($l | split row "\t")
    let raw_snip = (if ($parts | length) > 6 { $parts | get 6 } else { "" })

    let snip_lines = if ($raw_snip | str trim) != "" {
        ($raw_snip
            | str replace --all '&amp;' '&'
            | str replace --all '&lt;'  '<'
            | str replace --all '&gt;'  '>'
            | split row "|||"
            | filter { |line|
                let t = ($line | str trim)
                (($t | str length) > 15 and not ($t | str ends-with ":") and not ($t =~ '(?i)^(#|http|\*\*|Full video:|Follow |Via:|Support |Substack:|Cashapp:|Venmo:|PayPal:|estimated reading time|.*Merch:)') and not ($t =~ 'https?://') and not ($t =~ '\w+\.\w+/'))
            }
            | take 2
            | each { |line|
                let t = ($line | str trim)
                if ($t | str length) > 250 { ($t | str substring 0..249) + "…" } else { $t }
            })
    } else { [] }

    let snip_items = ($snip_lines | each { |s| $"    - ($s)" })
    (entry-header-lines $parts | append $snip_items) | str join "\n"
}

def "main freshrss update-technical" [
    --host (-H): string = "postgresql.verticon.com"
    --news-file: string = "/home/jconlon/git/news/docs/index.md"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let link_lines = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-query "technical")
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l| entry-to-markdown $l }
    )

    if ($link_lines | is-empty) {
        error make { msg: "No links returned from database — aborting to protect the news file." }
    }

    let file_lines = (open $news_file | lines)

    let heading_idx = (
        $file_lines
        | enumerate
        | where { |row| $row.item == "### Technical" }
        | first
        | get index
    )

    let next_heading_idx = (
        $file_lines
        | enumerate
        | skip ($heading_idx + 1)
        | where { |row| ($row.item | str starts-with "## ") or ($row.item | str starts-with "### ") }
        | first
        | get index
    )

    let before = ($file_lines | take ($heading_idx + 2))
    let after  = ($file_lines | skip ($next_heading_idx - 1))

    ($before | append $link_lines | append "" | append $after | str join "\n") + "\n"
    | save --force $news_file

    print $"Updated ($news_file) ### Technical with ($link_lines | length) links."
}

def "main freshrss update-news" [
    --host (-H): string = "postgresql.verticon.com"
    --news-file: string = "/home/jconlon/git/news/docs/index.md"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let link_lines = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-query "publish")
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l| entry-to-markdown $l }
    )

    if ($link_lines | is-empty) {
        error make { msg: "No links returned from database — aborting to protect the news file." }
    }

    let file_lines = (open $news_file | lines)

    let latest_idx = (
        $file_lines
        | enumerate
        | where { |row| $row.item == "### Latest" }
        | first
        | get index
    )

    let next_heading_idx = (
        $file_lines
        | enumerate
        | skip ($latest_idx + 1)
        | where { |row| ($row.item | str starts-with "## ") or ($row.item | str starts-with "### ") }
        | first
        | get index
    )

    let before = ($file_lines | take ($latest_idx + 2))
    let after  = ($file_lines | skip ($next_heading_idx - 1))

    let new_content = ($before | append $link_lines | append "" | append $after | str join "\n") + "\n"

    let byline_date = (date now | format date "%b %d %H:%M")
    let new_byline  = $"**Information Perspectives For ($byline_date)**"
    ($new_content | str replace --regex '\*\*Information Perspectives For [^*]+\*\*' $new_byline)
    | save --force $news_file

    print $"Updated ($news_file) with ($link_lines | length) links and by-line: ($new_byline)."
}

# Build the SELECT query for starred (favorited) entries, deduped by entry
# (v_freshrss_entries has one row per entry/tag pair) and ordered by category
# then date so the caller can group consecutive rows by category.
def freshrss-starred-query [] {
    "SELECT
    title,
    replace(link, '&amp;', '&'),
    to_char(to_timestamp(date), 'Mon DD YYYY'),
    feed_name,
    COALESCE(category_name, ''),
    COALESCE(author, ''),
    COALESCE(
        NULLIF(btrim(replace(replace(NULLIF(entry_attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''),
        NULLIF(btrim(replace(replace(regexp_replace(COALESCE(content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''),
        ''
    )
FROM (
    SELECT DISTINCT ON (entry_id) *
    FROM v_freshrss_entries
    WHERE is_favorite = 1
      AND link IS NOT NULL AND link != ''
) e
ORDER BY category_name NULLS LAST, date DESC;"
}

# Export starred (favorited) FreshRSS entries grouped by category to a standalone
# markdown page — unlike update-news/update-technical, this writes a complete new
# file rather than patching a section of an existing one. is_favorite is left
# untouched, so the page just reflects current favorites on every run.
#
# Usage:
#   ops freshrss update-starred
#
def "main freshrss update-starred" [
    --host (-H): string = "postgresql.verticon.com"
    --news-file: string = "/home/jconlon/git/news/docs/starred.md"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let rows = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-starred-query)
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
    )

    if ($rows | is-empty) {
        error make { msg: "No starred entries returned from database — aborting to protect the starred file." }
    }

    let groups = (
        $rows
        | group-by { |l| let cat = ($l | split row "\t" | get 4); if ($cat | str trim) == "" { "Uncategorized" } else { $cat } }
        | transpose category entries
        | sort-by category
    )

    let sections = (
        $groups
        | each { |g|
            [$"## ($g.category)" ""] | append ($g.entries | each { |l| entry-to-markdown $l }) | append ""
        }
        | flatten
    )

    (["# Starred Articles" ""] | append $sections | str join "\n") + "\n"
    | save --force $news_file

    print $"Wrote ($news_file) with ($rows | length) starred entries across ($groups | length) categories."
}

# Build a markdown list item using freshrss-streams' LLM-generated summary
# bullets (from the Ceph atom-entries bucket) instead of the raw content
# snippet used by entry-to-markdown — the review pipeline's whole point is
# surfacing that enrichment.
def entry-from-avro [avro: record, parts: list] {
    let bullet_items = ($avro.vi_summary_bullets | each { |b| $"    - ($b)" })
    (entry-header-lines $parts | append $bullet_items) | str join "\n"
}

# Export FreshRSS entries tagged 'review' to a standalone markdown page,
# enriched with freshrss-streams' LLM-generated summary bullets where
# available (issue #117).
#
# The 'review' tag itself only exists in FreshRSS's Postgres tag table — it
# is NOT reflected in the atom-entries Avro `categories` field (that field
# only carries feed-provided hashtag categories, confirmed by cross-checking
# live bucket contents). So entry *selection* still goes through Postgres
# (same query shape as update-starred), and the Ceph object store is used
# purely to enrich the selected entries with richer LLM summary bullets in
# place of the raw content snippet, when a matching, fully-processed record
# exists. Falls back to the Postgres-only snippet per entry (or for the
# whole run, if the bucket is unreachable) rather than failing the page.
#
# Usage:
#   ops freshrss update-review
#
def "main freshrss update-review" [
    --host (-H): string = "postgresql.verticon.com"
    --bucket: string = "atom-entries"
    --review-file: string = "/home/jconlon/git/news/docs/review.md"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let rows = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-query "review")
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
    )

    if ($rows | is-empty) {
        error make { msg: "No review-tagged entries returned from database — aborting to protect the review file." }
    }

    # Enrichment is best-effort: read-only reuse of the atom-entries-s3-sink
    # connector's own S3 credentials (kafka-connect-secret, kafka-system) —
    # scoped to this bucket via the CephObjectStoreUser Rook created for it
    # (see docs/object-storage-design.html).
    let tmp_dir = (mktemp -d)
    let enriched_by_link = (
        try {
            let access_key = (^kubectl get secret kafka-connect-secret -n kafka-system -o $"jsonpath={.data.AWS_ACCESS_KEY_ID}" | ^base64 -d | str trim)
            let secret_key = (^kubectl get secret kafka-connect-secret -n kafka-system -o $"jsonpath={.data.AWS_SECRET_ACCESS_KEY}" | ^base64 -d | str trim)

            with-env { MC_HOST_atomentries: $"https://($access_key):($secret_key)@s3.verticon.com" } {
                ^mc mirror --quiet $"atomentries/($bucket)/" $tmp_dir o> /dev/null
            }

            let links = ($rows | each { |l| $l | split row "\t" | get 1 })
            let matched = (
                ($links | str join "\n")
                | ^python3 scripts/decode_atom_entries.py $tmp_dir
                | from json
            )

            ($matched | reduce -f {} { |r, acc| $acc | insert $r.id $r })
        } catch { |e|
            print $"WARN  could not read atom-entries bucket \(($e.msg)\) — falling back to Postgres content only."
            {}
        }
    )
    rm -r $tmp_dir

    let entries = (
        $rows
        | each { |l|
            let parts = ($l | split row "\t")
            let link  = ($parts | get 1)
            let avro  = ($enriched_by_link | get $link -i)
            if ($avro != null) and ($avro.vi_summary_status == "processed") and (($avro.vi_summary_bullets | length) > 0) {
                entry-from-avro $avro $parts
            } else {
                entry-to-markdown $l
            }
        }
    )

    (["# Review" ""] | append $entries | str join "\n") + "\n"
    | save --force $review_file

    let enriched_count = (
        $rows
        | where { |l| ($enriched_by_link | get ($l | split row "\t" | get 1) -i) != null }
        | length
    )
    print $"Wrote ($review_file) with ($rows | length) review entries \(($enriched_count) enriched from atom-entries\)."
}

# Query FreshRSS entries tagged 'publish' and output a markdown link list.
#
# Connects directly to postgresql.verticon.com, runs the publish query via
# v_freshrss_entries, and prints results as a markdown list.
#
# Usage:
#   ops freshrss publish-links
#
def "main freshrss publish-links" [
    --host (-H): string = "postgresql.verticon.com"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let markdown = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-query "publish")
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l| entry-to-markdown $l }
        | str join "\n"
    )

    print $markdown
}

# Build the SELECT query for RSS feed generation (publish tag, RFC 822 dates, limited to 50 items).
def freshrss-rss-query [] {
    "SELECT
    title,
    replace(link, '&amp;', '&'),
    to_char(to_timestamp(date) AT TIME ZONE 'UTC', 'Dy, DD Mon YYYY HH24:MI:SS') || ' +0000',
    feed_name,
    COALESCE(category_name, ''),
    COALESCE(
        NULLIF(btrim(replace(replace(NULLIF(entry_attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''),
        NULLIF(btrim(replace(replace(regexp_replace(COALESCE(content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''),
        ''
    )
FROM v_freshrss_entries
WHERE tag_name = 'publish'
  AND link IS NOT NULL AND link != ''
ORDER BY date DESC
LIMIT 50;"
}

# Convert a raw tab-separated entry row into an RSS <item> XML string.
def entry-to-rss-item [l: string] {
    let parts = ($l | split row "\t")
    let title = ($parts | get 0)
        | str replace --all --regex '\|\|.*$' ''
        | str replace --all --regex ' • From .*$' ''
        | str trim
        | str replace --all '&amp;' '&'
        | str replace --all '&lt;'  '<'
        | str replace --all '&gt;'  '>'
        | str replace --all '&'     '&amp;'
        | str replace --all '<'     '&lt;'
        | str replace --all '>'     '&gt;'
    let link    = ($parts | get 1) | str replace --all '&' '&amp;'
    let pubdate = ($parts | get 2)
    let feed    = ($parts | get 3)
    let raw_snip = (if ($parts | length) > 5 { $parts | get 5 } else { "" })

    let snip = ($raw_snip
        | str replace --all '|||' ' '
        | str trim)

    let desc_text = if ($snip | str trim) != "" { $snip } else { $feed }

    $"    <item>
      <title>($title)</title>
      <link>($link)</link>
      <guid>($link)</guid>
      <pubDate>($pubdate)</pubDate>
      <category>($feed)</category>
      <description><![CDATA[($desc_text)]]></description>
    </item>"
}

# Generate an RSS 2.0 feed from FreshRSS 'publish'-tagged entries and write to feed.xml.
#
# Connects directly to postgresql.verticon.com, queries the 50 most recent published
# entries, and writes a valid RSS 2.0 feed to the news docs directory for deployment
# at https://verticon.com/news/feed.xml.
#
# Usage:
#   ops freshrss update-feed
#
def "main freshrss update-feed" [
    --host (-H): string = "postgresql.verticon.com"
    --feed-file: string = "/home/jconlon/git/news/docs/feed.xml"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let items = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -F (char tab) -c (freshrss-rss-query)
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l| entry-to-rss-item $l }
    )

    if ($items | is-empty) {
        error make { msg: "No entries returned from database — aborting to protect the feed file." }
    }

    let now = (date now | format date "%a, %d %b %Y %H:%M:%S %z")
    let items_xml = ($items | str join "\n")

    let feed = $"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">
  <channel>
    <title>Condor Research Network</title>
    <link>https://verticon.com/news/</link>
    <description>Information Perspectives — curated news and analysis</description>
    <atom:link href=\"https://verticon.com/news/feed.xml\" rel=\"self\" type=\"application/rss+xml\"/>
    <lastBuildDate>($now)</lastBuildDate>
    <language>en-us</language>
($items_xml)
  </channel>
</rss>
"

    $feed | save --force $feed_file
    print $"Updated ($feed_file) with ($items | length) items."
}

# Connect to the FreshRSS PostgreSQL database via psql.
#
# Connects directly to the external PostgreSQL readonly replica at
# postgresql.verticon.com using credentials from the cluster secret.
#
# Usage:
#   ops freshrss psql
#
def "main freshrss psql" [
    --host (-H): string = "postgresql.verticon.com"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    print "Connecting to freshrss database..."

    with-env { PGPASSWORD: $password } {
        ^psql -h $host -p 5432 -U freshrss -d freshrss
    }
}
