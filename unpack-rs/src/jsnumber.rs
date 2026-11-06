// ECMAScript number semantics for the JSFuck interpreter: ToString(Number),
// ToNumber(String), radix formatting and the legacy escape() builtin.
//
// Rust's f64 Display differs from JS (e.g. 1e-7 prints as "1e-7" in JS but
// "0.0000001" in Rust), so the JS rules are implemented directly on top of
// shortest-round-trip digits.

const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";

/// JS `Number::toString(x)` for a finite f64 (ECMA-262 7.1.12.1, "Number
/// to String" applied to the Number type).
pub fn js_number_to_string(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value == 0.0 {
        return "0".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_string();
    }
    let negative = value < 0.0;
    let abs = value.abs();
    // Shortest round-trip digits via Rust's scientific formatter:
    // "{:e}" yields mantissa like "1.05" or "1" plus an exponent.
    let sci = format!("{:e}", abs);
    let (mantissa, exp) = sci.split_once('e').expect("scientific format");
    let exp: i32 = exp.parse().expect("scientific exponent");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let digits = digits.trim_end_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    let k = digits.len() as i32; // digit count
    // Decimal point position after the first digit: for "1.05e2" -> n = 3.
    let n = exp + 1;

    let body = if k <= n && n <= 21 {
        // digits followed by zeros
        format!("{}{}", digits, "0".repeat((n - k) as usize))
    } else if 0 < n && n <= 21 {
        // point inside the digits
        format!("{}.{}", &digits[..n as usize], &digits[n as usize..])
    } else if -6 < n && n <= 0 {
        // 0.000digits
        format!("0.{}{}", "0".repeat((-n) as usize), digits)
    } else if k == 1 {
        // single digit, exponential; JS prints the exponent as n-1
        format!("{}e{}{}", digits, sign(n - 1), (n - 1).abs())
    } else {
        // multi digit, exponential
        format!("{}.{}e{}{}", &digits[..1], &digits[1..], sign(n - 1), (n - 1).abs())
    };
    if negative {
        format!("-{body}")
    } else {
        body
    }
}

fn sign(exp: i32) -> char {
    if exp >= 0 {
        '+'
    } else {
        '-'
    }
}

/// JS `Number.prototype.toString(radix)` for the integral range the encoder
/// recipes use (radix 2..=36, |value| < 2^53).
pub fn js_number_to_radix_string(value: f64, radix: u32) -> String {
    assert!((2..=36).contains(&radix), "radix out of range");
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_string();
    }
    let mut int = value.trunc().abs() as u64;
    if value == 0.0 {
        return "0".to_string();
    }
    let mut rev = Vec::new();
    while int > 0 {
        rev.push(DIGITS[(int % radix as u64) as usize] as char);
        int /= radix as u64;
    }
    let digits: String = rev.iter().rev().collect();
    if value < 0.0 {
        format!("-{digits}")
    } else {
        digits
    }
}

fn is_js_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'
    ) || c == '\u{a0}'
        || c == '\u{feff}'
        || c == '\u{1680}'
        || ('\u{2000}'..='\u{200a}').contains(&c)
        || matches!(c, '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}')
}

/// JS ToNumber(string) for the grammar the recipes exercise: trimmed decimal
/// and exponent forms, 0x hex, Infinity, and empty -> 0.
pub fn js_string_to_number(s: &str) -> f64 {
    let t = s.trim_matches(is_js_space);
    if t.is_empty() {
        return 0.0;
    }
    let (sign, rest) = match t.as_bytes()[0] {
        b'-' => (-1.0, &t[1..]),
        b'+' => (1.0, &t[1..]),
        _ => (1.0, t),
    };
    if rest == "Infinity" {
        return sign * f64::INFINITY;
    }
    if rest == "NaN" {
        return f64::NAN;
    }
    let lower = rest.to_ascii_lowercase();
    if lower.starts_with("0x") {
        let hex = &rest[2..];
        if hex.is_empty() || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return f64::NAN;
        }
        return sign * u64::from_str_radix(hex, 16).map(|v| v as f64).unwrap_or(f64::NAN);
    }
    // Validate the decimal/exponent shape strictly; JS rejects junk.
    let bytes = rest.as_bytes();
    let mut i = 0usize;
    let mut int_digits = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
        int_digits += 1;
    }
    let mut frac_digits = 0;
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
            frac_digits += 1;
        }
    }
    let mut exp_digits = 0;
    if i < bytes.len() && (bytes[i] == b'e' || bytes[i] == b'E') {
        let mut j = i + 1;
        if j < bytes.len() && (bytes[j] == b'+' || bytes[j] == b'-') {
            j += 1;
        }
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
            exp_digits += 1;
        }
        if exp_digits > 0 {
            i = j;
        }
    }
    let valid = i == bytes.len() && (int_digits + frac_digits) > 0;
    if !valid {
        return f64::NAN;
    }
    rest.parse::<f64>().map(|v| sign * v).unwrap_or(f64::NAN)
}

/// The legacy JS `escape()`: everything outside A-Za-z0-9@*_+-./
/// becomes %XX (or %uXXXX per UTF-16 surrogate above 0xFF).
pub fn js_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '@' | '*' | '_' | '+' | '-' | '.' | '/') {
            out.push(ch);
        } else if (ch as u32) <= 0xFF {
            out.push_str(&format!("%{:02X}", ch as u32));
        } else {
            let mut units = [0u16; 2];
            for unit in ch.encode_utf16(&mut units) {
                out.push_str(&format!("%u{unit:04X}"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn js_number_string() {
        assert_eq!(js_number_to_string(101.0), "101");
        assert_eq!(js_number_to_string(0.0), "0");
        assert_eq!(js_number_to_string(-0.0), "0");
        assert_eq!(js_number_to_string(1e-7), "1e-7");
        assert_eq!(js_number_to_string(1e21), "1e+21");
        assert_eq!(js_number_to_string(1e20), "100000000000000000000");
        assert_eq!(js_number_to_string(f64::INFINITY), "Infinity");
        assert_eq!(js_number_to_string(f64::NAN), "NaN");
        assert_eq!(js_number_to_string(0.5), "0.5");
        assert_eq!(js_number_to_string(-1.5), "-1.5");
        assert_eq!(js_number_to_string(123.45), "123.45");
    }

    #[test]
    fn js_radix_string() {
        assert_eq!(js_number_to_radix_string(101.0, 21), "4h");
        assert_eq!(js_number_to_radix_string(20.0, 21), "k");
        assert_eq!(js_number_to_radix_string(211.0, 31), "6p");
    }

    #[test]
    fn js_to_number() {
        assert_eq!(js_string_to_number("101"), 101.0);
        assert_eq!(js_string_to_number("1e1000"), f64::INFINITY);
        assert_eq!(js_string_to_number(".0000001"), 1e-7);
        assert!(js_string_to_number("false").is_nan());
        assert_eq!(js_string_to_number(""), 0.0);
        assert_eq!(js_string_to_number("0x10"), 16.0);
        assert!(js_string_to_number("10e20 ").is_finite());
    }

    #[test]
    fn escape_builtins() {
        assert_eq!(js_escape("function at() { [native code] }"), "function%20at%28%29%20%7B%20%5Bnative%20code%5D%20%7D");
        assert_eq!(js_escape("<i></i>"), "%3Ci%3E%3C/i%3E");
    }
}
