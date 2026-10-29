// Test oracle: JSFuck 0.5.0 encoder, ported verbatim from
// hhfkbeloejjheeiihhjndfcogjhejoek/test/fixtures/jsfuck-encoder.js so the
// decode tests exercise the same byte shapes the vendored web library
// produces. This mirrors the JS suite, which loads the fixture and calls
// JSFuck.encode() — the encoder belongs to the test rig, not the engine.

use std::collections::HashSet;
use std::sync::LazyLock;
const MIN: u32 = 32;
const MAX: u32 = 126;

const SIMPLE: [(&str, &str); 5] = [
    ("false", "![]"),
    ("true", "!![]"),
    ("undefined", "[][[]]"),
    ("NaN", "+[![]]"),
    (
        "Infinity",
        "+(+!+[]+(!+[]+[])[!+[]+!+[]+!+[]]+[+!+[]]+[+[]]+[+[]]+[+[]])",
    ),
];

// Regex metacharacters the fixture escapes when building the unmapped class.
const META: &[char] = &[
    '.', '*', '+', '?', '^', '$', '{', '}', '(', ')', '|', '[', ']', '\\',
];

// Declaration order is preserved: digits first (integer keys sort first in
// JS for-in), then the literal order — the unmapped character class and the
// missing-char passes both walk this order.

struct Encoder {
    mapping: Vec<(char, Option<String>)>,
}

fn build_encoder() -> Encoder {
    let mut mapping: Vec<(char, Option<String>)> = Vec::new();
    // Integer keys first (JS for-in order), then the declared string keys.
    for d in '0'..='9' {
        mapping.push((d, None)); // filled by fill_missing_digits below
    }
    let declared: Vec<(char, Option<&str>)> = declared_mapping();
    for (c, v) in declared {
        mapping.push((c, v.map(|s| s.to_string())));
    }
    fill_missing_digits(&mut mapping);
    replace_map(&mut mapping);
    replace_strings(&mut mapping);
    Encoder { mapping }
}

fn declared_mapping() -> Vec<(char, Option<&'static str>)> {
    let mut rows: Vec<(char, Option<&str>)> = Vec::new();
    let lower = [
        "(false+\"\")[1]", "([][\"entries\"]()+\"\")[2]", "([][\"at\"]+\"\")[3]", "(undefined+\"\")[2]",
        "(true+\"\")[3]", "(false+\"\")[0]", "(false+[0]+String)[20]",
        "(+(101))[\"to\"+String[\"name\"]](21)[1]", "([false]+undefined)[10]",
        "([][\"entries\"]()+\"\")[3]", "(+(20))[\"to\"+String[\"name\"]](21)", "(false+\"\")[2]",
        "(Number+\"\")[11]", "(undefined+\"\")[1]", "(true+[][\"at\"])[10]",
        "(+(211))[\"to\"+String[\"name\"]](31)[1]", "(\"\")[\"fontcolor\"]([0]+false+\")[20]",
        "(true+\"\")[1]", "(false+\"\")[3]", "(true+\"\")[0]", "(undefined+\"\")[0]",
        "(+(31))[\"to\"+String[\"name\"]](32)", "(+(32))[\"to\"+String[\"name\"]](33)",
        "(+(101))[\"to\"+String[\"name\"]](34)[1]", "(NaN+[Infinity])[10]",
        "(+(35))[\"to\"+String[\"name\"]](36)",
    ];
    for (i, v) in lower.iter().enumerate() {
        rows.push(((b'a' + i as u8) as char, Some(*v)));
    }
    let upper_values: [Option<&str>; 26] = [
        Some("(NaN+[][\"entries\"]())[11]"),
        Some("(+[]+Boolean)[10]"),
        Some("Function(\"return escape\")()((\"\")[\"italics\"]())[2]"),
        Some("Function(\"return escape\")()([][\"at\"])[\"at\"](\"-1\")"),
        Some("(RegExp+\"\")[12]"),
        Some("(+[]+Function)[10]"),
        Some("(false+Function(\"return Date\")()())[30]"),
        None, None, None, None, None, // H I J K L
        Some("(true+Function(\"return Date\")()())[30]"),
        Some("(NaN+\"\")[0]"),
        None, None, None, // O P Q
        Some("(+[]+RegExp)[10]"),
        Some("(+[]+String)[10]"),
        Some("(NaN+Function(\"return Date\")()())[30]"),
        None, None, None, None, None, None, // U V W X Y Z
    ];
    for (i, v) in upper_values.iter().enumerate() {
        rows.push(((b'A' + i as u8) as char, *v));
    }
    let punct: [(char, Option<&str>); 33] = [
        (' ', Some("(NaN+[][\"at\"])[11]")),
        ('!', None),
        ('"', Some("(\"\")[\"fontcolor\"]()[12]")),
        ('#', None),
        ('$', None),
        ('%', Some("Function(\"return escape\")()([][\"at\"])[22]")),
        ('&', Some("(\"\")[\"fontcolor\"](\")[13]")),
        ('\'', None),
        ('(', Some("([][\"at\"]+\"\")[11]")),
        (')', Some("(\"\"+[][\"at\"])[12]")),
        ('*', None),
        ('+', Some("(+(+!+[]+(!+[]+[])[!+[]+!+[]+!+[]]+[+!+[]]+[+[]]+[+[]])+[])[2]")),
        (',', Some("[[]][\"concat\"]([[]])+\"\"")),
        ('-', Some("(+(.+[0000001])+\"\")[2]")),
        ('.', Some("(+(+!+[]+[+!+[]]+(!![]+[])[!+[]+!+[]+!+[]]+[!+[]+!+[]]+[+[]])+[])[+!+[]]")),
        ('/', Some("(false+[0])[\"italics\"]()[10]")),
        (':', Some("(RegExp()+\"\")[3]")),
        (';', Some("(\"\")[\"fontcolor\"](NaN+\")[21]")),
        ('<', Some("(\"\")[\"italics\"]()[0]")),
        ('=', Some("(\"\")[\"fontcolor\"]()[11]")),
        ('>', Some("(\"\")[\"italics\"]()[2]")),
        ('?', Some("(RegExp()+\"\")[2]")),
        ('@', None),
        ('[', Some("([][\"entries\"]()+\"\")[0]")),
        ('\\', Some("(RegExp(\"/\")+\"\")[1]")),
        (']', Some("([][\"entries\"]()+\"\")[22]")),
        ('^', None),
        ('_', None),
        ('`', None),
        ('{', Some("([0]+false+[][\"at\"])[20]")),
        ('|', None),
        ('}', Some("([][\"at\"]+\"\")[\"at\"](\"-1\")")),
        ('~', None),
    ];
    rows.extend(punct);
    rows
}

fn mapping_index(mapping: &[(char, Option<String>)], c: char) -> usize {
    mapping.iter().position(|(k, _)| *k == c).expect("mapped key")
}

fn fill_missing_digits(mapping: &mut [(char, Option<String>)]) {
    for number in 0u32..10 {
        let mut output = "+[]".to_string();
        if number > 0 {
            output = format!("+!{output}");
        }
        for _ in 1..number {
            output = format!("+!+[]{output}");
        }
        if number > 1 {
            output = output[1..].to_string();
        }
        let idx = mapping_index(mapping, (b'0' + number as u8) as char);
        mapping[idx].1 = Some(format!("[{output}]"));
    }
}

const CONSTRUCTORS: [(&str, &str); 6] = [
    ("Array", "[]"),
    ("Number", "(+[])"),
    ("String", "([]+[])"),
    ("Boolean", "(![])"),
    ("Function", r#"[]["at"]"#),
    ("RegExp", "Function(\"return/\"+false+\"/\")()"),
];

const GLOBAL: &str = "Function(\"return this\")()";

fn digit(mapping: &[(char, Option<String>)], c: char) -> String {
    mapping[mapping_index(mapping, c)].1.clone().expect("digit mapped")
}

fn number_replacement(mapping: &[(char, Option<String>)], y: &str) -> String {
    let chars: Vec<char> = y.chars().collect();
    let head = chars[0].to_digit(10).unwrap();
    let values: Vec<char> = chars[1..].to_vec();
    let mut output = "+[]".to_string();
    if head > 0 {
        output = format!("+!{output}");
    }
    for _ in 1..head {
        output = format!("+!+[]{output}");
    }
    if head > 1 {
        output = output[1..].to_string();
    }
    let mut joined = vec![output];
    joined.extend(values.iter().map(|c| c.to_string()));
    let joined = joined.join("+");
    regex::Regex::new(r"(\d)")
        .unwrap()
        .replace_all(&joined, |caps: &regex::Captures| {
            digit(mapping, caps.get(1).unwrap().as_str().chars().next().unwrap())
        })
        .into_owned()
}

fn replace_map(mapping: &mut [(char, Option<String>)]) {
    for code in MIN..=MAX {
        let character = char::from_u32(code).unwrap();
        let idx = mapping_index(mapping, character);
        let Some(mut value) = mapping[idx].1.clone() else {
            continue;
        };
        let replace = |value: &str, pattern: &str, apply: &dyn Fn(&str) -> String| -> String {
            let re = regex::RegexBuilder::new(pattern)
                .case_insensitive(true)
                .build()
                .unwrap();
            re.replace_all(value, |caps: &regex::Captures| {
                apply(caps.get(0).unwrap().as_str())
            })
            .into_owned()
        };
        for (key, ctor) in &CONSTRUCTORS {
            let pattern = format!(r"\b{key}");
            let replacement = format!("{ctor}[\"constructor\"]");
            value = replace(&value, &pattern, &move |m: &str| {
                let _ = m;
                replacement.clone()
            });
        }
        for (key, simple) in &SIMPLE {
            let replacement = (*simple).to_string();
            value = replace(&value, key, &move |m: &str| {
                let _ = m;
                replacement.clone()
            });
        }
        value = replace(&value, r"(\d\d+)", &|m: &str| {
            number_replacement(mapping, m)
        });
        value = replace(&value, r"\((\d)\)", &|m: &str| {
            digit(mapping, m.chars().nth(1).unwrap())
        });
        value = replace(&value, r"\[(\d)\]", &|m: &str| {
            digit(mapping, m.chars().nth(1).unwrap())
        });
        value = replace(&value, "GLOBAL", &|_| GLOBAL.to_string());
        value = replace(&value, r#"\+"""#, &|_| "+[]".to_string());
        value = replace(&value, r#""""#, &|_| "[]+[]".to_string());
        mapping[idx].1 = Some(value);
    }
}

fn replace_strings(mapping: &mut [(char, Option<String>)]) {
    let quote_re = regex::Regex::new(r#"(?i)"([^"]+)""#).unwrap();
    for slot in mapping.iter_mut() {
        if let Some(value) = slot.1.clone() {
            slot.1 = Some(
                quote_re
                    .replace_all(&value, |caps: &regex::Captures| {
                        caps.get(1)
                            .unwrap()
                            .as_str()
                            .chars()
                            .map(|c| c.to_string())
                            .collect::<Vec<_>>()
                            .join("+")
                    })
                    .into_owned(),
            );
        }
    }
    let reg_ex = regex::Regex::new(r"[^\[\]\(\)\!\+]{1}").unwrap();
    let mut count = (MAX - MIN) as i64;
    loop {
        let missing: Vec<char> = mapping
            .iter()
            .filter(|(_, v)| v.as_deref().map(|v| reg_ex.is_match(v)).unwrap_or(false))
            .map(|(c, _)| *c)
            .collect();
        if missing.is_empty() {
            break;
        }
        let missing_set: HashSet<char> = missing.iter().copied().collect();
        for &c in &missing {
            let idx = mapping_index(mapping, c);
            let value = mapping[idx].1.clone().unwrap();
            let replaced = reg_ex
                .replace_all(&value, |caps: &regex::Captures| {
                    let ch = caps.get(0).unwrap().as_str().chars().next().unwrap();
                    if missing_set.contains(&ch) {
                        ch.to_string()
                    } else {
                        digit_or_value(mapping, ch)
                    }
                })
                .into_owned();
            mapping[idx].1 = Some(replaced);
        }
        count -= 1;
        if count < 0 {
            panic!("Could not compile the following chars: {missing:?}");
        }
    }
}

fn digit_or_value(mapping: &[(char, Option<String>)], c: char) -> String {
    mapping
        .iter()
        .find(|(k, _)| *k == c)
        .and_then(|(_, v)| v.clone())
        .unwrap_or_else(|| "null".to_string())
}

/// JS escapeSequence: octal under 256, \uXXXX above.
fn escape_sequence(c: char) -> String {
    let cc = c as u32;
    if cc < 256 {
        format!("\\{cc:o}")
    } else {
        let hex = format!("{cc:x}");
        format!("\\u{}", &format!("0000{hex}")[hex.len()..])
    }
}

fn escape_sequence_for_replace(c: char) -> String {
    escape_sequence(c).replacen('\\', "t", 1)
}

static ENCODER: LazyLock<Encoder> = LazyLock::new(build_encoder);

pub fn encode(input: &str, wrap_with_eval: bool, run_in_parent_scope: bool) -> String {
    if input.is_empty() {
        return String::new();
    }
    let encoder = &*ENCODER;
    let mapping = &encoder.mapping;

    // Character class of mapped keys, in for-in order (digits first), with
    // regex metacharacters escaped exactly like the fixture. The bare '-'
    // between ',' and '.' forms the same range in both engines.
    let mut unmapped = String::new();
    for (k, v) in mapping {
        if v.is_some() {
            if META.contains(k) {
                unmapped.push('\\');
            }
            unmapped.push(*k);
        }
    }
    let unmapped_re = regex::Regex::new(&format!(r"[^{unmapped}]")).unwrap();
    let unmapped_count = unmapped_re.find_iter(input).count();

    let mut input: String = input.to_string();
    if unmapped_count > 1 {
        input = regex::Regex::new(r"[^0123456789.adefilnrsuN]")
            .unwrap()
            .replace_all(&input, |caps: &regex::Captures| {
                escape_sequence_for_replace(caps.get(0).unwrap().as_str().chars().next().unwrap())
            })
            .into_owned();
    } else if unmapped_count > 0 {
        input = regex::Regex::new(r#"["\\]"#)
            .unwrap()
            .replace_all(&input, |caps: &regex::Captures| {
                escape_sequence(caps.get(0).unwrap().as_str().chars().next().unwrap())
            })
            .into_owned();
        input = unmapped_re
            .replace_all(&input, |caps: &regex::Captures| {
                escape_sequence(caps.get(0).unwrap().as_str().chars().next().unwrap())
            })
            .into_owned();
    }

    let mut output: Vec<String> = Vec::new();
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        let rest: String = chars[i..].iter().collect();
        let mut simple_hit: Option<&'static str> = None;
        for (key, value) in &SIMPLE {
            if rest.starts_with(key) {
                simple_hit = Some(value);
                i += key.chars().count();
                break;
            }
        }
        if let Some(value) = simple_hit {
            output.push(format!("({value}+[])"));
        } else {
            let c = chars[i];
            i += 1;
            let replacement = mapping
                .iter()
                .find(|(k, _)| *k == c)
                .and_then(|(_, v)| v.clone());
            output.push(replacement.unwrap_or_else(|| panic!("Found unmapped character: {c}")));
        }
    }
    let mut out = output.join("+");
    if input.len() == 1 && input.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        out.push_str("+[]");
    }

    if unmapped_count > 1 {
        out = format!(
            "({out})[{}]({})[{}]({})",
            encode("split", false, false),
            encode("t", false, false),
            encode("join", false, false),
            encode("\\", false, false)
        );
    }
    if unmapped_count > 0 {
        out = format!(
            "[][{}][{}]({}+{out}+{})()",
            encode("at", false, false),
            encode("constructor", false, false),
            encode("return\"", false, false),
            encode("\"", false, false)
        );
    }
    if wrap_with_eval {
        if run_in_parent_scope {
            out = format!(
                "[][{}][{}]({})()({out})",
                encode("at", false, false),
                encode("constructor", false, false),
                encode("return eval", false, false)
            );
        } else {
            out = format!("[][{}][{}]({out})()", encode("at", false, false), encode("constructor", false, false));
        }
    }
    out
}
