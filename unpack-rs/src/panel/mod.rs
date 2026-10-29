//! The DevTools panel's own logic, ported from the former extension
//! `src/js/page.js`.
//!
//! The panel is the extension's code (unlike the inspected-page collectors,
//! which run in the page's own JavaScript context and cannot be wasm): it owns
//! capture state, resource filtering and sorting, artifact path building,
//! report shaping and the HTML view strings. A thin JavaScript platform shim
//! forwards the `chrome.devtools` callbacks into these entry points and
//! applies the view models this module produces.
//!
//! `text` holds the pure string/number helpers with the exact JavaScript
//! semantics (verified against node oracles captured from the pre-port
//! implementation).

pub mod analysis;
pub mod artifacts;
pub mod assets;
pub mod boundary;
pub mod graph;
pub mod model;
pub mod text;
pub mod view;
pub mod workspace;
