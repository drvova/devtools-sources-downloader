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
