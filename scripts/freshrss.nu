#!/usr/bin/env nu

# Connect to the FreshRSS PostgreSQL database via psql
#
# Connects directly to the external PostgreSQL readonly replica at
# postgresql.verticon.com using credentials from the cluster secret.
#
# Usage:
#   ops freshrss psql
#
# Query FreshRSS entries tagged 'publish' and output a markdown link list
#
# Connects directly to postgresql.verticon.com, runs the publish query,
# and prints results as a markdown list of links with tags.
#
# Usage:
#   ops freshrss publish-links
#
def "main freshrss update-technical" [
    --host (-H): string = "postgresql.verticon.com"
    --news-file: string = "/home/jconlon/git/news/docs/index.md"
] {
    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    let sql = "SELECT btrim(regexp_replace(regexp_replace(e.title, '\\|\\|.*$', ''), ' • From .*$', '')) || chr(9) || replace(e.link, '&amp;', '&') || chr(9) || to_char(to_timestamp(e.date), 'Mon DD YYYY') || chr(9) || f.name || chr(9) || COALESCE(c.name, '') || chr(9) || COALESCE(ltrim(e.author, ';'), '') || chr(9) || COALESCE(NULLIF(btrim(replace(replace(NULLIF(e.attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''), NULLIF(btrim(replace(replace(regexp_replace(COALESCE(e.content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''), '')
FROM public.freshrss_admin_entry AS e
JOIN public.freshrss_admin_entrytag AS et_publish ON et_publish.id_entry = e.id
JOIN public.freshrss_admin_tag AS t_publish ON t_publish.id = et_publish.id_tag AND t_publish.name = 'technical'
JOIN public.freshrss_admin_feed AS f ON f.id = e.id_feed
LEFT JOIN public.freshrss_admin_category AS c ON c.id = f.category
WHERE e.link IS NOT NULL AND e.link != ''
ORDER BY e.date DESC;"

    let link_lines = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -c $sql
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l|
            let parts    = ($l | split row "\t")
            let title    = ($parts | get 0) | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
            let link     = ($parts | get 1)
            let date     = ($parts | get 2)
            let feed     = ($parts | get 3)
            let cat      = ($parts | get 4)
            let author   = ($parts | get 5)
            let raw_snip  = (if ($parts | length) > 6 { $parts | get 6 } else { "" })
            let snip_lines = if ($raw_snip | str trim) != "" {
                ($raw_snip
                    | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
                    | split row "|||"
                    | filter { |line|
                        let t = ($line | str trim)
                        ($t | str length) > 15 and not ($t | str ends-with ":") and not ($t =~ '(?i)^(#|http|\*\*|Full video:|Follow |Via:|Support |Substack:|Cashapp:|Venmo:|PayPal:|estimated reading time|.*Merch:)') and not ($t =~ 'https?://') and not ($t =~ '\w+\.\w+/')
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
            let with_snip  = ($with_meta | append $snip_items)
            $with_snip | str join "\n"
        }
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

    let new_content = ($before | append $link_lines | append "" | append $after | str join "\n") + "\n"

    $new_content | save --force $news_file
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

    let sql = "SELECT btrim(regexp_replace(regexp_replace(e.title, '\\|\\|.*$', ''), ' • From .*$', '')) || chr(9) || replace(e.link, '&amp;', '&') || chr(9) || to_char(to_timestamp(e.date), 'Mon DD YYYY') || chr(9) || f.name || chr(9) || COALESCE(c.name, '') || chr(9) || COALESCE(ltrim(e.author, ';'), '') || chr(9) || COALESCE(NULLIF(btrim(replace(replace(NULLIF(e.attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''), NULLIF(btrim(replace(replace(regexp_replace(COALESCE(e.content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''), '')
FROM public.freshrss_admin_entry AS e
JOIN public.freshrss_admin_entrytag AS et_publish ON et_publish.id_entry = e.id
JOIN public.freshrss_admin_tag AS t_publish ON t_publish.id = et_publish.id_tag AND t_publish.name = 'publish'
JOIN public.freshrss_admin_feed AS f ON f.id = e.id_feed
LEFT JOIN public.freshrss_admin_category AS c ON c.id = f.category
WHERE e.link IS NOT NULL AND e.link != ''
ORDER BY e.date DESC;"

    let link_lines = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -c $sql
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l|
            let parts    = ($l | split row "\t")
            let title    = ($parts | get 0) | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
            let link     = ($parts | get 1)
            let date     = ($parts | get 2)
            let feed     = ($parts | get 3)
            let cat      = ($parts | get 4)
            let author   = ($parts | get 5)
            let raw_snip  = (if ($parts | length) > 6 { $parts | get 6 } else { "" })
            let snip_lines = if ($raw_snip | str trim) != "" {
                ($raw_snip
                    | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
                    | split row "|||"
                    | filter { |line|
                        let t = ($line | str trim)
                        ($t | str length) > 15 and not ($t | str ends-with ":") and not ($t =~ '(?i)^(#|http|\*\*|Full video:|Follow |Via:|Support |Substack:|Cashapp:|Venmo:|PayPal:|estimated reading time|.*Merch:)') and not ($t =~ 'https?://') and not ($t =~ '\w+\.\w+/')
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
            let with_snip  = ($with_meta | append $snip_items)
            $with_snip | str join "\n"
        }
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
    let new_byline = $"**Information Perspectives For ($byline_date)**"
    let final_content = ($new_content | str replace --regex '\*\*Information Perspectives For [^*]+\*\*' $new_byline)

    $final_content | save --force $news_file
    print $"Updated ($news_file) with ($link_lines | length) links and by-line: ($new_byline)."
}

# Query FreshRSS entries tagged 'publish' and output a markdown link list
#
# Connects directly to postgresql.verticon.com, runs the publish query,
# and prints results as a markdown list of links with tags.
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

    let sql = "SELECT btrim(regexp_replace(regexp_replace(e.title, '\\|\\|.*$', ''), ' • From .*$', '')) || chr(9) || replace(e.link, '&amp;', '&') || chr(9) || to_char(to_timestamp(e.date), 'Mon DD YYYY') || chr(9) || f.name || chr(9) || COALESCE(c.name, '') || chr(9) || COALESCE(ltrim(e.author, ';'), '') || chr(9) || COALESCE(NULLIF(btrim(replace(replace(NULLIF(e.attributes, '')::json->'enclosures'->0->>'description', chr(13), ''), chr(10), '|||')), ''), NULLIF(btrim(replace(replace(regexp_replace(COALESCE(e.content, ''), '<[^>]+>', '', 'g'), chr(13), ''), chr(10), '|||')), ''), '')
FROM public.freshrss_admin_entry AS e
JOIN public.freshrss_admin_entrytag AS et_publish ON et_publish.id_entry = e.id
JOIN public.freshrss_admin_tag AS t_publish ON t_publish.id = et_publish.id_tag AND t_publish.name = 'publish'
JOIN public.freshrss_admin_feed AS f ON f.id = e.id_feed
LEFT JOIN public.freshrss_admin_category AS c ON c.id = f.category
WHERE e.link IS NOT NULL AND e.link != ''
ORDER BY e.date DESC;"

    let markdown = (
        with-env { PGPASSWORD: $password } {
            ^psql -h $host -p 5432 -U freshrss -d freshrss -t -A -c $sql
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l|
            let parts    = ($l | split row "\t")
            let title    = ($parts | get 0) | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
            let link     = ($parts | get 1)
            let date     = ($parts | get 2)
            let feed     = ($parts | get 3)
            let cat      = ($parts | get 4)
            let author   = ($parts | get 5)
            let raw_snip  = (if ($parts | length) > 6 { $parts | get 6 } else { "" })
            let snip_lines = if ($raw_snip | str trim) != "" {
                ($raw_snip
                    | str replace --all '&amp;' '&' | str replace --all '&lt;' '<' | str replace --all '&gt;' '>'
                    | split row "|||"
                    | filter { |line|
                        let t = ($line | str trim)
                        ($t | str length) > 15 and not ($t | str ends-with ":") and not ($t =~ '(?i)^(#|http|\*\*|Full video:|Follow |Via:|Support |Substack:|Cashapp:|Venmo:|PayPal:|estimated reading time|.*Merch:)') and not ($t =~ 'https?://') and not ($t =~ '\w+\.\w+/')
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
            let with_snip  = ($with_meta | append $snip_items)
            $with_snip | str join "\n"
        }
        | str join "\n"
    )

    print $markdown
}

# Connect to the FreshRSS PostgreSQL database via psql
#
# Connects directly to the external PostgreSQL readonly replica at
# postgresql.verticon.com using credentials from the cluster secret.
#
# Usage:
#   ops freshrss psql
#
# Example:
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
