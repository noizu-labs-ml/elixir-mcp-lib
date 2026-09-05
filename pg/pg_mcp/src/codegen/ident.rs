//! §4.5 identifier rules (PRD-8, normative): MCP names → valid Postgres
//! identifiers, deterministically, with recovery of the original name kept in
//! the table option (`tool '…'`).
//!
//! The pipeline ([`derive`]) is: camelCase/PascalCase split → lowercase →
//! every character outside `[a-z0-9_]` becomes `_` → runs of `_` collapse →
//! leading/trailing `_` stripped → leading digit gets a `_` prefix → the
//! `prefix` option is prepended → 63-byte enforcement (truncate the derived
//! name to 55 bytes, suffix `_` + 7 hex of SHA-256 over the pre-truncation
//! name) → collision suffixing ([`dedup`], same hash over the *original*
//! name).
//!
//! SHA-256 is implemented here rather than pulled in as a dependency: the
//! suffix is the only consumer, and ADR-002 keeps the crate's dependency set
//! deliberate. The implementation is the FIPS 180-4 algorithm, unmodified.
//!
//! Reserved words are never renamed (§4.5 rule 3) — the DDL emitters quote
//! every identifier unconditionally, which satisfies the rule; [`is_reserved`]
//! exists for tests and for callers that must know.

use std::collections::HashMap;

/// Postgres identifier limit: `NAMEDATALEN - 1`.
const MAX_BYTES: usize = 63;
/// Truncation target before the hash suffix is appended (§4.5 rule 4).
const TRUNCATE_BYTES: usize = 55;
/// Hex characters in the suffix.
const SUFFIX_HEX: usize = 7;

/// Derive a SQL identifier from an MCP name (§4.5 rules 1-2, 4, 6).
///
/// `prefix` is prepended before the length rule applies (rule 6). The output
/// is always a valid, ≤63-byte, unquoted identifier: `[a-z0-9_]`, never
/// starting with a digit.
pub fn derive(name: &str, prefix: &str) -> String {
    let base = derive_base(name);

    let mut composed = if prefix.is_empty() {
        base
    } else {
        format!("{}{}", prefix, base)
    };

    if composed.len() > MAX_BYTES {
        // The derived name is pure ASCII (`[a-z0-9_]` + the prefix, which the
        // caller validates down to the same class), so byte truncation cannot
        // split a character. The hash covers the *pre-truncation* name, which
        // includes the prefix (rule 6 orders the prefix before rule 4).
        let mut truncated: String = composed[..TRUNCATE_BYTES].to_string();
        truncated.push('_');
        truncated.push_str(&sha256_hex7(composed.as_bytes()));
        composed = truncated;
    }
    debug_assert!(composed.len() <= MAX_BYTES);
    composed
}

/// Rules 1-2: derive the base identifier, without prefix or length handling.
fn derive_base(name: &str) -> String {
    let split = split_case_boundaries(name);
    let lowered = split.to_lowercase();
    let mut out = String::with_capacity(lowered.len());
    let mut last_was_underscore = false;
    for c in lowered.chars() {
        let keep = c.is_ascii_lowercase() || c.is_ascii_digit();
        if keep {
            out.push(c);
            last_was_underscore = false;
        } else if !last_was_underscore && !out.is_empty() {
            out.push('_');
            last_was_underscore = true;
        }
        // Leading separators and runs are dropped here; leading digits are
        // fixed below once the string is final.
    }
    while out.starts_with('_') {
        out.remove(0);
    }
    while out.ends_with('_') {
        out.pop();
    }
    if out.as_bytes().first().is_some_and(u8::is_ascii_digit) {
        out.insert(0, '_');
    }
    out
}

/// Insert `_` at case boundaries — lower→upper, and the last upper of an
/// acronym run that meets a lower (`getHTTPResponse` → `get_http_response`).
fn split_case_boundaries(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::with_capacity(name.len() + 8);
    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            let boundary = (prev.is_ascii_lowercase() && c.is_ascii_uppercase())
                || (prev.is_ascii_uppercase()
                    && c.is_ascii_uppercase()
                    && chars.get(i + 1).is_some_and(|n| n.is_ascii_lowercase()))
                || (prev.is_ascii_digit() && c.is_ascii_uppercase());
            if boundary {
                out.push('_');
            }
        }
        out.push(c);
    }
    out
}

/// Rules 5+6: resolve collisions after [`derive`], under `prefix`. The first
/// name keeps its derived identifier; each subsequent name with the same
/// identifier gets `_` + 7 hex of the SHA-256 of *its* original name, applied
/// after truncation so the result stays ≤63 bytes. Input order decides who
/// wins.
pub fn dedup<I>(names: I, prefix: &str) -> Vec<(String, String)>
where
    I: IntoIterator,
    I::Item: AsRef<str>,
{
    let names: Vec<String> = names.into_iter().map(|n| n.as_ref().to_string()).collect();
    let derived: Vec<String> = names.iter().map(|n| derive(n, prefix)).collect();

    let mut seen: HashMap<&str, usize> = HashMap::new();
    let mut out = Vec::with_capacity(names.len());
    for (original, sql) in names.iter().zip(derived.iter()) {
        if seen.insert(sql.as_str(), out.len()).is_none() {
            out.push((original.clone(), sql.clone()));
        } else {
            // Collision: hash the original name, after truncation (the
            // derived name is already prefixed and ≤63 bytes, so trimming to
            // 55 leaves room for the suffix).
            let mut suffixed = sql[..sql.len().min(TRUNCATE_BYTES)].to_string();
            suffixed.push('_');
            suffixed.push_str(&sha256_hex7(original.as_bytes()));
            out.push((original.clone(), suffixed));
        }
    }
    out
}

/// Rule 3: is this name a PostgreSQL *reserved* keyword (Appendix C's
/// "reserved" column — the class that cannot appear unquoted anywhere)?
/// The emitters quote unconditionally, so this is an assertion helper, not a
/// transformation.
pub fn is_reserved(name: &str) -> bool {
    const RESERVED: &[&str] = &[
        "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "asymmetric", "both",
        "binary", "case", "cast", "check", "collate", "collation", "column", "concurrently",
        "constraint", "create", "current_catalog", "current_date", "current_role", "current_time",
        "current_timestamp", "current_user", "default", "deferrable", "desc", "distinct", "do",
        "else", "end", "except", "false", "fetch", "filter", "for", "foreign", "freeze", "from",
        "full", "grant", "group", "having", "ilike", "in", "initially", "inner", "intersect",
        "into", "is", "isnull", "join", "lateral", "leading", "left", "like", "limit",
        "localtime", "localtimestamp", "natural", "not", "notnull", "null", "offset", "on",
        "only", "or", "order", "outer", "overlaps", "placing", "primary", "references",
        "returning", "right", "select", "session_user", "similar", "some", "symmetric", "table",
        "tablesample", "then", "to", "trailing", "true", "union", "unique", "user", "using",
        "variadic", "verbose", "when", "where", "window", "with",
    ];
    RESERVED.binary_search(&name).is_ok()
}

/// The first 7 hex characters of the SHA-256 of `bytes`.
fn sha256_hex7(bytes: &[u8]) -> String {
    let digest = sha256(bytes);
    digest
        .iter()
        .take(4) // 4 bytes = 8 hex; slice to 7 below
        .map(|b| format!("{b:02x}"))
        .collect::<String>()[..SUFFIX_HEX]
        .to_string()
}

/// The 7-hex collision/truncation suffix for an original MCP name. Public so
/// the planner can suffix colliding *column* names within one tool's schema
/// (§4.5 rule 5 applied at property granularity).
pub fn sha_suffix(original: &str) -> String {
    sha256_hex7(original.as_bytes())
}

/// SHA-256 (FIPS 180-4). Minimal, allocation-free over the input via padding.
fn sha256(message: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    // Padding: message + 0x80 + zeros + 64-bit big-endian bit length, to a
    // multiple of 64 bytes.
    let bit_len = (message.len() as u64).wrapping_mul(8);
    let padded_len = ((message.len() + 9 + 63) / 64) * 64;
    let mut block = vec![0u8; padded_len];
    block[..message.len()].copy_from_slice(message);
    block[message.len()] = 0x80;
    block[padded_len - 8..].copy_from_slice(&bit_len.to_be_bytes());

    let mut w = [0u32; 64];
    for chunk in block.chunks_exact(64) {
        for (i, word) in w.iter_mut().take(16).enumerate() {
            *word = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut digest = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        digest[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    digest
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    /// Rules 1-2: derivation, camelCase splitting, separators, whitespace.
    #[pgrx::pg_test]
    fn derivation_rules_split_case_and_strip_separators() {
        assert_eq!(derive("search_docs", ""), "search_docs");
        assert_eq!(derive("searchDocs", ""), "search_docs");
        assert_eq!(derive("SearchDocs", ""), "search_docs");
        assert_eq!(derive("getHTTPResponse", ""), "get_http_response");
        assert_eq!(derive("HTTPServer", ""), "http_server");
        assert_eq!(derive("get2fa", ""), "get2fa");
        // Digits are not case boundaries (§4.5 splits case only); the
        // Update boundary still splits.
        assert_eq!(derive("version2Update", ""), "version2_update");
        // Non-identifier characters collapse to single underscores.
        assert_eq!(derive("search-docs.v2", ""), "search_docs_v2");
        assert_eq!(derive("  spaced  name  ", ""), "spaced_name");
        assert_eq!(derive("we!rd@@name", ""), "we_rd_name");
        // Unicode lowercases then falls outside the class.
        assert_eq!(derive("École", ""), "cole");
        assert_eq!(derive("日本語", ""), "");
        // Leading digits get the underscore prefix (rule 2).
        assert_eq!(derive("2fa_check", ""), "_2fa_check");
        assert_eq!(derive("42", ""), "_42");
        // Runs of separators collapse; leading/trailing never survive.
        assert_eq!(derive("--a___b--", ""), "a_b");
        // The empty derivation is still a valid (if dull) identifier.
        assert_eq!(derive("###", ""), "");
    }

    /// Rule 6: the prefix composes before the length rule.
    #[pgrx::pg_test]
    fn prefix_is_prepended_and_counts_toward_the_length_rule() {
        assert_eq!(derive("search_docs", "mcp_"), "mcp_search_docs");
        assert_eq!(derive("searchDocs", "npl_"), "npl_search_docs");
    }

    /// Rule 3 + AC-8.7: reserved words survive verbatim (the emitters quote).
    #[pgrx::pg_test]
    fn reserved_words_are_recognized_and_survive_unrenamed() {
        assert_eq!(derive("limit", ""), "limit");
        assert_eq!(derive("select", ""), "select");
        assert_eq!(derive("LIMIT", ""), "limit");
        assert!(is_reserved("limit"));
        assert!(is_reserved("select"));
        assert!(!is_reserved("search_docs"));
    }

    /// Rule 4 + AC-8.8: a 70-character name yields exactly 63 bytes ending in
    /// `_` + 7 hex, identical across runs (fixed vector).
    #[pgrx::pg_test]
    fn long_names_truncate_to_63_bytes_with_a_deterministic_hash_suffix() {
        let long = "a_very_long_tool_name_that_goes_on_and_on_until_it_passes_the_sixty_three_byte_limit";
        assert_eq!(long.len(), 84);
        let derived = derive(long, "");
        assert_eq!(derived.len(), 63, "byte length is the identifier limit");
        // Structure: 55 bytes of derived content, then `_`, then 7 hex.
        let (head, tail) = derived.split_at(55);
        let tail = tail.strip_prefix('_').unwrap();
        assert_eq!(head, &long[..55].to_lowercase());
        assert_eq!(tail.len(), 7);
        assert!(tail.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        // The fixed vector: identical across runs and machines (AC-8.8).
        assert_eq!(derived, format!("{}{}", &long[..55].to_lowercase(), {
            let h = sha256_hex7(long.to_lowercase().as_bytes());
            format!("_{h}")
        }));
        // Deterministic across calls.
        assert_eq!(derive(long, ""), derive(long, ""));
    }

    #[pgrx::pg_test]
    fn prefix_applied_names_also_respect_the_63_byte_limit() {
        let long = "search_docs_with_an_extremely_long_descriptive_name_that_will_not_fit";
        let derived = derive(long, "npl_");
        assert!(derived.len() <= 63);
        assert!(derived.starts_with("npl_"));
    }

    /// Rule 5 + AC-8.9: collisions get deterministic per-original suffixes.
    #[pgrx::pg_test]
    fn colliding_names_get_deterministic_distinct_suffixes() {
        // Both derive to `a_b`.
        let out = dedup(["a-b", "a_b", "a.b"], "");
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].1, "a_b", "the first occurrence keeps the plain name");
        let second = &out[1].1;
        let third = &out[2].1;
        assert_ne!(second, third, "every colliding tool gets its own name");
        for (_, sql) in &out {
            assert!(sql.len() <= 63);
        }
        // Suffixes hash the *original* name: `a_b`'s suffix is sha256("a_b")[..7].
        assert_eq!(
            second,
            &format!("a_b_{}", sha256_hex7(b"a_b")),
            "second occurrence suffixes with its own original name's hash"
        );
        assert_eq!(
            third,
            &format!("a_b_{}", sha256_hex7(b"a.b"))
        );
        // Deterministic and order-stable.
        assert_eq!(dedup(["a-b", "a_b"], ""), out[..2].to_vec());
        // No collision, no suffix.
        assert_eq!(dedup(["one", "two"], "").iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>(), vec!["one", "two"]);

        // Prefix composes with collision handling (rules 5+6 together).
        let out = dedup(["a-b", "a_b"], "p_");
        assert_eq!(out[0].1, "p_a_b");
        assert_eq!(out[1].1, format!("p_a_b_{}", sha256_hex7(b"a_b")));
    }

    /// §7.1: a property test over hostile names — the output is always a
    /// valid, ≤63-byte Postgres identifier.
    #[pgrx::pg_test]
    fn hostile_names_always_produce_valid_identifiers() {
        let hostile = [
            "github.create_issue",
            "UPPER", "lower", "MiXeD case", "tabs\tand\nnewlines",
            "emoji🚀rocket", "null\0byte", "quote\"name", "dollar$sign",
            "0", "_leading_underscore", "trailing_", "a", "", "  ",
            "engine.upstream.very.long.name.chain.that.keeps.going.and.going",
            &"x".repeat(200),
        ];
        for name in hostile {
            let derived = derive(name, "p_");
            assert!(derived.len() <= 63, "{name:?} → {} bytes", derived.len());
            assert!(!derived.is_empty(), "{name:?} must not derive to empty under a prefix");
            assert!(
                derived
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
                "{name:?} → {derived:?} is not in [a-z0-9_]"
            );
            assert!(
                !derived.as_bytes()[0].is_ascii_digit(),
                "{name:?} → {derived:?} starts with a digit"
            );
        }
    }

    /// The SHA-256 implementation against FIPS 180-4's published vectors.
    #[pgrx::pg_test]
    fn sha256_matches_the_published_test_vectors() {
        let of = |s: &str| sha256(s.as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(
            of(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            of("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            of("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        // > one block, exercising the multi-chunk path.
        assert_eq!(
            of(&"a".repeat(1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }
}
