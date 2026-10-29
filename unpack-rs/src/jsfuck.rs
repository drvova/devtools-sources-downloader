// JSFuck ([], (), !, +) decoding without eval/Function.
//
// The JS original evaluates the grammar over REAL JavaScript values so +, !,
// String() and method calls delegate to the engine. Rust has no host engine,
// so the value model below implements exactly the coercion and builtin
// surface the canonical encoder (jsfuck.com 0.5.0) reaches:
//   - arrays, groups, unary !/+, binary + (jsPlus)
//   - Array.prototype: at, entries, concat; String.prototype: at, fontcolor,
//     italics, split; Array.prototype.join; Number.prototype.toString(radix)
//   - constructors read as values ('function Number() { [native code] }')
//   - Function/eval modeled as capture seams, never executed
//   - Function("return X") bodies: this / eval / builtin-by-name / regex
//     literal / quoted payload / raw payload (captured)
//   - escape() and Date() builtins for the encoder's C/D/%/G/M/T recipes

use std::collections::HashMap;
use std::sync::LazyLock;

const CHARSET: [char; 6] = ['[', ']', '(', ')', '!', '+'];
const MAX_PARSE_NODES: u64 = 2_000_000;
const MAX_PARSE_DEPTH: u64 = 10_000;

/// A native builtin the fromSource resolver and global object can produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Builtin {
    Array,
    Number,
    String_,
    Boolean,
    RegExp,
    Date,
    Escape,
}

impl Builtin {
    pub fn name(self) -> &'static str {
        match self {
            Builtin::Array => "Array",
            Builtin::Number => "Number",
            Builtin::String_ => "String",
            Builtin::Boolean => "Boolean",
            Builtin::RegExp => "RegExp",
            Builtin::Date => "Date",
            Builtin::Escape => "escape",
        }
    }
}

/// The interpreter's value model: the subset of ECMAScript values the
/// canonical JSFuck language can construct.
#[derive(Debug, Clone, PartialEq)]
pub enum JValue {
    Undefined,
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<JValue>),
    /// A native function reached through prototype chains (`[]["at"]`).
    Native(&'static str),
    /// A constructor read as a value (`Number`, `String`).
    Constructor(&'static str),
    /// The result of `[]["entries"]()`; stringifies as
    /// '[object Array Iterator]'.
    ArrayIterator,
    /// The Function constructor seam.
    FunctionModel,
    /// The eval seam.
    EvalModel,
    /// `{__jsfuckFn: true, body}` — a Function("...") result.
    FromSource(String),
    /// `Function("return this")()` — the global object.
    Global,
    /// A RegExp value with source and flags.
    RegExp { source: String, flags: String },
}

#[derive(serde::Serialize)]
pub struct JsfuckDetect {
    pub detected: bool,
    pub purity: f64,
    pub reason: String,
}

#[derive(serde::Serialize)]
pub struct JsfuckDecode {
    pub value: Option<String>,
    pub captured: bool,
}

#[derive(Debug)]
pub struct JsfuckError(pub String);

impl std::fmt::Display for JsfuckError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for JsfuckError {}

pub fn longest_operator_chain(source: &str) -> usize {
    source
        .chars()
        .fold((0usize, 0usize), |(best, run), c| {
            if c == '+' {
                (best.max(run + 1), run + 1)
            } else {
                (best, 0)
            }
        })
        .0
}

/// Detection ports the disrobe heuristic: only the charset (plus whitespace),
/// high purity, long-enough body, bounded operator chains.
pub fn detect_jsfuck(source: &str) -> JsfuckDetect {
    let trimmed = source.trim();
    if trimmed.chars().count() < 12 {
        return JsfuckDetect {
            detected: false,
            purity: 0.0,
            reason: "too short".to_string(),
        };
    }
    let mut hits = 0usize;
    let mut counted = 0usize;
    for c in trimmed.chars() {
        if CHARSET.contains(&c) {
            hits += 1;
        }
        if c != ' ' {
            counted += 1;
        }
    }
    let purity = if counted > 0 { hits as f64 / counted as f64 } else { 0.0 };
    if purity < 0.95 || hits < 12 {
        return JsfuckDetect {
            detected: false,
            purity,
            reason: format!("purity {:.1}% ({hits} charset bytes)", purity * 100.0),
        };
    }
    let chain = longest_operator_chain(trimmed);
    if chain > 4096 {
        return JsfuckDetect {
            detected: false,
            purity,
            reason: format!("operator chain too long ({chain})"),
        };
    }
    JsfuckDetect {
        detected: true,
        purity,
        reason: String::new(),
    }
}

struct Interpreter<'a> {
    source: &'a [char],
    pos: usize,
    nodes: u64,
    capture: Option<String>,
}

/// Canonical array-index keys only ("0", "42"); "00" or "-1" are property
/// names, not indices, exactly like JS `target[key]`.
fn canonical_index(key: &str) -> Option<usize> {
    if key.is_empty() || !key.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let parsed: usize = key.parse().ok()?;
    (key == parsed.to_string()).then_some(parsed)
}

/// JSFuck value stringification for the + operator and explicit coercions.
fn to_display_string(v: &JValue) -> String {
    match v {
        JValue::Undefined => "undefined".to_string(),
        JValue::Null => "null".to_string(),
        JValue::Bool(b) => b.to_string(),
        JValue::Num(n) => crate::jsnumber::js_number_to_string(*n),
        JValue::Str(s) => s.clone(),
        JValue::Arr(items) => items
            .iter()
            .map(|item| match item {
                JValue::Undefined | JValue::Null => String::new(),
                other => to_display_string(other),
            })
            .collect::<Vec<_>>()
            .join(","),
        JValue::Native(name) | JValue::Constructor(name) => {
            format!("function {name}() {{ [native code] }}")
        }
        JValue::ArrayIterator => "[object Array Iterator]".to_string(),
        JValue::FunctionModel => "function Function() { [native code] }".to_string(),
        JValue::EvalModel => "function eval() { [native code] }".to_string(),
        JValue::FromSource(_) => "[object Object]".to_string(),
        JValue::Global => "[object global]".to_string(),
        JValue::RegExp { source, flags } => {
            if source.is_empty() {
                // V8 prints the empty-source regex as /(?:)/.
                format!("/(?:)/{flags}")
            } else {
                format!("/{source}/{flags}")
            }
        }
    }
}

fn is_array(v: &JValue) -> bool {
    matches!(v, JValue::Arr(_))
}

/// unwrapToPrimitive over the model.
fn unwrap_to_primitive(v: &JValue) -> JValue {
    match v {
        JValue::Arr(items) => JValue::Str(
            items
                .iter()
                .map(|item| match item {
                    JValue::Undefined | JValue::Null => String::new(),
                    other => to_display_string(other),
                })
                .collect::<Vec<_>>()
                .join(","),
        ),
        JValue::ArrayIterator => JValue::Str("[object Array Iterator]".to_string()),
        JValue::Global => JValue::Str("[object global]".to_string()),
        JValue::FromSource(_) => JValue::Str("[object Object]".to_string()),
        // Functions and regexes unwrap to their source string, like JS
        // ToPrimitive (that is how `true + [].at` spells out the fn text).
        JValue::Native(_)
        | JValue::Constructor(_)
        | JValue::FunctionModel
        | JValue::EvalModel
        | JValue::RegExp { .. } => JValue::Str(to_display_string(v)),
        other => other.clone(),
    }
}

/// ToBoolean over the model.
fn to_boolean(v: &JValue) -> bool {
    match v {
        JValue::Undefined | JValue::Null => false,
        JValue::Bool(b) => *b,
        JValue::Num(n) => *n != 0.0 && !n.is_nan(),
        JValue::Str(s) => !s.is_empty(),
        _ => true,
    }
}

/// ToNumber over the model (unary + and numeric +).
fn to_number(v: &JValue) -> f64 {
    match v {
        JValue::Undefined => f64::NAN,
        JValue::Null => 0.0,
        JValue::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        JValue::Num(n) => *n,
        JValue::Str(s) => crate::jsnumber::js_string_to_number(s),
        JValue::Arr(_) => crate::jsnumber::js_string_to_number(&to_display_string(v)),
        other => crate::jsnumber::js_string_to_number(&to_display_string(other)),
    }
}

impl<'a> Interpreter<'a> {
    fn new(source: &'a [char]) -> Self {
        Interpreter {
            source,
            pos: 0,
            nodes: 0,
            capture: None,
        }
    }

    fn peek(&self) -> Option<char> {
        self.source.get(self.pos).copied()
    }

    fn skip_noise(&mut self) {
        while self
            .peek()
            .map(|c| c.is_whitespace())
            .unwrap_or(false)
        {
            self.pos += 1;
        }
    }

    fn expect(&mut self, ch: char) -> Result<(), JsfuckError> {
        self.skip_noise();
        if self.peek() != Some(ch) {
            return Err(JsfuckError(format!(
                "jsfuck decode error at {}: expected {ch}",
                self.pos
            )));
        }
        self.pos += 1;
        Ok(())
    }

    fn parse_primary(&mut self, depth: u64) -> Result<JValue, JsfuckError> {
        self.nodes += 1;
        if self.nodes > MAX_PARSE_NODES {
            return Err(JsfuckError(format!(
                "jsfuck decode error at {}: expression budget exceeded",
                self.pos
            )));
        }
        if depth > MAX_PARSE_DEPTH {
            return Err(JsfuckError(format!(
                "jsfuck decode error at {}: nesting too deep",
                self.pos
            )));
        }
        self.skip_noise();
        let c = match self.peek() {
            Some(c) => c,
            None => {
                return Err(JsfuckError(format!(
                    "jsfuck decode error at {}: unexpected end of input",
                    self.pos
                )))
            }
        };
        match c {
            '(' => {
                self.pos += 1;
                let value = self.parse_expression(depth + 1)?;
                self.expect(')')?;
                Ok(value)
            }
            '[' => {
                self.pos += 1;
                let mut elements = Vec::new();
                self.skip_noise();
                if self.peek() == Some(']') {
                    self.pos += 1;
                    return Ok(JValue::Arr(elements));
                }
                loop {
                    elements.push(self.parse_expression(depth + 1)?);
                    self.skip_noise();
                    if self.peek() == Some(',') {
                        self.pos += 1;
                        self.skip_noise();
                        if self.peek() == Some(']') {
                            break; // trailing comma tolerated
                        }
                        continue;
                    }
                    break;
                }
                self.expect(']')?;
                Ok(JValue::Arr(elements))
            }
            '!' => {
                self.pos += 1;
                Ok(JValue::Bool(!to_boolean(&self.parse_primary(depth + 1)?)))
            }
            '+' => {
                self.pos += 1;
                Ok(JValue::Num(to_number(&self.parse_primary(depth + 1)?)))
            }
            other => Err(JsfuckError(format!(
                "jsfuck decode error at {}: unexpected character {other:?}",
                self.pos
            ))),
        }
    }

    fn parse_suffixes(
        &mut self,
        mut value: JValue,
        depth: u64,
    ) -> Result<JValue, JsfuckError> {
        // Real JS binds `this` at CALL time from the member-read receiver.
        let mut receiver: Option<JValue> = None;
        loop {
            self.skip_noise();
            match self.peek() {
                Some('[') => {
                    self.pos += 1;
                    let key = self.parse_expression(depth + 1)?;
                    self.expect(']')?;
                    receiver = Some(value.clone());
                    value = self.read_member(&value, &key)?;
                }
                Some('(') => {
                    self.pos += 1;
                    let mut args = Vec::new();
                    self.skip_noise();
                    if self.peek() != Some(')') {
                        loop {
                            args.push(self.parse_expression(depth + 1)?);
                            self.skip_noise();
                            if self.peek() == Some(',') {
                                self.pos += 1;
                                continue;
                            }
                            break;
                        }
                    }
                    self.expect(')')?;
                    value = self.call_value(&value, &args, receiver.take())?;
                }
                _ => return Ok(value),
            }
        }
    }

    fn parse_expression(&mut self, depth: u64) -> Result<JValue, JsfuckError> {
        self.nodes += 1;
        if self.nodes > MAX_PARSE_NODES {
            return Err(JsfuckError(format!(
                "jsfuck decode error at {}: expression budget exceeded",
                self.pos
            )));
        }
        let primary = self.parse_primary(depth)?;
        let mut value = self.parse_suffixes(primary, depth)?;
        loop {
            self.skip_noise();
            if self.peek() != Some('+') {
                return Ok(value);
            }
            self.pos += 1;
            let right_primary = self.parse_primary(depth)?;
            let right = self.parse_suffixes(right_primary, depth)?;
            value = js_plus(&value, &right);
        }
    }

    fn read_member(&mut self, base: &JValue, key_expr: &JValue) -> Result<JValue, JsfuckError> {
        let key = to_display_string(&unwrap_to_primitive(key_expr));
        if matches!(base, JValue::Global) {
            return Ok(self.read_global_member(&key));
        }
        match base {
            JValue::Undefined | JValue::Null => Err(JsfuckError(format!(
                "jsfuck decode error at {}: member access on {} for key {key:?}",
                self.pos,
                to_display_string(base)
            ))),
            JValue::Arr(_) => {
                let JValue::Arr(items) = base else { unreachable!() };
                Ok(if let Some(idx) = canonical_index(&key) {
                    items.get(idx).cloned().unwrap_or(JValue::Undefined)
                } else {
                    array_member(&key)
                })
            }
            JValue::Str(_) => {
                let JValue::Str(text) = base else { unreachable!() };
                Ok(if let Some(idx) = canonical_index(&key) {
                    text.chars()
                        .nth(idx)
                        .map(|c| JValue::Str(c.to_string()))
                        .unwrap_or(JValue::Undefined)
                } else {
                    string_member(&key)
                })
            }
            JValue::Num(_) => Ok(number_member(&key)),
            JValue::Bool(_) => Ok(if key == "constructor" {
                JValue::Constructor("Boolean")
            } else {
                JValue::Undefined
            }),
            JValue::Native(name) | JValue::Constructor(name) => {
                if key == "constructor" {
                    return Ok(JValue::FunctionModel);
                }
                if key == "name" {
                    return Ok(JValue::Str((*name).to_string()));
                }
                Ok(JValue::Undefined)
            }
            JValue::RegExp { .. } => Ok(if key == "constructor" {
                JValue::Constructor("RegExp")
            } else if key == "source" {
                let JValue::RegExp { source, .. } = base else {
                    unreachable!()
                };
                JValue::Str(source.clone())
            } else {
                JValue::Undefined
            }),
            JValue::ArrayIterator | JValue::FromSource(_) => Ok(JValue::Undefined),
            JValue::FunctionModel | JValue::EvalModel => {
                if key == "constructor" {
                    Ok(JValue::FunctionModel)
                } else if key == "name" {
                    Ok(JValue::Str(
                        if matches!(base, JValue::FunctionModel) {
                            "Function"
                        } else {
                            "eval"
                        }
                        .to_string(),
                    ))
                } else {
                    Ok(JValue::Undefined)
                }
            }
            JValue::Global => unreachable!(),
        }
    }

    fn read_global_member(&self, key: &str) -> JValue {
        if key == "eval" {
            return JValue::EvalModel;
        }
        if key == "Function" {
            return JValue::FunctionModel;
        }
        match key {
            "Array" => JValue::Constructor("Array"),
            "Number" => JValue::Constructor("Number"),
            "String" => JValue::Constructor("String"),
            "Boolean" => JValue::Constructor("Boolean"),
            "RegExp" => JValue::Constructor("RegExp"),
            "Date" => JValue::Native("Date"),
            "escape" => JValue::Native("escape"),
            "undefined" => JValue::Undefined,
            "NaN" => JValue::Num(f64::NAN),
            "Infinity" => JValue::Num(f64::INFINITY),
            _ => JValue::Undefined,
        }
    }

    fn call_value(
        &mut self,
        callee: &JValue,
        args: &[JValue],
        receiver: Option<JValue>,
    ) -> Result<JValue, JsfuckError> {
        match callee {
            JValue::FunctionModel => {
                let body = args
                    .iter()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .collect::<Vec<_>>()
                    .join(",");
                Ok(JValue::FromSource(body))
            }
            JValue::EvalModel => {
                // eval(payload) is the capture point: record, never execute.
                let text = args
                    .first()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_default();
                self.capture = Some(text);
                Ok(JValue::Undefined)
            }
            JValue::FromSource(body) => self.call_from_source(body.clone()),
            JValue::Native(_) | JValue::Constructor(_) => {
                self.invoke_native(callee, args, receiver)
            }
            other => Err(JsfuckError(format!(
                "jsfuck decode error at {}: call target is {}, not a function",
                self.pos,
                value_type_name(other)
            ))),
        }
    }

    fn call_from_source(&mut self, body: String) -> Result<JValue, JsfuckError> {
        static RETURN_NAME: LazyLock<regex::Regex> =
            LazyLock::new(|| regex::Regex::new(r"^return\s+([A-Za-z_$][\w$]*)$").unwrap());
        static RETURN_REGEX: LazyLock<regex::Regex> =
            LazyLock::new(|| regex::Regex::new(r"^return\s*/(.*)/([a-z]*)\s*$").unwrap());
        static RETURN_QUOTED: LazyLock<regex::Regex> =
            LazyLock::new(|| regex::Regex::new(r#"^return\s*"((?:[^"\\]|\\.)*)"\s*$"#).unwrap());
        if let Some(m) = RETURN_NAME.captures(&body) {
            let name = m.get(1).unwrap().as_str();
            if name == "this" {
                return Ok(JValue::Global);
            }
            if name == "eval" {
                return Ok(JValue::EvalModel);
            }
            return match name {
                "Array" => Ok(JValue::Constructor("Array")),
                "Number" => Ok(JValue::Constructor("Number")),
                "String" => Ok(JValue::Constructor("String")),
                "Boolean" => Ok(JValue::Constructor("Boolean")),
                "RegExp" => Ok(JValue::Constructor("RegExp")),
                "Date" => Ok(JValue::Native("Date")),
                "escape" => Ok(JValue::Native("escape")),
                "NaN" => Ok(JValue::Num(f64::NAN)),
                "Infinity" => Ok(JValue::Num(f64::INFINITY)),
                _ => Err(JsfuckError(format!(
                    "jsfuck decode error at {}: unknown builtin {name:?} in fromSource",
                    self.pos
                ))),
            };
        }
        if let Some(m) = RETURN_REGEX.captures(&body) {
            return Ok(JValue::RegExp {
                source: m.get(1).unwrap().as_str().to_string(),
                flags: m.get(2).unwrap().as_str().to_string(),
            });
        }
        if let Some(m) = RETURN_QUOTED.captures(&body) {
            return Ok(JValue::Str(unescape_literal(m.get(1).unwrap().as_str())));
        }
        // Payload code: capture instead of executing.
        self.capture = Some(body);
        Ok(JValue::Undefined)
    }

    fn invoke_native(
        &mut self,
        callee: &JValue,
        args: &[JValue],
        receiver: Option<JValue>,
    ) -> Result<JValue, JsfuckError> {
        let name = match callee {
            JValue::Native(n) => *n,
            JValue::Constructor(c) => *c,
            _ => unreachable!(),
        };
        let this = receiver
            .map(|r| unwrap_to_primitive(&r))
            .unwrap_or(JValue::Undefined);
        match name {
            "at" => {
                // Array.prototype.at / String.prototype.at share this arm; the
                // receiver decides which.
                let index = args
                    .first()
                    .map(to_number)
                    .unwrap_or(f64::NAN);
                if is_array(&this) {
                    let JValue::Arr(items) = &this else { unreachable!() };
                    let len = items.len() as f64;
                    if index.is_nan() {
                        return Ok(JValue::Undefined);
                    }
                    let idx = if index < 0.0 { len + index } else { index };
                    if !(0.0..len).contains(&idx) || idx.fract() != 0.0 {
                        return Ok(JValue::Undefined);
                    }
                    Ok(items[idx as usize].clone())
                } else {
                    let s = to_display_string(&this);
                    let len = s.chars().count() as f64;
                    if index.is_nan() {
                        return Ok(JValue::Undefined);
                    }
                    let idx = if index < 0.0 { len + index } else { index };
                    if !(0.0..len).contains(&idx) || idx.fract() != 0.0 {
                        return Ok(JValue::Undefined);
                    }
                    Ok(JValue::Str(
                        s.chars().nth(idx as usize).unwrap_or_default().to_string(),
                    ))
                }
            }
            "entries" => Ok(JValue::ArrayIterator),
            "concat" => {
                if let JValue::Arr(items) = &this {
                    let mut out = items.clone();
                    for a in args {
                        match a {
                            JValue::Arr(other) => out.extend(other.iter().cloned()),
                            other => out.push(other.clone()),
                        }
                    }
                    Ok(JValue::Arr(out))
                } else {
                    let mut s = to_display_string(&this);
                    for a in args {
                        s.push_str(&to_display_string(&unwrap_to_primitive(a)));
                    }
                    Ok(JValue::Str(s))
                }
            }
            "join" => {
                let sep = args
                    .first()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_else(|| ",".to_string());
                if let JValue::Arr(items) = &this {
                    Ok(JValue::Str(
                        items
                            .iter()
                            .map(|item| match item {
                                JValue::Undefined | JValue::Null => String::new(),
                                other => to_display_string(other),
                            })
                            .collect::<Vec<_>>()
                            .join(&sep),
                    ))
                } else {
                    Err(JsfuckError(format!(
                        "jsfuck decode error at {}: join on non-array receiver",
                        self.pos
                    )))
                }
            }
            "split" => {
                let s = to_display_string(&this);
                let sep = args
                    .first()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_default();
                if sep.is_empty() {
                    return Ok(JValue::Arr(
                        s.chars().map(|c| JValue::Str(c.to_string())).collect(),
                    ));
                }
                Ok(JValue::Arr(
                    s.split(sep.as_str())
                        .map(|part| JValue::Str(part.to_string()))
                        .collect(),
                ))
            }
            "fontcolor" => {
                let s = to_display_string(&this);
                let color = args
                    .first()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_else(|| "undefined".to_string());
                Ok(JValue::Str(format!(
                    r#"<font color="{}">{s}</font>"#,
                    color.replace('"', "&quot;")
                )))
            }
            "italics" => {
                let s = to_display_string(&this);
                Ok(JValue::Str(format!("<i>{s}</i>")))
            }
            "toString" => match args.first().map(to_number) {
                Some(radix) if (2.0..=36.0).contains(&radix) && radix.fract() == 0.0 => {
                    let n = match &this {
                        JValue::Num(n) => *n,
                        JValue::Arr(_) | JValue::Str(_) => to_number(&this),
                        other => to_number(other),
                    };
                    Ok(JValue::Str(
                        crate::jsnumber::js_number_to_radix_string(n, radix as u32),
                    ))
                }
                _ => Ok(JValue::Str(to_display_string(&this))),
            },
            "escape" => Ok(JValue::Str(crate::jsnumber::js_escape(&to_display_string(
                &unwrap_to_primitive(args.first().unwrap_or(&JValue::Undefined)),
            )))),
            "Date" => Ok(JValue::Str(js_date_string())),
            "Array" => Ok(JValue::Arr(Vec::new())),
            "Number" => Ok(JValue::Num(to_number(
                args.first().unwrap_or(&JValue::Undefined),
            ))),
            "String" => Ok(JValue::Str(to_display_string(&unwrap_to_primitive(
                args.first().unwrap_or(&JValue::Undefined),
            )))),
            "Boolean" => Ok(JValue::Bool(to_boolean(
                args.first().unwrap_or(&JValue::Undefined),
            ))),
            "RegExp" => {
                let source = args
                    .first()
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_default();
                let flags = args
                    .get(1)
                    .map(|a| to_display_string(&unwrap_to_primitive(a)))
                    .unwrap_or_default();
                Ok(JValue::RegExp { source, flags })
            }
            other => Err(JsfuckError(format!(
                "jsfuck decode error at {}: unmodeled builtin {other:?}",
                self.pos
            ))),
        }
    }
}

fn value_type_name(v: &JValue) -> &'static str {
    match v {
        JValue::Undefined => "undefined",
        JValue::Null => "object",
        JValue::Bool(_) => "boolean",
        JValue::Num(_) => "number",
        JValue::Str(_) => "string",
        _ => "object",
    }
}

/// JS `+`: string concatenation when either side is a string, numeric
/// addition otherwise (the model's real-engine semantics cover number +
/// function strings, arrays, etc.).
fn js_plus(left: &JValue, right: &JValue) -> JValue {
    let l = unwrap_to_primitive(left);
    let r = unwrap_to_primitive(right);
    if matches!(l, JValue::Str(_)) || matches!(r, JValue::Str(_)) {
        return JValue::Str(format!("{}{}", to_display_string(&l), to_display_string(&r)));
    }
    JValue::Num(to_number(&l) + to_number(&r))
}

fn array_member(key: &str) -> JValue {
    match key {
        "at" => JValue::Native("at"),
        "entries" => JValue::Native("entries"),
        "concat" => JValue::Native("concat"),
        "join" => JValue::Native("join"),
        "constructor" => JValue::FunctionModel,
        _ => JValue::Undefined,
    }
}

fn string_member(key: &str) -> JValue {
    match key {
        "at" => JValue::Native("at"),
        "concat" => JValue::Native("concat"),
        "split" => JValue::Native("split"),
        "fontcolor" => JValue::Native("fontcolor"),
        "italics" => JValue::Native("italics"),
        "constructor" => JValue::Constructor("String"),
        _ => JValue::Undefined,
    }
}

fn number_member(key: &str) -> JValue {
    match key {
        "toString" => JValue::Native("toString"),
        "constructor" => JValue::Constructor("Number"),
        _ => JValue::Undefined,
    }
}

/// Date() as a function: V8's UTC-format string. The original delegates to
/// the host Date and is locale-dependent by nature; the model pins one
/// environment's answer (see PORTING.md).
fn js_date_string() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    // 1970-01-01 was a Thursday (index 4).
    let weekday = names[((days + 4) % 7) as usize];
    let iso = crate::util::iso8601_from_unix_secs(secs);
    let (date, _time) = iso.split_once('T').unwrap_or((iso.as_str(), ""));
    let (year, rest) = date.split_once('-').unwrap_or((date, ""));
    let (month, day) = rest.split_once('-').unwrap_or((rest, ""));
    format!(
        "{weekday} {month} {day} {year} {:02}:{:02}:{:02} GMT+0000 (Coordinated Universal Time)",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn unescape_literal(raw: &str) -> String {
    static ESCAPE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(
            r"\\(?:(u[0-9a-fA-F]{4})|(x[0-9a-fA-F]{2})|([0-7]{1,3})|(\r|\n)|(.))",
        )
        .unwrap()
    });
    ESCAPE
        .replace_all(raw, |caps: &regex::Captures| -> String {
            if let Some(m) = caps.get(1) {
                let code = u32::from_str_radix(&m.as_str()[1..], 16).unwrap_or(0);
                return char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}').to_string();
            }
            if let Some(m) = caps.get(2) {
                let code = u32::from_str_radix(&m.as_str()[1..], 16).unwrap_or(0);
                return char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}').to_string();
            }
            if let Some(m) = caps.get(3) {
                let code = u32::from_str_radix(m.as_str(), 8).unwrap_or(0);
                return char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}').to_string();
            }
            if caps.get(4).is_some() {
                return String::new();
            }
            match caps.get(5).unwrap().as_str() {
                "n" => "\n".to_string(),
                "r" => "\r".to_string(),
                "t" => "\t".to_string(),
                "b" => "\u{8}".to_string(),
                "f" => "\u{c}".to_string(),
                "v" => "\u{b}".to_string(),
                "0" => "\0".to_string(),
                other => other.to_string(),
            }
        })
        .into_owned()
}

/// The full interpreter: returns the evaluated value plus the captured
/// payload (what the program would have executed at an eval/Function seam).
pub fn interpret_jsfuck(source: &str) -> Result<(JValue, Option<String>), JsfuckError> {
    let chars: Vec<char> = source.chars().collect();
    let mut interp = Interpreter::new(&chars);
    let value = interp.parse_expression(0)?;
    interp.skip_noise();
    if interp.pos < chars.len() {
        return Err(JsfuckError(format!(
            "jsfuck decode error at {}: trailing input",
            interp.pos
        )));
    }
    Ok((value, interp.capture))
}

/// Decode returns the captured payload (what the script would have executed)
/// when the program reaches a Function/eval seam, otherwise the string the
/// expression evaluates to.
pub fn decode_jsfuck(source: &str) -> JsfuckDecode {
    match interpret_jsfuck(source) {
        Ok((value, capture)) => {
            if let Some(captured) = capture {
                return JsfuckDecode {
                    value: Some(captured),
                    captured: true,
                };
            }
            match value {
                JValue::Str(s) => JsfuckDecode {
                    value: Some(s),
                    captured: false,
                },
                _ => JsfuckDecode {
                    value: None,
                    captured: false,
                },
            }
        }
        Err(_) => JsfuckDecode {
            value: None,
            captured: false,
        },
    }
}

// Builtin is referenced by name-matching in fromSource; keep the enum used
// for future registry extension without dead-code warnings.
#[allow(dead_code)]
fn builtin_registry() -> HashMap<&'static str, Builtin> {
    HashMap::from([
        ("Array", Builtin::Array),
        ("Number", Builtin::Number),
        ("String", Builtin::String_),
        ("Boolean", Builtin::Boolean),
        ("RegExp", Builtin::RegExp),
        ("Date", Builtin::Date),
        ("escape", Builtin::Escape),
    ])
}
