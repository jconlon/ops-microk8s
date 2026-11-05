#!/usr/bin/env nu

# Apicurio Registry, Confluent-compatible API (replaced Confluent Schema Registry)
const SCHEMA_REGISTRY_URL = "https://schema-registry.verticon.com/apis/ccompat/v6"

# List all registered schema subjects
#
# Usage:
#   ops kafka schema-list
#
# Example output:
#   ╭───┬──────────────────────────────────╮
#   │ # │             subject              │
#   ├───┼──────────────────────────────────┤
#   │ 0 │ atom.entries-value      │
#   ╰───┴──────────────────────────────────╯
#
def "main kafka schema-list" [] {
    http get $"($SCHEMA_REGISTRY_URL)/subjects"
    | each { |s| { subject: $s } }
}

# Show the latest schema for a subject
#
# Usage:
#   ops kafka schema-get <subject>
#
# Parameters:
#   subject: string  — Schema subject name (e.g. "atom.entries-value")
#
def "main kafka schema-get" [
    subject: string  # Schema subject name
] {
    let result = (http get $"($SCHEMA_REGISTRY_URL)/subjects/($subject)/versions/latest")
    {
        subject:    $result.subject
        version:    $result.version
        schema_id:  $result.id
        schema:     ($result.schema | from json)
    }
}

# List all versions for a schema subject
#
# Usage:
#   ops kafka schema-versions <subject>
#
def "main kafka schema-versions" [
    subject: string  # Schema subject name
] {
    http get $"($SCHEMA_REGISTRY_URL)/subjects/($subject)/versions"
    | each { |v| { version: $v } }
}

# Show Schema Registry global config and compatibility level
#
# Usage:
#   ops kafka schema-config
#
def "main kafka schema-config" [] {
    http get $"($SCHEMA_REGISTRY_URL)/config"
}
