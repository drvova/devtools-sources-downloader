(function () {
    'use strict';

    var TRACKER = {
        resources: {},
        loaded: [],
        unloaded: [],
    };
    window.__RESOURCE_TRACKER__ = TRACKER;

    var RECON = {
        xhr: [],
        fetch: [],
        websockets: [],
        sse: [],
        mutations: [],
        runtime: [],
    };
    window.__RECON__ = RECON;

    var FRAMEWORK_INTROSPECTOR = window.__FRAMEWORK_INTROSPECTOR__ || null;

    // The capture policy is engine-owned (panel/policy.rs) and injected by the
    // panel before this file runs (page.js::injectAndReload). There is no local
    // copy to drift from it, and a missing policy fails closed: zero budgets and
    // no redaction pattern, so nothing is decoded and nothing is kept.
    var POLICY = window.__CAPTURE_POLICY__ || null;
    function limit(name) {
        return POLICY && POLICY.limits ? POLICY.limits[name] || 0 : 0;
    }
    var TEXT_MIME_RE = new RegExp(POLICY ? POLICY.textMime : '$^', 'i');
    var GRAPHQL_URL = POLICY ? POLICY.graphqlUrl : '';

    // Mirrors the engine's `default_strategy` (panel/stackprofile.rs): the page
    // world needs usable timings before the panel's analysed profile arrives,
    // and the engine's test pins its defaults to these same values.
    function defaultStrategy() {
        return {
            profile: 'generic-app',
            bootDelayMs: 1200,
            networkQuietMs: 1000,
            mutationQuietMs: 1200,
            runtimeQuietMs: 1000,
            socketQuietMs: 2200,
            workerGraceMs: 1200,
            maxCaptureMs: 18000,
            preferHydratedDom: false,
            captureFrameworkState: false,
            captureGraphQLOps: false,
            prioritizeSourceMaps: false,
            reasons: ['Generic adaptive profile'],
        };
    }

    var SIGNALS = {
        startedAt: Date.now(),
        domContentLoadedAt: 0,
        loadEventAt: 0,
        activeRequests: 0,
        openSockets: 0,
        openSse: 0,
        workerCount: 0,
        serviceWorkerCount: 0,
        wasmCount: 0,
        runtimeCount: 0,
        resourceCount: 0,
        mutationCount: 0,
        graphqlCount: 0,
        lastNetworkAt: 0,
        lastMutationAt: 0,
        lastRuntimeAt: 0,
        lastSocketAt: 0,
        lastWorkerAt: 0,
    };
    window.__STACK_SIGNALS__ = SIGNALS;

    var CAPTURE_STATUS = {
        ready: false,
        startedAt: SIGNALS.startedAt,
        profile: 'generic-app',
        confidence: 0,
        technologies: [],
        reason: 'booting',
        reasonText: 'Booting adaptive capture profiler...',
        strategy: defaultStrategy(),
        signals: {},
        updatedAt: Date.now(),
    };
    window.__CAPTURE_STATUS__ = CAPTURE_STATUS;
    window.__STACK_PROFILE__ = {
        // The engine stamps the real version when it answers; this is the
        // placeholder the page world boots with.
        version: 'fallback',
        generatedAt: Date.now(),
        technologies: [],
        traits: [],
        confidence: 0,
        evidence: { technologies: {}, traits: {}, globals: [], endpoints: [] },
        strategy: CAPTURE_STATUS.strategy,
        summary: 'Booting profiler',
    };

    var profileRefreshTimer = null;
    var readinessTimer = null;

    function lower(value) {
        return String(value || '').toLowerCase();
    }

    function addUnique(list, value) {
        value = String(value || '').trim();
        if (value && list.indexOf(value) < 0) list.push(value);
    }

    function countRuntimeKind(kind) {
        var count = 0;
        for (var i = 0; i < RECON.runtime.length; i++) {
            if (RECON.runtime[i] && RECON.runtime[i].kind === kind) count++;
        }
        return count;
    }

    function countRuntimeKinds(kinds) {
        var count = 0;
        for (var i = 0; i < RECON.runtime.length; i++) {
            if (RECON.runtime[i] && kinds.indexOf(RECON.runtime[i].kind) >= 0) count++;
        }
        return count;
    }

    function findWindowKey(pattern) {
        try {
            for (var key in window) {
                if (pattern.test(key)) return true;
            }
        } catch (_) {}
        return false;
    }

    function getMetaContent(name) {
        try {
            var el = document.querySelector('meta[name="' + name + '"]');
            return el ? el.content || '' : '';
        } catch (_) {
            return '';
        }
    }

    function getResourceUrls() {
        var urls = [];
        for (var key in TRACKER.resources) {
            if (Object.prototype.hasOwnProperty.call(TRACKER.resources, key)) urls.push(key);
        }
        return urls.slice(0, 160);
    }

    function getScriptUrls() {
        var urls = [];
        var scripts = document.scripts || [];
        for (var i = 0; i < scripts.length; i++) {
            if (scripts[i] && scripts[i].src) urls.push(scripts[i].src);
        }
        return urls.slice(0, 80);
    }

    function looksLikeGraphQL(url, body) {
        if (GRAPHQL_URL && lower(url).indexOf(GRAPHQL_URL) >= 0) return true;
        if (!body) return false;
        if (typeof body === 'string') {
            return (
                /(?:^|\b)(query|mutation|subscription)\b/.test(body) ||
                body.indexOf('operationName') >= 0
            );
        }
        return typeof body === 'object' && (body.query || body.operationName || body.extensions);
    }

    function getGraphQLEndpoints() {
        var endpoints = [];
        var lists = [RECON.xhr, RECON.fetch];
        for (var i = 0; i < lists.length; i++) {
            for (var j = 0; j < lists[i].length; j++) {
                var entry = lists[i][j] || {};
                if (looksLikeGraphQL(entry.url, entry.requestBody))
                    addUnique(endpoints, entry.url || 'graphql');
            }
        }
        return endpoints.slice(0, 20);
    }

    function buildGlobalFlags() {
        var flags = {
            nextData: !!window.__NEXT_DATA__,
            reactDevtoolsHook: !!window.__REACT_DEVTOOLS_GLOBAL_HOOK__,
            nuxt: !!window.__NUXT__,
            vue: !!window.Vue || !!window.__VUE__,
            vueDevtoolsHook: !!window.__VUE_DEVTOOLS_GLOBAL_HOOK__,
            angular: !!window.ng || typeof window.getAllAngularRootElements === 'function',
            svelteKit: !!window.__SVELTEKIT_APP_VERSION__,
            remix: !!window.__remixContext,
            vitePreamble: !!window.__vite_plugin_react_preamble_installed__,
            webpackJsonp: !!window.webpackJsonp,
            webpackChunk: findWindowKey(/^webpackChunk/),
            shopify: !!window.Shopify,
            apolloClient: !!window.__APOLLO_CLIENT__,
            apolloState: !!window.__APOLLO_STATE__,
            relay: !!window.__RELAY_DEVTOOLS_HOOK__,
            serviceWorkerController: !!(
                navigator.serviceWorker && navigator.serviceWorker.controller
            ),
        };
        var detected = [];
        for (var key in flags)
            if (Object.prototype.hasOwnProperty.call(flags, key) && flags[key]) detected.push(key);
        flags.detected = detected;
        return flags;
    }

    function touchSignal(channel) {
        var now = Date.now();
        if (channel === 'network') SIGNALS.lastNetworkAt = now;
        if (channel === 'mutation') SIGNALS.lastMutationAt = now;
        if (channel === 'runtime') SIGNALS.lastRuntimeAt = now;
        if (channel === 'socket') SIGNALS.lastSocketAt = now;
        if (channel === 'worker') SIGNALS.lastWorkerAt = now;
    }

    function updateCaptureStatus(reason, reasonText) {
        CAPTURE_STATUS.reason = reason || CAPTURE_STATUS.reason;
        CAPTURE_STATUS.reasonText = reasonText || CAPTURE_STATUS.reasonText;
        CAPTURE_STATUS.updatedAt = Date.now();
        CAPTURE_STATUS.activity = {
            activeRequests: SIGNALS.activeRequests,
            openSockets: SIGNALS.openSockets,
            openSse: SIGNALS.openSse,
            workerCount: SIGNALS.workerCount,
            serviceWorkerCount: SIGNALS.serviceWorkerCount,
            wasmCount: SIGNALS.wasmCount,
            runtimeCount: SIGNALS.runtimeCount,
            resourceCount: SIGNALS.resourceCount,
            mutationCount: SIGNALS.mutationCount,
            graphqlCount: SIGNALS.graphqlCount,
            lastNetworkAt: SIGNALS.lastNetworkAt,
            lastMutationAt: SIGNALS.lastMutationAt,
            lastRuntimeAt: SIGNALS.lastRuntimeAt,
            lastSocketAt: SIGNALS.lastSocketAt,
            lastWorkerAt: SIGNALS.lastWorkerAt,
        };
    }

    function refreshFrameworkState(trigger) {
        if (!FRAMEWORK_INTROSPECTOR || typeof FRAMEWORK_INTROSPECTOR.refresh !== 'function') return;
        window.__FRAMEWORK_STATE__ = FRAMEWORK_INTROSPECTOR.refresh({
            reason: trigger || 'capture-refresh',
            stackProfile: window.__STACK_PROFILE__ || null,
            captureStatus: CAPTURE_STATUS,
        });
    }

    function refreshStackProfile(trigger) {
        var globals = buildGlobalFlags();
        var snapshot = {
            resourceUrls: getResourceUrls(),
            scriptUrls: getScriptUrls(),
            globals: globals,
            globalsDetected: globals.detected,
            dom: {
                metaGenerator: lower(getMetaContent('generator')),
                hasNextRoot: !!document.getElementById('__next'),
                hasNuxtRoot: !!document.getElementById('__nuxt'),
                hasVueApp: !!document.querySelector('[data-v-app],[data-vue-meta-server-rendered]'),
                hasNgVersion: !!document.querySelector('[ng-version]'),
                hasSvelteData: !!document.querySelector(
                    '[data-sveltekit-preload-data],[data-svelte-h]',
                ),
                hasAstroIsland: !!document.querySelector('astro-island'),
                hasRemixData: !!document.querySelector(
                    '[data-remix-run],script[type="application/remix-data"]',
                ),
                hasShopify: !!document.querySelector(
                    '[id^="shopify-section"],[data-shopify],meta[name="shopify-checkout-api-token"]',
                ),
                scriptCount: document.scripts ? document.scripts.length : 0,
                mutationCount: RECON.mutations.length,
            },
            network: {
                xhrCount: RECON.xhr.length,
                fetchCount: RECON.fetch.length,
                graphqlCount: SIGNALS.graphqlCount,
                graphqlEndpoints: getGraphQLEndpoints(),
                websocketCount: RECON.websockets.length,
                sseCount: RECON.sse.length,
                resourceCount: TRACKER.loaded.length,
            },
            runtime: {
                runtimeCount: RECON.runtime.length,
                wasmCount: countRuntimeKind('wasm'),
                workerCount: countRuntimeKinds(['worker', 'shared-worker']),
                serviceWorkerCount: countRuntimeKind('service-worker'),
            },
            activity: {
                openSockets: SIGNALS.openSockets + SIGNALS.openSse,
                workerCount: SIGNALS.workerCount,
                serviceWorkerCount: SIGNALS.serviceWorkerCount,
                wasmCount: SIGNALS.wasmCount,
            },
        };
        // The analysis runs in the panel's engine: publish the snapshot and read
        // back whatever profile the panel has pushed in. Until it arrives the
        // default strategy carries the capture, and every readiness gate below is
        // at least a second wide, so the analysed timings are always in place
        // before one can fire.
        window.__STACK_SNAPSHOT__ = snapshot;
        var profile = window.__STACK_PROFILE__ || {};
        CAPTURE_STATUS.profile =
            profile.strategy && profile.strategy.profile ? profile.strategy.profile : 'generic-app';
        CAPTURE_STATUS.confidence = profile.confidence || 0;
        CAPTURE_STATUS.technologies = profile.technologies || [];
        CAPTURE_STATUS.strategy = profile.strategy || CAPTURE_STATUS.strategy || defaultStrategy();
        updateCaptureStatus(trigger || 'profile-refresh', CAPTURE_STATUS.reasonText);
        refreshFrameworkState(trigger || 'profile-refresh');
    }

    function scheduleProfileRefresh(trigger) {
        if (profileRefreshTimer) return;
        profileRefreshTimer = setTimeout(function () {
            profileRefreshTimer = null;
            refreshStackProfile(trigger || 'refresh');
            evaluateReadiness(trigger || 'refresh');
        }, 150);
    }

    function isQuiet(lastSeenAt, quietMs, now) {
        return !lastSeenAt || now - lastSeenAt >= quietMs;
    }

    function finishReady(reason, reasonText) {
        window.__RESOURCE_TRACKER_READY__ = true;
        CAPTURE_STATUS.ready = true;
        updateCaptureStatus(reason, reasonText);
        refreshFrameworkState(reason || 'ready');
        if (readinessTimer) {
            clearInterval(readinessTimer);
            readinessTimer = null;
        }
    }

    function evaluateReadiness(trigger) {
        var now = Date.now();
        var strategy = CAPTURE_STATUS.strategy || defaultStrategy();
        var elapsed = now - SIGNALS.startedAt;
        var domReady = document.readyState === 'complete' || elapsed >= strategy.bootDelayMs;
        var networkQuiet =
            SIGNALS.activeRequests === 0 &&
            isQuiet(SIGNALS.lastNetworkAt, strategy.networkQuietMs, now);
        var mutationQuiet = isQuiet(SIGNALS.lastMutationAt, strategy.mutationQuietMs, now);
        var runtimeQuiet = isQuiet(SIGNALS.lastRuntimeAt, strategy.runtimeQuietMs, now);
        var socketQuiet = isQuiet(SIGNALS.lastSocketAt, strategy.socketQuietMs, now);
        var workerQuiet = isQuiet(SIGNALS.lastWorkerAt, strategy.workerGraceMs, now);

        CAPTURE_STATUS.signals = {
            domReady: domReady,
            networkQuiet: networkQuiet,
            mutationQuiet: mutationQuiet,
            runtimeQuiet: runtimeQuiet,
            socketQuiet: socketQuiet,
            workerQuiet: workerQuiet,
            elapsedMs: elapsed,
        };

        if (window.__RESOURCE_TRACKER_READY__) return;
        if (elapsed >= strategy.maxCaptureMs)
            return finishReady(
                'max-capture',
                'Adaptive max capture window reached for ' + strategy.profile + '.',
            );
        if (
            domReady &&
            networkQuiet &&
            mutationQuiet &&
            runtimeQuiet &&
            socketQuiet &&
            workerQuiet
        ) {
            return finishReady(
                'quiet-window',
                'Adaptive quiet window satisfied for ' + strategy.profile + '.',
            );
        }

        var waitingOn = [];
        if (!domReady) waitingOn.push('document readiness');
        if (!networkQuiet)
            waitingOn.push(
                SIGNALS.activeRequests > 0
                    ? SIGNALS.activeRequests + ' network request(s)'
                    : 'network quiet window',
            );
        if (!mutationQuiet) waitingOn.push('DOM mutations');
        if (!runtimeQuiet) waitingOn.push('runtime code activity');
        if (!socketQuiet) waitingOn.push('socket activity');
        if (!workerQuiet) waitingOn.push('worker activity');
        updateCaptureStatus(
            trigger || 'capturing',
            'Adaptive capture waiting on ' + waitingOn.slice(0, 3).join(', ') + '.',
        );
    }

    var textEncoder = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
    var textDecoder = typeof TextDecoder !== 'undefined' ? new TextDecoder() : null;
    var NativeBlob = typeof Blob !== 'undefined' ? Blob : null;
    var blobRecords = typeof WeakMap !== 'undefined' ? new WeakMap() : null;
    var blobUrlLookup = {};

    function assign(target, source) {
        for (var key in source) {
            if (Object.prototype.hasOwnProperty.call(source, key) && source[key] !== undefined) {
                target[key] = source[key];
            }
        }
        return target;
    }

    function currentStack() {
        try {
            throw new Error('runtime-capture');
        } catch (err) {
            if (!err || !err.stack) return '';
            return String(err.stack).split('\n').slice(2, 8).join('\n');
        }
    }

    function captureRuntime(kind, payload) {
        if (RECON.runtime.length >= limit('runtimeItems')) return null;
        var entry = assign(
            {
                id: kind + '-' + String(RECON.runtime.length + 1),
                kind: kind,
                timestamp: Date.now(),
            },
            payload || {},
        );
        RECON.runtime.push(entry);
        SIGNALS.runtimeCount = RECON.runtime.length;
        SIGNALS.wasmCount = countRuntimeKind('wasm');
        SIGNALS.workerCount = countRuntimeKinds(['worker', 'shared-worker']);
        SIGNALS.serviceWorkerCount = countRuntimeKind('service-worker');
        touchSignal('runtime');
        if (
            kind === 'worker' ||
            kind === 'shared-worker' ||
            kind === 'service-worker' ||
            kind === 'wasm'
        )
            touchSignal('worker');
        scheduleProfileRefresh('runtime-' + kind);
        return entry;
    }

    function stringToBytes(text) {
        text = String(text == null ? '' : text);
        if (textEncoder) return textEncoder.encode(text);
        var bytes = new Uint8Array(text.length);
        for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 255;
        return bytes;
    }

    function cloneBytes(source) {
        if (!source) return new Uint8Array(0);
        if (source instanceof ArrayBuffer) {
            var bufferBytes = new Uint8Array(source);
            var bufferCopy = new Uint8Array(bufferBytes.length);
            bufferCopy.set(bufferBytes);
            return bufferCopy;
        }
        if (
            typeof ArrayBuffer !== 'undefined' &&
            typeof ArrayBuffer.isView === 'function' &&
            ArrayBuffer.isView(source)
        ) {
            var viewBytes = new Uint8Array(
                source.buffer,
                source.byteOffset || 0,
                source.byteLength,
            );
            var viewCopy = new Uint8Array(viewBytes.length);
            viewCopy.set(viewBytes);
            return viewCopy;
        }
        return new Uint8Array(0);
    }

    function concatBytes(chunks) {
        var total = 0;
        for (var i = 0; i < chunks.length; i++) total += chunks[i].length;
        var out = new Uint8Array(total);
        var offset = 0;
        for (var j = 0; j < chunks.length; j++) {
            out.set(chunks[j], offset);
            offset += chunks[j].length;
        }
        return out;
    }

    function bytesToText(bytes) {
        if (textDecoder) return textDecoder.decode(bytes);
        var text = '';
        for (var i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
        return text;
    }

    function bytesToBase64(bytes) {
        var binary = '';
        for (var i = 0; i < bytes.length; i += 32768) {
            var chunk = bytes.subarray(i, Math.min(i + 32768, bytes.length));
            binary += String.fromCharCode.apply(null, chunk);
        }
        return btoa(binary);
    }

    function looksLikeText(bytes) {
        if (!bytes || !bytes.length) return false;
        var sample = Math.min(bytes.length, 256);
        var suspicious = 0;
        for (var i = 0; i < sample; i++) {
            if (bytes[i] === 0) return false;
            if (bytes[i] < 9 || (bytes[i] > 13 && bytes[i] < 32)) suspicious++;
        }
        return suspicious <= Math.max(3, Math.floor(sample / 12));
    }

    function isTextMime(mimeType) {
        return TEXT_MIME_RE.test(mimeType || '');
    }

    function limitText(text) {
        text = String(text == null ? '' : text);
        return {
            text: text.slice(0, limit('runtimeText')),
            length: text.length,
            truncated: text.length > limit('runtimeText'),
        };
    }

    function limitBytes(bytes) {
        var byteLength = bytes ? bytes.length : 0;
        return {
            bytes:
                byteLength > limit('runtimeBinary')
                    ? bytes.subarray(0, limit('runtimeBinary'))
                    : bytes,
            length: byteLength,
            truncated: byteLength > limit('runtimeBinary'),
        };
    }

    function captureTextRuntime(kind, text, meta) {
        var limited = limitText(text);
        return captureRuntime(
            kind,
            assign(
                {
                    text: limited.text,
                    textLength: limited.length,
                    truncated: limited.truncated,
                },
                meta || {},
            ),
        );
    }

    function captureBinaryRuntime(kind, bytes, meta) {
        var limited = limitBytes(bytes || new Uint8Array(0));
        return captureRuntime(
            kind,
            assign(
                {
                    base64: bytesToBase64(limited.bytes),
                    byteLength: limited.length,
                    truncated: limited.truncated,
                },
                meta || {},
            ),
        );
    }

    function parseDataUrl(url) {
        var match = /^data:([^;,]*)(;base64)?,([\s\S]*)$/.exec(url || '');
        if (!match) return null;
        var mimeType = match[1] || '';
        if (match[2]) {
            var raw = atob(match[3]);
            var bytes = new Uint8Array(raw.length);
            for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
            return {
                mimeType: mimeType,
                bytes: bytes,
                text: isTextMime(mimeType) || looksLikeText(bytes) ? bytesToText(bytes) : null,
            };
        }
        var text = decodeURIComponent(match[3]);
        return { mimeType: mimeType, bytes: stringToBytes(text), text: text };
    }

    function normalizeBlobParts(parts) {
        var chunks = [];
        var nestedBlobCount = 0;
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (NativeBlob && part instanceof NativeBlob) {
                nestedBlobCount++;
                continue;
            }
            if (typeof part === 'string') {
                chunks.push(stringToBytes(part));
                continue;
            }
            var bytes = cloneBytes(part);
            if (bytes.length) {
                chunks.push(bytes);
                continue;
            }
            if (part != null) chunks.push(stringToBytes(part));
        }
        return { bytes: concatBytes(chunks), nestedBlobCount: nestedBlobCount };
    }

    function captureBlob(blob, parts, options) {
        var mimeType = (options && options.type) || blob.type || '';
        var normalized = normalizeBlobParts(parts || []);
        var bytes = normalized.bytes;
        var meta = {
            mimeType: mimeType,
            size: blob.size || bytes.length,
            source: 'Blob',
            stack: currentStack(),
        };
        if (normalized.nestedBlobCount)
            meta.note = 'Contains ' + normalized.nestedBlobCount + ' nested Blob part(s)';
        var entry;
        if (!bytes.length) {
            entry = captureRuntime('blob', meta);
        } else if (isTextMime(mimeType) || looksLikeText(bytes)) {
            meta.byteLength = bytes.length;
            entry = captureTextRuntime('blob', bytesToText(bytes), meta);
        } else {
            entry = captureBinaryRuntime('blob', bytes, meta);
        }
        if (blobRecords && entry) blobRecords.set(blob, entry);
    }

    function captureUrlRuntime(kind, url, meta) {
        url = url ? String(url) : '';
        var payload = assign({ url: url }, meta || {});
        if (!url) return captureRuntime(kind, payload);
        if (url.indexOf('data:') === 0) {
            var parsed = parseDataUrl(url);
            if (!parsed) return captureRuntime(kind, payload);
            payload.mimeType = parsed.mimeType;
            if (parsed.text != null) return captureTextRuntime(kind, parsed.text, payload);
            return captureBinaryRuntime(kind, parsed.bytes, payload);
        }
        if (blobUrlLookup[url]) payload.blobId = blobUrlLookup[url];
        return captureRuntime(kind, payload);
    }

    function captureInlineScriptElement(el, source) {
        if (!el || el.__runtimeScriptCaptured || (el.tagName || '').toLowerCase() !== 'script')
            return;
        el.__runtimeScriptCaptured = true;
        var meta = {
            source: source,
            scriptType: el.type || 'classic',
            stack: currentStack(),
        };
        if (el.src) {
            captureUrlRuntime('script-injection', el.src, meta);
            return;
        }
        var text = el.text || el.textContent || '';
        if (text) captureTextRuntime('script-injection', text, meta);
    }

    if (typeof PerformanceObserver !== 'undefined') {
        try {
            var po = new PerformanceObserver(function (list) {
                var entries = list.getEntries();
                for (var i = 0; i < entries.length; i++) {
                    var entry = entries[i];
                    if (entry.entryType !== 'resource') continue;
                    var url = entry.name;
                    if (!url || url.indexOf('data:') === 0 || url.indexOf('blob:') === 0) continue;
                    var resource = TRACKER.resources[url];
                    if (!resource) {
                        resource = {
                            url: url,
                            type: entry.initiatorType || 'other',
                            source: 'network',
                            status: 'loaded',
                            size: entry.transferSize || 0,
                            duration: Math.round(entry.duration * 100) / 100,
                            time: Date.now(),
                        };
                        TRACKER.resources[url] = resource;
                        TRACKER.loaded.push(resource);
                    } else {
                        resource.size = Math.max(resource.size, entry.transferSize || 0);
                        resource.duration = entry.duration || resource.duration;
                    }
                }
                SIGNALS.resourceCount = TRACKER.loaded.length;
                touchSignal('network');
                scheduleProfileRefresh('performance-observer');
            });
            po.observe({ type: 'resource', buffered: true });
        } catch (_) {}
    }

    if (typeof XMLHttpRequest !== 'undefined') {
        var _xhrOpen = XMLHttpRequest.prototype.open;
        var _xhrSend = XMLHttpRequest.prototype.send;
        var _xhrSetReqHdr = XMLHttpRequest.prototype.setRequestHeader;

        XMLHttpRequest.prototype.open = function (method, url) {
            this.__recon_method = method;
            this.__recon_url = url;
            this.__recon_reqHeaders = {};
            return _xhrOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
            if (!this.__recon_reqHeaders) this.__recon_reqHeaders = {};
            this.__recon_reqHeaders[name] = value;
            return _xhrSetReqHdr.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function (body) {
            var self = this;
            var entry = {
                method: this.__recon_method || 'GET',
                url: this.__recon_url || '',
                requestHeaders: this.__recon_reqHeaders || {},
                requestBody: body || null,
                timestamp: Date.now(),
            };
            var origReady = this.onreadystatechange;
            var origError = this.onerror;
            var finished = false;

            SIGNALS.activeRequests++;
            touchSignal('network');
            scheduleProfileRefresh('xhr-start');

            function finishRequest(status, statusText) {
                if (finished) return;
                finished = true;
                SIGNALS.activeRequests = Math.max(0, SIGNALS.activeRequests - 1);
                if (status !== undefined) entry.status = status;
                if (statusText !== undefined) entry.statusText = statusText;
                entry.completed = Date.now();
                RECON.xhr.push(entry);
                if (looksLikeGraphQL(entry.url, entry.requestBody)) SIGNALS.graphqlCount++;
                touchSignal('network');
                scheduleProfileRefresh('xhr-complete');
            }

            this.onreadystatechange = function () {
                if (self.readyState === 4) {
                    entry.status = self.status;
                    entry.statusText = self.statusText;
                    entry.responseHeaders = self.getAllResponseHeaders();
                    entry.responseBody = self.responseText
                        ? self.responseText.substring(0, 10000)
                        : null;
                    entry.responseSize = self.responseText ? self.responseText.length : 0;
                    finishRequest();
                }
                if (origReady) origReady.apply(self, arguments);
            };

            this.onerror = function () {
                finishRequest(0, 'Network Error');
                if (origError) origError.apply(self, arguments);
            };

            return _xhrSend.apply(this, arguments);
        };
    }

    if (typeof fetch !== 'undefined') {
        var _fetch = fetch;
        window.fetch = function (input, init) {
            var url = typeof input === 'string' ? input : input && input.url ? input.url : '';
            var method = (init && init.method) || 'GET';
            var headers = init && init.headers ? init.headers : {};
            var body = init && init.body ? init.body : null;
            var entry = {
                method: method,
                url: url,
                requestHeaders: headers,
                requestBody: body,
                timestamp: Date.now(),
            };
            var reqHeaders = {};
            if (headers && typeof headers.entries === 'function') {
                try {
                    var iter = headers.entries();
                    for (var h = iter.next(); !h.done; h = iter.next())
                        reqHeaders[h.value[0]] = h.value[1];
                } catch (_) {}
            } else if (headers && typeof headers === 'object') {
                for (var key in headers)
                    if (Object.prototype.hasOwnProperty.call(headers, key))
                        reqHeaders[key] = headers[key];
            }
            entry.requestHeaders = reqHeaders;

            SIGNALS.activeRequests++;
            touchSignal('network');
            scheduleProfileRefresh('fetch-start');

            return _fetch
                .call(this, input, init)
                .then(function (response) {
                    entry.status = response.status;
                    entry.statusText = response.statusText;
                    var respHeaders = {};
                    response.headers.forEach(function (value, key) {
                        respHeaders[key] = value;
                    });
                    entry.responseHeaders = respHeaders;
                    entry.completed = Date.now();
                    response
                        .clone()
                        .text()
                        .then(function (text) {
                            entry.responseBody = text ? text.substring(0, 10000) : null;
                            entry.responseSize = text ? text.length : 0;
                        })
                        .catch(function () {
                            entry.responseBody =
                                '[binary/stream: ' +
                                (response.headers.get('content-type') || 'unknown') +
                                ']';
                        });
                    RECON.fetch.push(entry);
                    SIGNALS.activeRequests = Math.max(0, SIGNALS.activeRequests - 1);
                    if (looksLikeGraphQL(entry.url, entry.requestBody)) SIGNALS.graphqlCount++;
                    touchSignal('network');
                    scheduleProfileRefresh('fetch-complete');
                    return response;
                })
                .catch(function (err) {
                    entry.status = 0;
                    entry.statusText = 'Network Error';
                    entry.completed = Date.now();
                    RECON.fetch.push(entry);
                    SIGNALS.activeRequests = Math.max(0, SIGNALS.activeRequests - 1);
                    if (looksLikeGraphQL(entry.url, entry.requestBody)) SIGNALS.graphqlCount++;
                    touchSignal('network');
                    scheduleProfileRefresh('fetch-error');
                    throw err;
                });
        };
    }

    if (typeof WebSocket !== 'undefined') {
        var _WS = WebSocket;
        window.WebSocket = function (url, protocols) {
            var instance = protocols ? new _WS(url, protocols) : new _WS(url);
            var entry = { url: url, opened: Date.now(), closed: null, messages: [] };
            var origSend = instance.send;
            SIGNALS.openSockets++;
            touchSignal('socket');
            scheduleProfileRefresh('websocket-open');
            instance.send = function (data) {
                entry.messages.push({
                    direction: 'out',
                    data: typeof data === 'string' ? data.substring(0, 2000) : '[binary]',
                    timestamp: Date.now(),
                });
                touchSignal('socket');
                return origSend.call(instance, data);
            };
            instance.addEventListener('message', function (event) {
                var message = event.data;
                if (typeof message !== 'string') {
                    try {
                        message = JSON.stringify(message);
                    } catch (_) {
                        message = '[binary]';
                    }
                }
                entry.messages.push({
                    direction: 'in',
                    data: message ? message.substring(0, 2000) : '',
                    timestamp: Date.now(),
                });
                touchSignal('socket');
                scheduleProfileRefresh('websocket-message');
            });
            instance.addEventListener('close', function () {
                entry.closed = Date.now();
                SIGNALS.openSockets = Math.max(0, SIGNALS.openSockets - 1);
                touchSignal('socket');
                scheduleProfileRefresh('websocket-close');
            });
            RECON.websockets.push(entry);
            return instance;
        };
        window.WebSocket.prototype = _WS.prototype;
        window.WebSocket.CONNECTING = _WS.CONNECTING;
        window.WebSocket.OPEN = _WS.OPEN;
        window.WebSocket.CLOSING = _WS.CLOSING;
        window.WebSocket.CLOSED = _WS.CLOSED;
    }

    if (typeof EventSource !== 'undefined') {
        var _ES = EventSource;
        window.EventSource = function (url, config) {
            var instance = config ? new _ES(url, config) : new _ES(url);
            var entry = { url: url, opened: Date.now(), events: [] };
            SIGNALS.openSse++;
            touchSignal('socket');
            scheduleProfileRefresh('sse-open');
            instance.addEventListener('message', function (event) {
                entry.events.push({
                    type: event.type || 'message',
                    data: event.data ? event.data.substring(0, 2000) : '',
                    timestamp: Date.now(),
                });
                touchSignal('socket');
                scheduleProfileRefresh('sse-message');
            });
            instance.addEventListener('error', function () {
                if (instance.readyState === _ES.CLOSED) {
                    SIGNALS.openSse = Math.max(0, SIGNALS.openSse - 1);
                    touchSignal('socket');
                    scheduleProfileRefresh('sse-close');
                }
            });
            var addEventListener = instance.addEventListener;
            instance.addEventListener = function (type, listener, options) {
                if (type && type !== 'message' && type !== 'error' && type !== 'open') {
                    entry.events.push({
                        type: type,
                        data: '[custom event listener attached]',
                        timestamp: Date.now(),
                    });
                }
                return addEventListener.call(instance, type, listener, options);
            };
            RECON.sse.push(entry);
            return instance;
        };
        window.EventSource.prototype = _ES.prototype;
        window.EventSource.CONNECTING = _ES.CONNECTING;
        window.EventSource.OPEN = _ES.OPEN;
        window.EventSource.CLOSED = _ES.CLOSED;
    }

    if (typeof window.eval === 'function') {
        var _eval = window.eval;
        window.eval = function (code) {
            if (typeof code === 'string' && code)
                captureTextRuntime('eval', code, { source: 'window.eval', stack: currentStack() });
            return _eval.apply(this, arguments);
        };
    }

    if (typeof Function === 'function') {
        var NativeFunction = Function;
        window.Function = function () {
            var args = Array.prototype.slice.call(arguments);
            var params = args.length > 1 ? args.slice(0, -1).map(String) : [];
            var body = args.length ? String(args[args.length - 1]) : '';
            if (body) {
                captureTextRuntime(
                    'function',
                    'function anonymous(' + params.join(', ') + ') {\n' + body + '\n}',
                    {
                        params: params,
                        source: 'Function',
                        stack: currentStack(),
                    },
                );
            }
            return NativeFunction.apply(this, args);
        };
        window.Function.prototype = NativeFunction.prototype;
    }

    if (NativeBlob) {
        window.Blob = function (parts, options) {
            var blob = new NativeBlob(parts, options);
            captureBlob(blob, parts || [], options || {});
            return blob;
        };
        window.Blob.prototype = NativeBlob.prototype;
    }

    if (window.URL && typeof window.URL.createObjectURL === 'function') {
        var _createObjectURL = window.URL.createObjectURL;
        window.URL.createObjectURL = function (object) {
            var url = _createObjectURL.apply(this, arguments);
            if (blobRecords && object && blobRecords.has(object)) {
                var entry = blobRecords.get(object);
                entry.objectUrl = url;
                blobUrlLookup[url] = entry.id;
            }
            return url;
        };
    }

    if (typeof Worker !== 'undefined') {
        var NativeWorker = Worker;
        window.Worker = function (url, options) {
            captureUrlRuntime('worker', url, {
                workerType: options && options.type ? options.type : 'classic',
                stack: currentStack(),
            });
            touchSignal('worker');
            scheduleProfileRefresh('worker');
            return new NativeWorker(url, options);
        };
        window.Worker.prototype = NativeWorker.prototype;
    }

    if (typeof SharedWorker !== 'undefined') {
        var NativeSharedWorker = SharedWorker;
        window.SharedWorker = function (url, nameOrOptions) {
            captureUrlRuntime('shared-worker', url, { stack: currentStack() });
            touchSignal('worker');
            scheduleProfileRefresh('shared-worker');
            return arguments.length > 1
                ? new NativeSharedWorker(url, nameOrOptions)
                : new NativeSharedWorker(url);
        };
        window.SharedWorker.prototype = NativeSharedWorker.prototype;
    }

    if (navigator.serviceWorker && typeof navigator.serviceWorker.register === 'function') {
        var _registerServiceWorker = navigator.serviceWorker.register;
        navigator.serviceWorker.register = function (url, options) {
            captureUrlRuntime('service-worker', url, {
                scope: options && options.scope ? options.scope : '',
                updateViaCache: options && options.updateViaCache ? options.updateViaCache : '',
                stack: currentStack(),
            });
            touchSignal('worker');
            scheduleProfileRefresh('service-worker');
            return _registerServiceWorker.apply(this, arguments);
        };
    }

    if (typeof WebAssembly !== 'undefined') {
        function captureWasmSource(source, meta) {
            if (!source) {
                captureRuntime('wasm', assign({ note: 'Missing WebAssembly source' }, meta || {}));
                return;
            }
            if (typeof source.arrayBuffer === 'function') {
                source
                    .arrayBuffer()
                    .then(function (buffer) {
                        captureBinaryRuntime(
                            'wasm',
                            cloneBytes(buffer),
                            assign({ mimeType: 'application/wasm' }, meta || {}),
                        );
                    })
                    .catch(function (err) {
                        captureRuntime(
                            'wasm',
                            assign(
                                {
                                    note:
                                        'Failed to read WebAssembly source: ' +
                                        (err && err.message ? err.message : String(err)),
                                },
                                meta || {},
                            ),
                        );
                    });
                return;
            }
            var bytes = cloneBytes(source);
            if (bytes.length) {
                captureBinaryRuntime(
                    'wasm',
                    bytes,
                    assign({ mimeType: 'application/wasm' }, meta || {}),
                );
                return;
            }
            captureRuntime(
                'wasm',
                assign({ note: 'Unsupported WebAssembly source type' }, meta || {}),
            );
        }

        function captureWasmResponse(response, meta) {
            if (!response || typeof response.clone !== 'function') {
                captureRuntime('wasm', assign({ note: 'Missing streaming response' }, meta || {}));
                return;
            }
            response
                .clone()
                .arrayBuffer()
                .then(function (buffer) {
                    captureBinaryRuntime(
                        'wasm',
                        cloneBytes(buffer),
                        assign(
                            {
                                url: response.url || '',
                                mimeType:
                                    response.headers && typeof response.headers.get === 'function'
                                        ? response.headers.get('content-type') || 'application/wasm'
                                        : 'application/wasm',
                            },
                            meta || {},
                        ),
                    );
                })
                .catch(function (err) {
                    captureRuntime(
                        'wasm',
                        assign(
                            {
                                note:
                                    'Failed to clone streaming WebAssembly response: ' +
                                    (err && err.message ? err.message : String(err)),
                            },
                            meta || {},
                        ),
                    );
                });
        }

        if (typeof WebAssembly.instantiate === 'function') {
            var _wasmInstantiate = WebAssembly.instantiate;
            WebAssembly.instantiate = function (source, _imports) {
                captureWasmSource(source, {
                    source: 'WebAssembly.instantiate',
                    stack: currentStack(),
                });
                return _wasmInstantiate.apply(this, arguments);
            };
        }
        if (typeof WebAssembly.compile === 'function') {
            var _wasmCompile = WebAssembly.compile;
            WebAssembly.compile = function (source) {
                captureWasmSource(source, { source: 'WebAssembly.compile', stack: currentStack() });
                return _wasmCompile.apply(this, arguments);
            };
        }
        if (typeof WebAssembly.instantiateStreaming === 'function') {
            var _wasmInstantiateStreaming = WebAssembly.instantiateStreaming;
            WebAssembly.instantiateStreaming = function (source, _imports) {
                Promise.resolve(source).then(function (response) {
                    captureWasmResponse(response, {
                        source: 'WebAssembly.instantiateStreaming',
                        stack: currentStack(),
                    });
                });
                return _wasmInstantiateStreaming.apply(this, arguments);
            };
        }
        if (typeof WebAssembly.compileStreaming === 'function') {
            var _wasmCompileStreaming = WebAssembly.compileStreaming;
            WebAssembly.compileStreaming = function (source) {
                Promise.resolve(source).then(function (response) {
                    captureWasmResponse(response, {
                        source: 'WebAssembly.compileStreaming',
                        stack: currentStack(),
                    });
                });
                return _wasmCompileStreaming.apply(this, arguments);
            };
        }
    }

    function recordMutation(mutation) {
        if (RECON.mutations.length >= limit('mutations')) return;
        RECON.mutations.push({
            type: mutation.type,
            target: getNodePath(mutation.target),
            addedNodes: mutation.addedNodes ? getNodeList(mutation.addedNodes, 3) : [],
            removedNodes: mutation.removedNodes ? getNodeList(mutation.removedNodes, 3) : [],
            attributeName: mutation.attributeName || null,
            oldValue: mutation.oldValue ? mutation.oldValue.substring(0, 200) : null,
            textContent:
                mutation.type === 'characterData'
                    ? (mutation.target.textContent || '').substring(0, 200)
                    : null,
            timestamp: Date.now(),
        });
        SIGNALS.mutationCount = RECON.mutations.length;
        touchSignal('mutation');
        scheduleProfileRefresh('mutation');
    }

    function getNodePath(node) {
        if (!node || !node.nodeType) return 'unknown';
        if (node === document) return '#document';
        if (node === document.documentElement) return '<html>';
        if (node === document.body) return '<body>';
        if (node === document.head) return '<head>';
        if (node.nodeType === 3) return '#text';
        if (node.nodeType === 8) return '#comment';
        var tag = (node.tagName || '').toLowerCase();
        var id = node.id ? '#' + node.id : '';
        var cls =
            node.className && typeof node.className === 'string'
                ? '.' + node.className.trim().split(/\s+/)[0]
                : '';
        return tag + id + cls || 'element';
    }

    function getNodeList(nodeList, max) {
        var arr = [];
        for (var i = 0; i < nodeList.length && i < max; i++) arr.push(getNodePath(nodeList[i]));
        if (nodeList.length > max) arr.push('... (+' + (nodeList.length - max) + ' more)');
        return arr;
    }

    if (typeof MutationObserver !== 'undefined') {
        try {
            var mo = new MutationObserver(function (mutations) {
                for (var i = 0; i < mutations.length; i++) recordMutation(mutations[i]);
            });
            // Observing `document` rather than `document.documentElement`:
            // the panel injects this script BEFORE the page loads
            // (`inspectedWindow.reload({ injectedScript })`), so at this point
            // documentElement is still null, observe() throws, and the catch
            // below swallowed it - no mutation was ever recorded. `document`
            // exists from the start and its subtree covers the document
            // element once it appears.
            mo.observe(document, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeOldValue: true,
                characterData: true,
            });
        } catch (_) {}
    }

    function getElementUrl(el) {
        var tag = (el.tagName || '').toLowerCase();
        if (!tag) return null;
        if (tag === 'script') {
            if (el.src) return el.src;
            var text = (el.textContent || '').substring(0, 80).replace(/\s+/g, ' ');
            return 'inline-script:' + (text || 'empty');
        }
        if (tag === 'link' && el.rel === 'stylesheet' && el.href) return el.href;
        if (tag === 'style')
            return (
                'inline-style:' +
                ((el.textContent || '').substring(0, 40).replace(/\s+/g, ' ') || 'empty')
            );
        if (tag === 'img') return el.src || el.getAttribute('data-src') || null;
        if (tag === 'video') return el.src || null;
        if (tag === 'audio') return el.src || null;
        if (tag === 'source') return el.src || el.srcset || null;
        if (tag === 'track') return el.src || null;
        if (tag === 'iframe') return el.src || null;
        if (tag === 'embed') return el.src || null;
        if (tag === 'object') return el.data || null;
        if (tag === 'link' && el.href) return el.href;
        return null;
    }

    function trackResourceAttach(el, source) {
        if (!el || !el.nodeType) return;
        captureInlineScriptElement(el, source);
        var url = getElementUrl(el);
        if (!url) return;
        var resource = TRACKER.resources[url];
        if (!resource) {
            resource = {
                url: url,
                type: (el.tagName || '').toLowerCase(),
                source: source,
                status: 'loaded',
                size: 0,
                time: Date.now(),
            };
            TRACKER.resources[url] = resource;
            TRACKER.loaded.push(resource);
            SIGNALS.resourceCount = TRACKER.loaded.length;
        }
        touchSignal('mutation');
        scheduleProfileRefresh('resource-attach');
    }

    function trackResourceDetach(el) {
        if (!el || !el.nodeType) return;
        var url = getElementUrl(el);
        if (!url) return;
        var resource = TRACKER.resources[url];
        if (resource && resource.status === 'loaded') {
            resource.status = 'unloaded';
            resource.unloadedTime = Date.now();
            TRACKER.unloaded.push(resource);
        }
        touchSignal('mutation');
        scheduleProfileRefresh('resource-detach');
    }

    if (typeof document.createElement === 'function') {
        var _createElement = document.createElement;
        document.createElement = function (tagName, options) {
            var el = _createElement.call(document, tagName, options);
            el.__track_tag = tagName;
            el.__track_ts = Date.now();
            return el;
        };
    }

    var _appendChild = Node.prototype.appendChild;
    Node.prototype.appendChild = function (child) {
        trackResourceAttach(child, 'appendChild');
        return _appendChild.call(this, child);
    };

    var _insertBefore = Node.prototype.insertBefore;
    Node.prototype.insertBefore = function (newNode, refNode) {
        trackResourceAttach(newNode, 'insertBefore');
        return _insertBefore.call(this, newNode, refNode);
    };

    var _removeChild = Element.prototype.removeChild;
    Element.prototype.removeChild = function (child) {
        trackResourceDetach(child);
        return _removeChild.call(this, child);
    };

    var _replaceChild = Node.prototype.replaceChild;
    Node.prototype.replaceChild = function (newChild, oldChild) {
        trackResourceDetach(oldChild);
        trackResourceAttach(newChild, 'replaceChild');
        return _replaceChild.call(this, newChild, oldChild);
    };

    document.addEventListener('DOMContentLoaded', function () {
        SIGNALS.domContentLoadedAt = Date.now();
        scheduleProfileRefresh('domcontentloaded');
    });

    window.addEventListener('load', function () {
        SIGNALS.loadEventAt = Date.now();
        scheduleProfileRefresh('load');
    });

    scheduleProfileRefresh('boot');
    readinessTimer = setInterval(function () {
        evaluateReadiness('interval');
    }, 500);
})();
