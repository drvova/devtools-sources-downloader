;;;; wf-consts.lisp - the waterfall report's markup constants.
;;;
;;;; EXTRACTED MECHANICALLY from report.rs (the 19 `WF_*` raw strings), not
;;;; transcribed. Three of them are over 300 characters and one is 2,374; a single
;;;; mistyped character in that volume would be invisible until a 13,000-character
;;;; string comparison failed. Byte lengths were verified round-trip on extraction.

(in-package :vovas.engine.panel.report)

(defparameter *wf-0* "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Waterfall Report</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;padding:20px}h1{font-size:20px;margin-bottom:6px;color:#03a9f4}.sub{color:#888;font-size:12px;margin-bottom:16px}.summary{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}.stat{background:#16213e;border-radius:6px;padding:8px 14px;border:1px solid #2a2a4a}.stat .val{font-size:18px;font-weight:600;color:#03a9f4}.stat .lbl{font-size:10px;color:#888;text-transform:uppercase;letter-spacing:.5px}.chart{background:#1e1e36;border-radius:8px;padding:16px;overflow-x:auto;border:1px solid #2a2a4a}.legend{display:flex;gap:16px;margin-bottom:10px;flex-wrap:wrap}.legend span{display:flex;align-items:center;gap:4px;font-size:11px}.legend .sw{width:12px;height:12px;border-radius:2px}.controls{display:flex;gap:8px;margin-bottom:12px}.controls button{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 12px;border-radius:4px;cursor:pointer;font-size:11px}.controls button:hover{background:#1e1e46;border-color:#03a9f4}.controls input{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 10px;border-radius:4px;font-size:11px;width:240px}.controls input:focus{outline:none;border-color:#03a9f4}.controls select{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px;border-radius:4px;font-size:11px}.dark{background:#f5f5f5;color:#333}.dark h1{color:#0288d1}.dark .stat{background:#fff;border:1px solid #ddd}.dark .stat .val{color:#0288d1}.dark .chart{background:#fff;border:1px solid #ddd}.dark .controls button{background:#eee;color:#333;border:1px solid #ccc}.dark .controls input{background:#fff;color:#333;border:1px solid #ccc}.dark .controls select{background:#fff;color:#333;border:1px solid #ccc}table{width:100%;border-collapse:collapse;margin-top:10px;font-size:11px}th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #2a2a4a}th{color:#888;font-weight:500;position:sticky;top:0;background:#1e1e36}tr:hover{background:rgba(3,169,244,.1)}.dark th{background:#fff;color:#666}.dark td{border-color:#eee}</style>
</head>
<body><h1>Network Waterfall</h1><div class=\"sub\">Generated ")
(defparameter *wf-2* " | ")
(defparameter *wf-4* " requests | Total: ")
(defparameter *wf-6* "</div><div class=\"summary\">")
(defparameter *wf-8* "</div><div class=\"controls\"><button onclick=\"toggleTheme()\">Toggle Dark/Light</button><input id=\"search\" placeholder=\"Filter by URL...\" oninput=\"filterTable()\"><select id=\"typeFilter\" onchange=\"filterTable()\"><option value=\"\">All types</option></select></div><div class=\"chart\"><div class=\"legend\"><span><span class=\"sw\" style=\"background:")
(defparameter *wf-10* "\"></span> DNS</span><span><span class=\"sw\" style=\"background:")
(defparameter *wf-12* "\"></span> TCP</span><span><span class=\"sw\" style=\"background:")
(defparameter *wf-14* "\"></span> SSL</span><span><span class=\"sw\" style=\"background:")
(defparameter *wf-16* "\"></span> TTFB</span><span><span class=\"sw\" style=\"background:")
(defparameter *wf-18* "\"></span> Download</span></div><svg viewBox=\"0 0 ")
(defparameter *wf-20* " ")
(defparameter *wf-22* "\" style=\"width:100%;height:auto;min-width:")
(defparameter *wf-24* "px\"><rect width=\"")
(defparameter *wf-26* "\" height=\"")
(defparameter *wf-28* "\" fill=\"")
(defparameter *wf-30* "\" rx=\"6\"/>")
(defparameter *wf-33* "</svg></div>")
(defparameter *wf-35* "<script>var timings=")
(defparameter *wf-37* ";function toggleTheme(){document.body.classList.toggle(\"dark\")}var types=[...new Set(timings.map(function(t){return t.initiatorType||\"other\"}))];var sel=document.getElementById(\"typeFilter\");for(var i=0;i<types.length;i++){var o=document.createElement(\"option\");o.value=types[i];o.textContent=types[i];sel.appendChild(o)}function filterTable(){var q=(document.getElementById(\"search\").value||\"\").toLowerCase();var tp=sel.value;var rows=document.querySelectorAll(\"#resTable tbody tr\");for(var i=0;i<rows.length;i++){var r=rows[i];var url=(r.cells[0].textContent||\"\").toLowerCase();var type=r.cells[1].textContent||\"\";var show=!q||url.indexOf(q)>-1;if(tp&&type!==tp)show=false;r.style.display=show?\"\":\"none\"}}</script></body></html>")
