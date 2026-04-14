-- FreshRSS entries view
--
-- Exposes all columns from freshrss_admin_entry (raw, untrimmed) joined with
-- feed, category, and tag tables.
--
-- One row per (entry, tag) pair — an entry with multiple tags appears multiple times.
--
-- Usage:
--   SELECT * FROM v_freshrss_entries WHERE tag_name = 'publish' ORDER BY date DESC;
--
-- Recreate:
--   psql -h postgresql.verticon.com -p 5432 -U freshrss -d freshrss -f scripts/sql/v_freshrss_entries.sql

CREATE OR REPLACE VIEW v_freshrss_entries AS
SELECT
    -- Entry columns (raw, untrimmed)
    e.id                        AS entry_id,
    e.guid,
    e.title,
    e.author,
    e.content,
    e.link,
    e.date,
    e."lastSeen"                AS last_seen,
    e."lastUserModified"        AS last_user_modified,
    e.hash,
    e.is_read,
    e.is_favorite,
    e.id_feed,
    e.tags                      AS entry_tags,
    e.attributes                AS entry_attributes,
    -- Feed columns
    f.id                        AS feed_id,
    f.name                      AS feed_name,
    f.url                       AS feed_url,
    f.website                   AS feed_website,
    f.description               AS feed_description,
    f."lastUpdate"              AS feed_last_update,
    f.kind                      AS feed_kind,
    f.priority                  AS feed_priority,
    f.error                     AS feed_error,
    f.ttl                       AS feed_ttl,
    f.attributes                AS feed_attributes,
    -- Category columns
    c.id                        AS category_id,
    c.name                      AS category_name,
    c.kind                      AS category_kind,
    c.attributes                AS category_attributes,
    -- Tag columns
    t.id                        AS tag_id,
    t.name                      AS tag_name,
    t.attributes                AS tag_attributes
FROM public.freshrss_admin_entry AS e
JOIN      public.freshrss_admin_feed     AS f  ON f.id       = e.id_feed
LEFT JOIN public.freshrss_admin_category AS c  ON c.id       = f.category
LEFT JOIN public.freshrss_admin_entrytag AS et ON et.id_entry = e.id
LEFT JOIN public.freshrss_admin_tag      AS t  ON t.id       = et.id_tag;
