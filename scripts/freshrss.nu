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

# Convert a raw tab-separated entry row into a formatted markdown list item string.
def entry-to-markdown [l: string] {
    let parts = ($l | split row "\t")
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

    let author_display = if ($author == $feed) { "" } else { $author }
    let meta       = ([$feed, $cat, $author_display] | filter { |p| ($p | str trim) != "" } | str join " | ")
    let snip_items = ($snip_lines | each { |s| $"    - ($s)" })
    let base       = [$"- [($title)]\(($link)\) — ($date)"]
    let with_meta  = if ($meta | str trim) != "" { $base | append $"    - ($meta)" } else { $base }
    ($with_meta | append $snip_items) | str join "\n"
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
