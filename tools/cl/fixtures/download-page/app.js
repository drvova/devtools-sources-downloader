// Every runtime payload kind the capture records, so the archive has something
// to show beyond the page's own resources.
fetch('data.json')
    .then(function (response) { return response.json(); })
    .then(function (data) {
        document.getElementById('status').textContent = 'loaded ' + data.value;
    });

// eval: recorded as a runtime payload.
eval('var fixtureEval = 1 + 1;');

// Function constructor: a second runtime payload kind.
var add = new Function('a', 'b', 'return a + b;');
add(1, 2);

// A worker: a third kind, and its own script resource.
try {
    var worker = new Worker('worker.js');
    worker.postMessage('ping');
    worker.onmessage = function (event) {
        document.body.setAttribute('data-worker', String(event.data));
    };
} catch (error) {
    document.body.setAttribute('data-worker-error', String(error));
}

// An inline source map, so the unpack path resolves one end to end.
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbImFwcC50cyJdLCJzb3VyY2VzQ29udGVudCI6WyIvLyBhcHAudHMgLSB0aGUgb3JpZ2luYWwgdGhlIG1hcCBwb2ludHMgYXRcbmNvbnN0IGFuc3dlcjogbnVtYmVyID0gNDI7XG4iXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQUEifQ==

// A real WebAssembly module, so the wasm detector and parser see one.
fetch('module.wasm')
    .then(function (response) { return response.arrayBuffer(); })
    .then(function (bytes) { return WebAssembly.instantiate(bytes); })
    .then(function (result) {
        document.body.setAttribute('data-wasm', String(result.instance.exports.answer()));
    });

// A GraphQL operation, so the body predicate and the operation parser run. The
// fixture server answers 404 for a POST; the request is what gets recorded.
fetch('graphql', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
        operationName: 'Fixture',
        query: 'query Fixture($id: ID!) { viewer(id: $id) { login } }',
        variables: { id: '1' },
    }),
});
