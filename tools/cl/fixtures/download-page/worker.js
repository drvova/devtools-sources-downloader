self.onmessage = function (event) {
    self.postMessage('pong:' + event.data);
};
