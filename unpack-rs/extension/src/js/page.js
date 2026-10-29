import JSZip from 'jszip';
import { saveAs } from 'file-saver';
import {
    unpackAssetsIntoZip,
    beautifyJs,
    looksMinified,
    looksBinaryScript,
    decodeBase64ToBytes,
    panelTrackerView,
} from './unpack-bridge.js';

var reloadDebugBtn = document.getElementById('reloadDebugBtn');
var downloadBtn = document.getElementById('downloadBtn');
var pageOriginEl = document.getElementById('pageOrigin');
var stackBadges = document.getElementById('stackBadges');
var captureProfileEl = document.getElementById('captureProfile');
var captureConfidenceEl = document.getElementById('captureConfidence');
var captureReasonEl = document.getElementById('captureReason');
var activityBanner = document.getElementById('activityBanner');
var activityText = document.getElementById('activityText');
var statusBar = document.getElementById('statusBar');
var loadedCountEl = document.getElementById('loadedCount');
var unloadedCountEl = document.getElementById('unloadedCount');
var visibleCountEl = document.getElementById('visibleCount');
var totalCountEl = document.getElementById('totalCount');
var resourceSearch = document.getElementById('resourceSearch');
var statusFilter = document.getElementById('statusFilter');
var typeFilter = document.getElementById('typeFilter');
var sortOrder = document.getElementById('sortOrder');
var resourceList = document.getElementById('resourceList');
var resourceBody = document.getElementById('resourceBody');
var emptyState = document.getElementById('emptyState');

var pollingTimer = null;
var isPolling = false;
var onPollComplete = null;
var latestTracker = null;
var latestStackProfile = null;
var latestCaptureStatus = null;

resourceSearch.oninput = renderTrackerView;
statusFilter.onchange = renderTrackerView;
typeFilter.onchange = renderTrackerView;
sortOrder.onchange = renderTrackerView;

function setActivity(tone, text) {
    activityBanner.className = 'notification is-light p-2 mb-0 is-' + (tone || 'info');
    activityText.textContent = text || '';
    activityBanner.style.display = text ? 'block' : 'none';
}

function clearActivity() {
    activityBanner.style.display = 'none';
    activityText.textContent = '';
}

function renderPageOrigin(site) {
    if (!site) {
        pageOriginEl.textContent = 'Awaiting inspected page';
        pageOriginEl.title = '';
        return;
    }
    var label = site.origin || site.url || site.title || 'Inspected page';
    pageOriginEl.textContent = label;
    pageOriginEl.title = [site.title || '', site.url || label].filter(Boolean).join('\n');
}

function renderStackProfile(profile, captureStatus) {
    latestStackProfile = profile || latestStackProfile;
    latestCaptureStatus = captureStatus || latestCaptureStatus;
    var activeProfile = latestStackProfile;
    var activeStatus = latestCaptureStatus;
    stackBadges.innerHTML = '';

    var labels = [];
    if (activeProfile && activeProfile.technologies && activeProfile.technologies.length) {
        for (var i = 0; i < activeProfile.technologies.length && i < 5; i++)
            labels.push(activeProfile.technologies[i].name);
    }
    if (!labels.length && activeProfile && activeProfile.traits) {
        for (var j = 0; j < activeProfile.traits.length && j < 3; j++)
            labels.push(activeProfile.traits[j]);
    }
    if (!labels.length) labels.push('Detecting stack');

    for (var k = 0; k < labels.length; k++) {
        var badge = document.createElement('span');
        badge.className = 'tag is-light';
        badge.textContent = labels[k];
        stackBadges.appendChild(badge);
    }

    captureProfileEl.textContent =
        activeStatus && activeStatus.profile
            ? activeStatus.profile
            : activeProfile && activeProfile.strategy
              ? activeProfile.strategy.profile
              : 'generic-app';
    captureConfidenceEl.textContent =
        activeProfile && activeProfile.confidence ? activeProfile.confidence + '%' : '--';
    captureReasonEl.textContent = describeCaptureReason(activeStatus, activeProfile);
}

function describeCaptureReason(status, profile) {
    if (status && status.reasonText) return status.reasonText;
    if (status && status.ready) return 'Adaptive capture window satisfied. Export can proceed.';
    if (
        profile &&
        profile.strategy &&
        profile.strategy.reasons &&
        profile.strategy.reasons.length
    ) {
        return (
            'Adaptive mode: ' + profile.strategy.profile + '. ' + profile.strategy.reasons[0] + '.'
        );
    }
    return 'Profiler idle until capture starts.';
}

function resetTrackerView() {
    latestTracker = null;
    latestStackProfile = null;
    latestCaptureStatus = null;
    resourceBody.innerHTML = '';
    stackBadges.innerHTML = '<span class="tag is-light">Detecting stack</span>';
    captureProfileEl.textContent = 'Awaiting detection';
    captureConfidenceEl.textContent = '--';
    captureReasonEl.textContent = 'Profiler idle until capture starts.';
    loadedCountEl.textContent = '0';
    unloadedCountEl.textContent = '0';
    visibleCountEl.textContent = '0';
    totalCountEl.textContent = '0';
    statusBar.style.display = 'none';
    resourceList.style.display = 'none';
    emptyState.style.display = 'none';
    typeFilter.innerHTML = '<option value="all">All types</option>';
}

function fetchTextAsset(url, label) {
    return fetch(url).then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status + ' loading ' + label);
        return res.text();
    });
}

function injectAndReload(buttonLabel, onComplete) {
    // When the panel page runs outside a DevTools window (e.g. opened
    // directly as an extension page), the devtools API is absent. Fail
    // visibly instead of throwing mid-flow.
    if (!chrome.devtools || !chrome.devtools.inspectedWindow) {
        setActivity(
            'danger',
            'DevTools API unavailable - open this panel from the DevTools window (Sources Downloader tab).',
        );
        return;
    }
    if (isPolling) return;
    isPolling = true;
    onPollComplete = onComplete;
    reloadDebugBtn.disabled = true;
    downloadBtn.disabled = true;
    reloadDebugBtn.textContent = buttonLabel;
    downloadBtn.textContent = buttonLabel;
    resetTrackerView();
    renderPageOrigin(null);
    setActivity('info', 'Injecting capture hooks and reloading the inspected page...');

    Promise.all([
        fetchTextAsset(chrome.runtime.getURL('js/stack-profile.js'), 'stack-profile.js'),
        fetchTextAsset(
            chrome.runtime.getURL('js/framework-introspect.js'),
            'framework-introspect.js',
        ),
        fetchTextAsset(chrome.runtime.getURL('js/injected.js'), 'injected.js'),
    ])
        .then(function (scripts) {
            var code = scripts.join('\n;\n');
            chrome.devtools.inspectedWindow.reload({ injectedScript: code, ignoreCache: true });
            setActivity(
                'info',
                'Waiting for the inspected page to settle so capture stays site-agnostic...',
            );
            startPolling();
        })
        .catch(function (err) {
            console.error('[Downloader] FAILED to load injected assets:', err);
            reloadDebugBtn.disabled = false;
            downloadBtn.disabled = false;
            reloadDebugBtn.textContent = 'Force Reload + Debug';
            downloadBtn.textContent = 'Download All';
            isPolling = false;
            setActivity(
                'danger',
                'Failed to load injected assets: ' +
                    (err && err.message ? err.message : String(err)),
            );
        });
}

reloadDebugBtn.onclick = function () {
    injectAndReload('Reloading page...', null);
};

downloadBtn.onclick = function () {
    injectAndReload('Reloading page...', doDownload);
};

function startPolling() {
    var attempts = 0;
    var maxAttempts = 180;
    pollingTimer = setInterval(function () {
        attempts++;
        chrome.devtools.inspectedWindow.eval(
            'JSON.stringify({ ready: window.__RESOURCE_TRACKER_READY__, data: window.__RESOURCE_TRACKER__, site: { title: document.title || "", url: location.href || "", origin: location.origin || "" }, stackProfile: window.__STACK_PROFILE__ || null, captureStatus: window.__CAPTURE_STATUS__ || null })',
            function (result, error) {
                if (error) {
                    if (attempts >= maxAttempts) stopPolling();
                    return;
                }
                try {
                    var payload = JSON.parse(result);
                    if (payload.site) renderPageOrigin(payload.site);
                    if (payload.stackProfile || payload.captureStatus)
                        renderStackProfile(payload.stackProfile, payload.captureStatus);
                    if (payload.data) renderResults(payload.data);
                    if (!payload.ready && payload.captureStatus && payload.captureStatus.reasonText)
                        setActivity('info', payload.captureStatus.reasonText);
                    if (payload.ready || attempts >= maxAttempts) stopPolling();
                } catch (_) {
                    if (attempts >= maxAttempts) stopPolling();
                }
            },
        );
    }, 500);
}

function stopPolling() {
    if (pollingTimer) {
        clearInterval(pollingTimer);
        pollingTimer = null;
    }
    isPolling = false;
    reloadDebugBtn.textContent = 'Force Reload + Debug';
    downloadBtn.textContent = 'Download All';
    if (onPollComplete) {
        var cb = onPollComplete;
        onPollComplete = null;
        reloadDebugBtn.disabled = false;
        setActivity('info', 'Capture complete. Building adaptive export package...');
        cb();
        return;
    }
    reloadDebugBtn.disabled = false;
    downloadBtn.disabled = false;
    if (latestTracker)
        setActivity('success', 'Capture ready. Filter the live view or export everything.');
    else clearActivity();
}

function renderResults(tracker) {
    latestTracker = tracker || { loaded: [], unloaded: [] };
    renderTrackerView();
}

function renderTrackerView() {
    if (!latestTracker) return;

    // Normalization, filtering, sorting and the row markup all live in the
    // Rust panel module; this applies the produced view to the DOM.
    var view = panelTrackerView(latestTracker, {
        status: statusFilter.value || 'all',
        kind: typeFilter.value || 'all',
        search: resourceSearch.value || '',
        sort: sortOrder.value || 'newest',
    });

    loadedCountEl.textContent = String(view.loaded);
    unloadedCountEl.textContent = String(view.unloaded);
    visibleCountEl.textContent = String(view.visible);
    totalCountEl.textContent = String(view.total);
    statusBar.style.display = view.showStatusBar ? 'grid' : 'none';

    typeFilter.innerHTML = view.typesHtml;
    typeFilter.value = view.typeSelection;
    resourceBody.innerHTML = view.rowsHtml;
    resourceList.style.display = view.showList ? 'block' : 'none';
    emptyState.style.display = view.showEmpty ? 'block' : 'none';
}

function hashString(text) {
    var hash = 0;
    text = String(text || '');
    for (var i = 0; i < text.length; i++) {
        hash = (hash << 5) - hash + text.charCodeAt(i);
        hash |= 0;
    }
    return Math.abs(hash).toString(16);
}

function safeDecodeURIComponent(value) {
    try {
        return decodeURIComponent(value);
    } catch (_) {
        return value;
    }
}

function sanitizePathPart(value, fallback) {
    value = String(value || '').trim();
    value = value.replace(/[\\:*?"<>|]/g, '_');
    if (!value) value = fallback || '_';
    return value.length > 100 ? value.substring(0, 100) : value;
}

function appendPathSuffix(path, suffix) {
    var dot = path.lastIndexOf('.');
    var slash = path.lastIndexOf('/');
    if (dot > slash) return path.substring(0, dot) + suffix + path.substring(dot);
    return path + suffix;
}

function normalizeUrlCandidate(url) {
    var value = String(url || '').trim();
    if (!value || /^data:/i.test(value)) return value;
    value = value.replace(/\\+/g, '/');
    value = value.replace(/^([a-z][a-z0-9+.-]*):\/(?!\/)/i, '$1://');
    value = value.replace(/^([a-z][a-z0-9+.-]*):\/\/+?/i, '$1://');
    return value;
}

function sanitizeFilename(url) {
    if (!url) return 'unknown/resource';
    url = normalizeUrlCandidate(url);
    if (url.indexOf('data:') === 0) {
        var mimeMatch = url.match(/^data:([^;,]+)/);
        var ext = 'data';
        if (mimeMatch) {
            var mimeParts = mimeMatch[1].split('/');
            if (mimeParts.length === 2) ext = mimeParts[1];
        }
        return 'inline/' + hashString(url) + '.' + ext;
    }

    var blobMatch = /^blob:(.+)$/i.exec(url);
    if (blobMatch) return appendPathSuffix(sanitizeFilename(blobMatch[1]), '__blob');

    var parsed = null;
    try {
        parsed = new URL(url);
    } catch (_) {}

    if (!parsed) {
        var rawValue = String(url).replace(/[?#].*$/, '');
        var rawParts = rawValue.split(/[\/]+/);
        var cleaned = [];
        var offset = 0;
        if (rawParts.length > 1 && /^[a-z][a-z0-9+.-]*:$/i.test(rawParts[0])) {
            var looseProtocol = rawParts[0].slice(0, -1).toLowerCase();
            if (looseProtocol !== 'http' && looseProtocol !== 'https')
                cleaned.push(sanitizePathPart(looseProtocol, 'scheme'));
            cleaned.push(sanitizePathPart(safeDecodeURIComponent(rawParts[1]), 'host'));
            offset = 2;
        }
        for (var i = offset; i < rawParts.length; i++) {
            if (!rawParts[i]) continue;
            cleaned.push(sanitizePathPart(safeDecodeURIComponent(rawParts[i]), '_'));
        }
        return cleaned.join('/') || 'unknown/resource';
    }

    var segments = [];
    var protocol = sanitizePathPart(parsed.protocol.replace(':', ''), 'scheme');
    if (protocol !== 'http' && protocol !== 'https') segments.push(protocol);
    if (parsed.host) segments.push(sanitizePathPart(parsed.host, 'host'));

    var pathname = parsed.pathname || '/';
    if (pathname.charAt(pathname.length - 1) === '/') pathname += 'index.html';
    var pathParts = pathname.split('/');
    for (var j = 0; j < pathParts.length; j++) {
        if (!pathParts[j]) continue;
        segments.push(sanitizePathPart(safeDecodeURIComponent(pathParts[j]), '_'));
    }
    if (!segments.length) segments.push('unknown');

    var name = segments.join('/');
    if (parsed.search || parsed.hash)
        name = appendPathSuffix(
            name,
            '__' + hashString((parsed.search || '') + (parsed.hash || '')).substring(0, 8),
        );
    return name;
}

function formatSize(bytes) {
    if (bytes === 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(2) + ' MB';
}

function sanitizePageTitle(title) {
    return (title || 'page').replace(/[\\/:*?"<>|]/g, '_').substring(0, 100) || 'page';
}

function formatMs(ms) {
    if (ms < 1) return Math.round(ms * 1000) + ' us';
    if (ms < 1000) return ms.toFixed(1) + ' ms';
    return (ms / 1000).toFixed(2) + ' s';
}

function doDownload() {
    // When the panel page runs outside a DevTools window (e.g. opened
    // directly as an extension page), the devtools API is absent. Fail
    // visibly instead of throwing inside the click handler.
    if (!chrome.devtools || !chrome.devtools.inspectedWindow) {
        setActivity(
            'danger',
            'DevTools API unavailable - open this panel from the DevTools window (Sources Downloader tab).',
        );
        return;
    }
    downloadBtn.disabled = true;
    downloadBtn.textContent = 'Downloading...';
    setActivity('info', 'Collecting resources, HTML, recon data, and runtime artifacts...');
    chrome.devtools.inspectedWindow.getResources(function (resources) {
        var zip = new JSZip();
        var pending = resources.length + 1;
        var jsAssets = [];
        var pageSnapshot = { html: '', title: 'page' };
        var done = false;

        function checkDone() {
            if (done || pending !== 0) return;
            done = true;
            collectReconAndFinalize(zip, jsAssets, pageSnapshot);
        }

        for (var i = 0; i < resources.length; i++) {
            (function (resource) {
                resource.getContent(function (content, encoding) {
                    zip.file(sanitizeFilename(resource.url), content, {
                        base64: encoding === 'base64',
                    });
                    var urlLo = resource.url.toLowerCase();
                    var binaryBytes = null;
                    if (encoding === 'base64' && content && content.length <= 8 * 1024 * 1024) {
                        try {
                            binaryBytes = decodeBase64ToBytes(content);
                        } catch (_) {
                            binaryBytes = null;
                        }
                    }
                    if (looksBinaryScript(resource.url, binaryBytes)) {
                        // Cached bytecode (V8 code cache, JSC bytecode, sealed
                        // .jsc): routed as bytes so the binary pass reads its
                        // header and recovers its strings instead of treating
                        // it as opaque text.
                        var routedBytes = binaryBytes;
                        if (!routedBytes) {
                            try {
                                routedBytes = decodeBase64ToBytes(content);
                            } catch (_) {
                                routedBytes = null;
                            }
                        }
                        if (routedBytes) {
                            jsAssets.push({
                                url: resource.url,
                                zipPath: sanitizeFilename(resource.url),
                                bytes: routedBytes,
                            });
                        }
                    } else if (/\.(?:js|mjs)(?:\?|$)/.test(urlLo) || /\.js$/.test(urlLo)) {
                        jsAssets.push({
                            url: resource.url,
                            zipPath: sanitizeFilename(resource.url),
                            content: encoding === 'base64' ? atob(content) : content,
                        });
                    }
                    pending--;
                    checkDone();
                });
            })(resources[i]);
        }

        chrome.devtools.inspectedWindow.eval(
            '(function(){return JSON.stringify({html:document.documentElement.outerHTML,title:document.title})})()',
            function (htmlResult, htmlError) {
                if (htmlResult && !htmlError) {
                    try {
                        var pageData = JSON.parse(htmlResult);
                        if (pageData.html) {
                            pageSnapshot.html = pageData.html;
                            pageSnapshot.title = pageData.title || 'page';
                            zip.file(
                                sanitizePageTitle(pageSnapshot.title) + '.html',
                                pageSnapshot.html,
                            );
                        }
                    } catch (_) {}
                }
                pending--;
                checkDone();
            },
        );
    });
}

function collectReconAndFinalize(zip, jsAssets, pageSnapshot) {
    downloadBtn.textContent = 'Collecting recon data...';
    setActivity('info', 'Collecting recon data from the inspected page...');
    var reconEval =
        '(function(){\n' +
        'var ls={},ss={};\n' +
        'try{for(var k in localStorage)ls[k]=localStorage[k];}catch(_){}\n' +
        'try{for(var k in sessionStorage)ss[k]=sessionStorage[k];}catch(_){}\n' +
        'var ck=document.cookie||"";\n' +
        'var timings=[];\n' +
        'try{var entries=performance.getEntriesByType("resource");for(var i=0;i<entries.length;i++){var e=entries[i];timings.push({name:e.name,initiatorType:e.initiatorType,duration:e.duration,transferSize:e.transferSize,encodedBodySize:e.encodedBodySize,decodedBodySize:e.decodedBodySize,startTime:e.startTime,domainLookupStart:e.domainLookupStart,domainLookupEnd:e.domainLookupEnd,connectStart:e.connectStart,connectEnd:e.connectEnd,secureConnectionStart:e.secureConnectionStart,requestStart:e.requestStart,responseStart:e.responseStart,responseEnd:e.responseEnd});}}catch(_){}\n' +
        'var recon=window.__RECON__||{};\n' +
        'var runtimeItems=recon.runtime||[];\n' +
        'var runtime=[];\n' +
        'for(var j=0;j<runtimeItems.length;j++){var item=runtimeItems[j]||{};runtime.push({index:j,id:item.id||("runtime-"+j),kind:item.kind||"unknown",mimeType:item.mimeType||"",source:item.source||"",url:item.url||"",objectUrl:item.objectUrl||"",blobId:item.blobId||null,note:item.note||"",size:item.size||0,textLength:item.textLength||0,byteLength:item.byteLength||0,truncated:!!item.truncated,timestamp:item.timestamp||0,scriptType:item.scriptType||"",workerType:item.workerType||"",scope:item.scope||"",updateViaCache:item.updateViaCache||"",params:item.params||null,stack:item.stack||"",hasText:typeof item.text==="string",hasBase64:typeof item.base64==="string"});}\n' +
        'var page={title:document.title||"",url:location.href||"",origin:location.origin||"",protocol:location.protocol||"",referrer:document.referrer||"",userAgent:navigator.userAgent||""};\n' +
        'var stackProfile=window.__STACK_PROFILE__||null;\n' +
        'var captureStatus=window.__CAPTURE_STATUS__||null;\n' +
        'var frameworkState=window.__FRAMEWORK_INTROSPECTOR__&&typeof window.__FRAMEWORK_INTROSPECTOR__.refresh==="function"?window.__FRAMEWORK_INTROSPECTOR__.refresh({reason:"recon-export",stackProfile:stackProfile,captureStatus:captureStatus}):(window.__FRAMEWORK_STATE__||null);\n' +
        'return JSON.stringify({ls:ls,ss:ss,cookies:ck,timings:timings,recon:{xhr:recon.xhr||[],fetch:recon.fetch||[],websockets:recon.websockets||[],sse:recon.sse||[],mutations:recon.mutations||[],runtime:runtime},page:page,stackProfile:stackProfile,captureStatus:captureStatus,frameworkState:frameworkState});\n' +
        '})()';

    chrome.devtools.inspectedWindow.eval(reconEval, function (result, error) {
        if (error) return finalizeZipWithRecon(zip, jsAssets, null, pageSnapshot);
        try {
            finalizeZipWithRecon(zip, jsAssets, JSON.parse(result), pageSnapshot);
        } catch (_) {
            finalizeZipWithRecon(zip, jsAssets, null, pageSnapshot);
        }
    });
}

function finalizeZipWithRecon(zip, jsAssets, reconData, pageSnapshot) {
    downloadBtn.textContent = 'Building zip...';
    setActivity('info', 'Building a site-aware export package...');
    var runtimeEntries = [];

    if (reconData) {
        if (reconData.ls && Object.keys(reconData.ls).length)
            zip.file('_recon/localStorage.json', JSON.stringify(reconData.ls, null, 2));
        if (reconData.ss && Object.keys(reconData.ss).length)
            zip.file('_recon/sessionStorage.json', JSON.stringify(reconData.ss, null, 2));
        if (reconData.cookies && reconData.cookies.trim())
            zip.file(
                '_recon/cookies.json',
                JSON.stringify(parseCookies(reconData.cookies), null, 2),
            );
        if (reconData.page) zip.file('_recon/page.json', JSON.stringify(reconData.page, null, 2));
        if (reconData.stackProfile) {
            zip.file('_recon/stack-profile.json', JSON.stringify(reconData.stackProfile, null, 2));
            if (reconData.stackProfile.evidence)
                zip.file(
                    '_recon/framework-signals.json',
                    JSON.stringify(reconData.stackProfile.evidence, null, 2),
                );
            if (reconData.stackProfile.strategy)
                zip.file(
                    '_recon/capture-strategy.json',
                    JSON.stringify(reconData.stackProfile.strategy, null, 2),
                );
        }
        if (reconData.captureStatus)
            zip.file(
                '_recon/capture-status.json',
                JSON.stringify(reconData.captureStatus, null, 2),
            );
        if (reconData.frameworkState) exportFrameworkArtifacts(zip, reconData.frameworkState);
        if (reconData.timings && reconData.timings.length) {
            zip.file('_recon/timings.json', JSON.stringify(reconData.timings, null, 2));
            zip.file('_recon/waterfall.html', generateWaterfallHTML(reconData.timings));
        }
        var r = reconData.recon;
        if (r) {
            if (r.xhr && r.xhr.length) zip.file('_recon/xhr.json', JSON.stringify(r.xhr, null, 2));
            if (r.fetch && r.fetch.length)
                zip.file('_recon/fetch.json', JSON.stringify(r.fetch, null, 2));
            if (r.websockets && r.websockets.length)
                zip.file('_recon/websockets.json', JSON.stringify(r.websockets, null, 2));
            if (r.sse && r.sse.length) zip.file('_recon/sse.json', JSON.stringify(r.sse, null, 2));
            if (r.mutations && r.mutations.length)
                zip.file('_recon/mutations.json', JSON.stringify(r.mutations, null, 2));
            if (
                reconData.stackProfile &&
                reconData.stackProfile.strategy &&
                reconData.stackProfile.strategy.captureGraphQLOps
            ) {
                var graphqlOps = collectGraphQLOperations(r);
                if (graphqlOps.length)
                    zip.file('_recon/graphql-operations.json', JSON.stringify(graphqlOps, null, 2));
            }
            if (r.runtime && r.runtime.length) runtimeEntries = r.runtime;
        }
    }
    if (pageSnapshot && pageSnapshot.html) {
        zip.file(
            '_recon/dom-snapshot.html',
            generateDOMSnapshotHTML(
                pageSnapshot.html,
                reconData && reconData.page
                    ? reconData.page
                    : { title: pageSnapshot.title || 'page' },
            ),
        );
    }

    collectRuntimePayloads(runtimeEntries, function (runtimePayloads) {
        var runtimeManifest = exportRuntimeArtifacts(zip, runtimePayloads);
        setActivity('info', 'Reconstructing modules, flows, workspaces, and journeys...');
        exportSemanticAnalysis(zip, jsAssets, reconData, runtimePayloads, runtimeManifest);
        setActivity(
            'info',
            'Unpacking JavaScript: source maps, bundles, and obfuscation layers...',
        );
        var runtimeJsAssets = buildRuntimeUnpackAssets(runtimePayloads, runtimeManifest);
        unpackAssetsIntoZip(zip, jsAssets, {
            fetchText: fetchSourceMapText,
            onProgress: function (done, total) {
                setActivity('info', 'Unpacking JavaScript ' + done + '/' + total + '...');
            },
        })
            .then(function (scriptReport) {
                return unpackAssetsIntoZip(zip, runtimeJsAssets, {
                    pathPrefix: '_unpack-runtime',
                    fetchText: fetchSourceMapText,
                    onProgress: function (done, total) {
                        setActivity(
                            'info',
                            'Unpacking runtime payloads ' + done + '/' + total + '...',
                        );
                    },
                }).then(function (runtimeReport) {
                    return mergeUnpackReports(scriptReport, runtimeReport);
                });
            })
            .then(function (unpackReport) {
                zip.generateAsync({ type: 'blob' }).then(function (zipContent) {
                    saveAs(zipContent, 'sources.zip');
                    downloadBtn.disabled = false;
                    downloadBtn.textContent = 'Download All';
                    var totals = unpackReport.totals;
                    setActivity(
                        'success',
                        'Export ready. Unpacked ' +
                            totals.unpacked +
                            ' of ' +
                            totals.assets +
                            ' scripts (' +
                            totals.beautified +
                            ' beautified, ' +
                            totals.sources +
                            ' original sources, ' +
                            totals.modules +
                            ' bundle modules).',
                    );
                });
            })
            .catch(function (err) {
                downloadBtn.disabled = false;
                downloadBtn.textContent = 'Download All';
                setActivity(
                    'danger',
                    'Unpacking failed: ' + (err && err.message ? err.message : String(err)),
                );
            });
    });
}

// Runtime payloads (eval, Function, injected scripts, JS workers) are exactly where
// obfuscation hides, so they take the same peel/beautify/module pass as page scripts.
function buildRuntimeUnpackAssets(runtimePayloads, runtimeManifest) {
    var assets = [];
    var manifest = runtimeManifest || [];
    for (var i = 0; i < runtimePayloads.length; i++) {
        var entry = runtimePayloads[i];
        if (typeof entry.text !== 'string' || !entry.text.length) continue;
        if (runtimeExtension(entry) !== 'js') continue;
        var rawFile = '';
        for (var m = 0; m < manifest.length; m++) {
            if (manifest[m].id === entry.id) {
                rawFile = manifest[m].file || '';
                break;
            }
        }
        assets.push({
            url: entry.url || entry.label || entry.id,
            content: entry.text,
            zipPath: rawFile,
        });
    }
    return assets;
}

function mergeUnpackReports(scriptReport, runtimeReport) {
    var totals = scriptReport.totals;
    var runtimeTotals = runtimeReport.totals;
    totals.assets += runtimeTotals.assets;
    totals.unpacked += runtimeTotals.unpacked;
    totals.modules += runtimeTotals.modules;
    totals.sources += runtimeTotals.sources;
    totals.beautified += runtimeTotals.beautified;
    return scriptReport;
}

function parseCookies(cookieStr) {
    var result = {};
    var pairs = cookieStr.split(';');
    for (var i = 0; i < pairs.length; i++) {
        var eq = pairs[i].indexOf('=');
        if (eq < 0) continue;
        result[pairs[i].substring(0, eq).trim()] = pairs[i].substring(eq + 1).trim();
    }
    return result;
}

function exportFrameworkArtifacts(zip, frameworkState) {
    if (!frameworkState) return;
    if (frameworkState.summary && Object.keys(frameworkState.summary).length)
        zip.file('_framework/summary.json', JSON.stringify(frameworkState.summary, null, 2));
    if (frameworkState.router && Object.keys(frameworkState.router).length)
        zip.file('_framework/router-state.json', JSON.stringify(frameworkState.router, null, 2));
    if (frameworkState.roots && frameworkState.roots.length)
        zip.file('_framework/framework-roots.json', JSON.stringify(frameworkState.roots, null, 2));
    if (frameworkState.stores && frameworkState.stores.length)
        zip.file('_framework/store-snapshots.json', JSON.stringify(frameworkState.stores, null, 2));
    if (frameworkState.queries && frameworkState.queries.length)
        zip.file('_framework/query-caches.json', JSON.stringify(frameworkState.queries, null, 2));
    if (frameworkState.hydration && frameworkState.hydration.length)
        zip.file(
            '_framework/hydration-payloads.json',
            JSON.stringify(frameworkState.hydration, null, 2),
        );
    if (frameworkState.auth && frameworkState.auth.length)
        zip.file('_framework/auth-state.json', JSON.stringify(frameworkState.auth, null, 2));
}

function collectRuntimePayloads(runtimeEntries, onComplete) {
    if (!runtimeEntries || runtimeEntries.length === 0) {
        onComplete([]);
        return;
    }
    var entries = runtimeEntries.slice();
    var cursor = 0;

    function step() {
        while (cursor < entries.length && !entries[cursor].hasText && !entries[cursor].hasBase64)
            cursor++;
        if (cursor >= entries.length) {
            onComplete(entries);
            return;
        }
        var entry = entries[cursor++];
        fetchRuntimePayload(entry.index, function (payload) {
            if (payload) {
                if (typeof payload.text === 'string') entry.text = payload.text;
                if (typeof payload.base64 === 'string') entry.base64 = payload.base64;
            }
            step();
        });
    }

    step();
}

function fetchRuntimePayload(index, onComplete) {
    var expr =
        '(function(){var list=window.__RECON__&&window.__RECON__.runtime;if(!list||!list[' +
        index +
        ']) return null;var item=list[' +
        index +
        '];return JSON.stringify({text:typeof item.text==="string"?item.text:null,base64:typeof item.base64==="string"?item.base64:null});})()';
    chrome.devtools.inspectedWindow.eval(expr, function (result, error) {
        if (!result || error) {
            onComplete(null);
            return;
        }
        try {
            onComplete(JSON.parse(result));
        } catch (_) {
            onComplete(null);
        }
    });
}

function exportRuntimeArtifacts(zip, runtimeEntries) {
    var manifest = [];
    var counters = {};
    for (var i = 0; i < runtimeEntries.length; i++) {
        var entry = runtimeEntries[i];
        var manifestEntry = {};
        for (var key in entry) {
            if (!Object.prototype.hasOwnProperty.call(entry, key)) continue;
            if (
                key === 'index' ||
                key === 'text' ||
                key === 'base64' ||
                key === 'hasText' ||
                key === 'hasBase64'
            )
                continue;
            manifestEntry[key] = entry[key];
        }
        if (typeof entry.text === 'string' || typeof entry.base64 === 'string') {
            manifestEntry.file = buildRuntimePath(entry, counters);
            if (typeof entry.text === 'string') zip.file(manifestEntry.file, entry.text);
            else zip.file(manifestEntry.file, entry.base64, { base64: true });
        }
        manifest.push(manifestEntry);
    }
    zip.file('_runtime/runtime-manifest.json', JSON.stringify(manifest, null, 2));
    return manifest;
}

function buildRuntimePath(entry, counters) {
    var folder = runtimeFolderName(entry.kind);
    counters[folder] = (counters[folder] || 0) + 1;
    return (
        '_runtime/' +
        folder +
        '/' +
        ('0000' + counters[folder]).slice(-4) +
        '.' +
        runtimeExtension(entry)
    );
}

function runtimeFolderName(kind) {
    if (kind === 'eval') return 'eval';
    if (kind === 'function') return 'function';
    if (kind === 'blob') return 'blob';
    if (kind === 'worker') return 'workers';
    if (kind === 'shared-worker') return 'shared-workers';
    if (kind === 'service-worker') return 'service-workers';
    if (kind === 'script-injection') return 'script-injections';
    if (kind === 'wasm') return 'wasm';
    return 'misc';
}

function runtimeExtension(entry) {
    var mimeType = entry.mimeType || '';
    if (entry.kind === 'wasm' || /wasm/i.test(mimeType)) return 'wasm';
    if (/javascript|ecmascript|typescript/i.test(mimeType)) return 'js';
    if (/json/i.test(mimeType)) return 'json';
    if (/html/i.test(mimeType)) return 'html';
    if (/css/i.test(mimeType)) return 'css';
    if (/svg/i.test(mimeType)) return 'svg';
    if (/xml/i.test(mimeType)) return 'xml';
    if (/text/i.test(mimeType)) return 'txt';
    if (
        entry.kind === 'eval' ||
        entry.kind === 'function' ||
        entry.kind === 'worker' ||
        entry.kind === 'shared-worker' ||
        entry.kind === 'service-worker' ||
        entry.kind === 'script-injection'
    )
        return 'js';
    return typeof entry.base64 === 'string' ? 'bin' : 'txt';
}

function exportSemanticAnalysis(zip, jsAssets, reconData, runtimeEntries, runtimeManifest) {
    var analysis = buildSemanticAnalysis(jsAssets, reconData, runtimeEntries, runtimeManifest);
    exportReadableArtifacts(zip, analysis);
    zip.file('_analysis/chunk-map.json', JSON.stringify(analysis.chunkMap, null, 2));
    zip.file(
        '_analysis/cross-boundary-flows.json',
        JSON.stringify(analysis.crossBoundaryFlows, null, 2),
    );
    zip.file('_analysis/module-graph.json', JSON.stringify(analysis.moduleGraph, null, 2));
    zip.file('_analysis/startup-chain.json', JSON.stringify(analysis.startupChain, null, 2));
    zip.file('_analysis/runtime-origins.json', JSON.stringify(analysis.runtimeOrigins, null, 2));
    zip.file('_analysis/boundary-labels.json', JSON.stringify(analysis.boundaryLabels, null, 2));
    zip.file(
        '_analysis/framework-runtime.json',
        JSON.stringify(analysis.frameworkRuntime, null, 2),
    );
    zip.file(
        '_analysis/interesting-entrypoints.json',
        JSON.stringify(analysis.interestingEntrypoints, null, 2),
    );
    zip.file('_analysis/index.html', generateInvestigationIndexHTML(analysis.investigation));
    for (var i = 0; i < analysis.investigation.workspaces.length; i++) {
        var workspace = analysis.investigation.workspaces[i];
        zip.file(
            '_analysis/workspaces/' + workspace.id + '.json',
            JSON.stringify(workspace, null, 2),
        );
    }
    for (var j = 0; j < analysis.investigation.journeys.length; j++) {
        var journey = analysis.investigation.journeys[j];
        zip.file('_analysis/journeys/' + journey.id + '.json', JSON.stringify(journey, null, 2));
    }
}

function buildSemanticAnalysis(jsAssets, reconData, runtimeEntries, runtimeManifest) {
    var assets = prepareScriptAssets(jsAssets, reconData);
    var runtimeOrigins = buildRuntimeOrigins(runtimeEntries, runtimeManifest, assets);
    var boundaryLabels = buildBoundaryLabels(reconData, assets, runtimeOrigins);
    var crossBoundaryFlows = buildCrossBoundaryFlows(reconData, assets, runtimeOrigins);
    var interestingEntrypoints = collectInterestingEntrypoints(assets, runtimeOrigins);
    var frameworkState = buildFrameworkStateSummary(
        reconData && reconData.frameworkState ? reconData.frameworkState : null,
    );
    var analysis = {
        assets: assets,
        runtimeRecords: runtimeOrigins,
        chunkMap: {
            generatedAt: new Date().toISOString(),
            summary: buildChunkSummary(assets),
            items: assets.map(stripChunkAsset),
        },
        moduleGraph: buildModuleGraph(reconData, assets, runtimeOrigins),
        startupChain: buildStartupChain(reconData, assets, runtimeOrigins),
        runtimeOrigins: {
            generatedAt: new Date().toISOString(),
            summary: buildRuntimeSummary(runtimeOrigins),
            items: runtimeOrigins.map(stripRuntimeEntry),
        },
        boundaryLabels: boundaryLabels,
        crossBoundaryFlows: crossBoundaryFlows,
        frameworkState: frameworkState,
        frameworkRuntime: buildFrameworkRuntimeSummary(
            reconData,
            assets,
            runtimeOrigins,
            interestingEntrypoints,
            boundaryLabels,
            crossBoundaryFlows,
        ),
        interestingEntrypoints: interestingEntrypoints,
    };
    analysis.investigation = buildInvestigationWorkspace(analysis);
    analysis.frameworkRuntime.availableWorkspaces = analysis.investigation.workspaces.map(
        function (workspace) {
            return {
                id: workspace.id,
                title: workspace.title,
                itemCount: workspace.summary.totalItems,
                transitionCount: workspace.summary.transitionCount,
            };
        },
    );
    analysis.frameworkRuntime.availableJourneys = analysis.investigation.journeys.map(
        function (journey) {
            return {
                id: journey.id,
                title: journey.title,
                eventCount: journey.summary.eventCount,
                transitionCount: journey.summary.transitionCount,
            };
        },
    );
    return analysis;
}

function normalizeUrlKey(url) {
    return String(url || '').split('#')[0];
}

function stripUrlVariant(url) {
    return normalizeUrlKey(url).split('?')[0];
}

function buildTimingLookup(timings) {
    var lookup = {};
    for (var i = 0; i < timings.length; i++) {
        var item = timings[i];
        if (!item || !item.name) continue;
        var full = normalizeUrlKey(item.name);
        var bare = stripUrlVariant(item.name);
        if (!lookup[full]) lookup[full] = item;
        if (!lookup[bare]) lookup[bare] = item;
    }
    return lookup;
}

function prepareScriptAssets(jsAssets, reconData) {
    var timings = reconData && reconData.timings ? reconData.timings : [];
    var timingLookup = buildTimingLookup(timings);
    var stackProfile = reconData && reconData.stackProfile ? reconData.stackProfile : null;
    var assets = [];
    for (var i = 0; i < jsAssets.length; i++) {
        var item = jsAssets[i] || {};
        var url = String(item.url || 'inline/script-' + (i + 1) + '.js');
        var content = typeof item.content === 'string' ? item.content : '';
        var scanText = content.length > 200000 ? content.substring(0, 200000) : content;
        var timing =
            timingLookup[normalizeUrlKey(url)] || timingLookup[stripUrlVariant(url)] || null;
        var imports = extractImportSpecifiers(scanText);
        var entry = {
            id:
                'chunk-' +
                sanitizePathPart(getBareFileName(url) || 'script-' + (i + 1), 'script') +
                '-' +
                hashString(url).substring(0, 8),
            url: url,
            file: sanitizeFilename(url),
            size: content.length,
            transferSize: timing && timing.transferSize ? timing.transferSize : 0,
            startTime: timing && typeof timing.startTime === 'number' ? timing.startTime : 0,
            duration: timing && typeof timing.duration === 'number' ? timing.duration : 0,
            imports: imports,
            moduleSignals: {
                importCount: imports.length,
                dynamicImports: countMatches(scanText, /\bimport\s*\(/g),
                requires: countMatches(scanText, /\brequire\s*\(\s*["'`]/g),
                exports: countMatches(scanText, /\bexport\s+(?:default|const|function|class|\{)/g),
            },
            bundler: detectBundlerName(url, scanText),
            frameworkHints: detectFrameworkHints(url, scanText, stackProfile),
            routeHints: extractRouteHintsFromUrl(url),
            startupSignals: detectStartupSignals(url, scanText),
            sourceMapEmbedded: /sourceMappingURL\s*=\s*data:/i.test(scanText),
            content: content,
        };
        entry.classification = classifyScriptAsset(
            url,
            scanText,
            entry.bundler,
            entry.frameworkHints,
            entry.startupSignals,
        );
        entry.score = scoreScriptAsset(entry);
        assets.push(entry);
    }
    return assets;
}

function detectBundlerName(url, content) {
    var sample = (String(url || '') + '\n' + String(content || '')).toLowerCase();
    if (
        sample.indexOf('__webpack_require__') >= 0 ||
        sample.indexOf('webpackchunk') >= 0 ||
        sample.indexOf('/_next/static/chunks/') >= 0
    )
        return 'webpack';
    if (sample.indexOf('parcelrequire') >= 0) return 'parcel';
    if (
        sample.indexOf('import.meta.hot') >= 0 ||
        sample.indexOf('/@vite/') >= 0 ||
        sample.indexOf('__vite__') >= 0
    )
        return 'vite';
    return 'unknown';
}

function detectFrameworkHints(url, content, stackProfile) {
    var sample = (String(url || '') + '\n' + String(content || '')).toLowerCase();
    var hints = [];
    if (sample.indexOf('__next_data__') >= 0 || sample.indexOf('/_next/') >= 0)
        hints.push('Next.js');
    if (sample.indexOf('reactdom') >= 0 || sample.indexOf('react') >= 0) hints.push('React');
    if (sample.indexOf('__nuxt') >= 0) hints.push('Nuxt');
    if (sample.indexOf('__vue') >= 0 || sample.indexOf('createapp(') >= 0) hints.push('Vue');
    if (sample.indexOf('ng-version') >= 0 || sample.indexOf('zone.js') >= 0) hints.push('Angular');
    if (sample.indexOf('svelte') >= 0) hints.push('SvelteKit');
    if (sample.indexOf('astro') >= 0) hints.push('Astro');
    if (sample.indexOf('remix') >= 0) hints.push('Remix');
    if (stackProfile && stackProfile.technologies) {
        for (var i = 0; i < stackProfile.technologies.length; i++) {
            var tech = stackProfile.technologies[i];
            if (tech && tech.name) hints.push(tech.name);
        }
    }
    return uniqueStrings(hints).slice(0, 8);
}

function detectStartupSignals(url, content) {
    var sample = (String(url || '') + '\n' + String(content || '')).toLowerCase();
    var signals = [];
    if (
        sample.indexOf('hydrateroot') >= 0 ||
        sample.indexOf('reactdom.hydrate') >= 0 ||
        sample.indexOf('__next_data__') >= 0
    )
        signals.push('hydration');
    if (sample.indexOf('serviceworker.register') >= 0) signals.push('service-worker-register');
    if (sample.indexOf('new worker(') >= 0 || sample.indexOf('sharedworker(') >= 0)
        signals.push('worker-bootstrap');
    if (sample.indexOf('webassembly') >= 0) signals.push('wasm-bootstrap');
    if (
        sample.indexOf('graphql') >= 0 ||
        sample.indexOf('apollo') >= 0 ||
        sample.indexOf('relay') >= 0
    )
        signals.push('graphql-client');
    if (sample.indexOf('import(') >= 0) signals.push('dynamic-import');
    if (sample.indexOf('sourcemappingurl=data:') >= 0) signals.push('inline-source-map');
    if (
        sample.indexOf('webpackchunk') >= 0 ||
        sample.indexOf('__webpack_require__.e') >= 0 ||
        sample.indexOf('parcelrequire') >= 0 ||
        sample.indexOf('__vite__') >= 0
    )
        signals.push('chunk-loader');
    if (sample.indexOf('router') >= 0 || sample.indexOf('history.pushstate') >= 0)
        signals.push('router');
    return uniqueStrings(signals);
}

function extractRouteHintsFromUrl(url) {
    var hints = [];
    try {
        var parsed = new URL(url);
        var parts = parsed.pathname.split('/');
        for (var i = 0; i < parts.length; i++) {
            var part = safeDecodeURIComponent(parts[i]).replace(/\.[A-Za-z0-9]+$/, '');
            if (!part || part.length < 3) continue;
            if (/^(static|assets|chunks|build|dist|js|runtime|vendor)$/i.test(part)) continue;
            if (/^[0-9a-f_-]{8,}$/i.test(part)) continue;
            hints.push(part);
        }
    } catch (_) {}
    return uniqueStrings(hints).slice(0, 6);
}

function extractImportSpecifiers(content) {
    var imports = [];
    var patterns = [
        /\bimport\s*(?:[^"'`]*?from\s*)?["'`]([^"'`]+)["'`]/g,
        /\bimport\s*\(\s*["'`]([^"'`]+)["'`]\s*\)/g,
        /\brequire\s*\(\s*["'`]([^"'`]+)["'`]\s*\)/g,
    ];
    for (var i = 0; i < patterns.length; i++) {
        patterns[i].lastIndex = 0;
        var match;
        while ((match = patterns[i].exec(content)) && imports.length < 40) {
            if (match[1]) imports.push(match[1]);
        }
    }
    return uniqueStrings(imports);
}

function countMatches(text, pattern) {
    pattern.lastIndex = 0;
    var count = 0;
    while (pattern.exec(text)) count++;
    pattern.lastIndex = 0;
    return count;
}

function classifyScriptAsset(url, content, bundler, frameworkHints, startupSignals) {
    var sample = (String(url || '') + '\n' + String(content || '')).toLowerCase();
    if (
        /runtime|manifest|polyfill|bootstrap/.test(sample) ||
        startupSignals.indexOf('chunk-loader') >= 0
    )
        return 'runtime';
    if (/vendor|node_modules|chunk-vendors/.test(sample)) return 'vendor';
    if (
        frameworkHints.length &&
        /react|vue|angular|next|nuxt|svelte|astro|remix/i.test(frameworkHints.join(' '))
    )
        return 'framework';
    if (bundler !== 'unknown' && startupSignals.indexOf('hydration') >= 0) return 'app';
    if (startupSignals.length || extractRouteHintsFromUrl(url).length) return 'app';
    return 'app';
}

function scoreScriptAsset(entry) {
    var score =
        entry.classification === 'app'
            ? 48
            : entry.classification === 'runtime'
              ? 34
              : entry.classification === 'framework'
                ? 24
                : 18;
    score += entry.startupSignals.length * 7;
    score += entry.routeHints.length * 4;
    score += Math.min(12, entry.moduleSignals.dynamicImports * 2 + entry.moduleSignals.importCount);
    if (entry.sourceMapEmbedded) score += 6;
    if (entry.transferSize) score += Math.min(12, Math.round(entry.transferSize / 50000));
    return score;
}

function buildChunkSummary(assets) {
    var summary = {
        totalScripts: assets.length,
        bundlersObserved: uniqueStrings(
            assets.map(function (item) {
                return item.bundler;
            }),
        ).filter(function (item) {
            return item && item !== 'unknown';
        }),
        classifications: countPropertyValues(assets, 'classification'),
        boundaryLabels: countBoundaryLabels(assets),
        sourceMapEmbedded: 0,
        dynamicImporters: 0,
        labeledScripts: countTaggedEntries(assets),
    };
    for (var i = 0; i < assets.length; i++) {
        if (assets[i].sourceMapEmbedded) summary.sourceMapEmbedded++;
        if (assets[i].moduleSignals.dynamicImports > 0) summary.dynamicImporters++;
    }
    return summary;
}

function stripChunkAsset(asset) {
    return {
        id: asset.id,
        url: asset.url,
        file: asset.file,
        size: asset.size,
        transferSize: asset.transferSize,
        startTime: asset.startTime,
        duration: asset.duration,
        classification: asset.classification,
        bundler: asset.bundler,
        frameworkHints: asset.frameworkHints,
        routeHints: asset.routeHints,
        startupSignals: asset.startupSignals,
        boundaryLabels: asset.boundaryLabels || [],
        primaryBoundary: asset.primaryBoundary || '',
        boundaryReasons: asset.boundaryReasons || [],
        imports: asset.imports,
        moduleSignals: asset.moduleSignals,
        sourceMapEmbedded: asset.sourceMapEmbedded,
        score: asset.score,
    };
}

function buildRuntimeOrigins(runtimeEntries, runtimeManifest, assets) {
    var manifestById = {};
    for (var i = 0; i < runtimeManifest.length; i++)
        manifestById[runtimeManifest[i].id] = runtimeManifest[i];
    var runtimeOrigins = [];
    for (var j = 0; j < runtimeEntries.length; j++) {
        var item = {};
        var source = runtimeEntries[j] || {};
        var manifestItem = manifestById[source.id] || null;
        if (manifestItem)
            for (var mk in manifestItem)
                if (Object.prototype.hasOwnProperty.call(manifestItem, mk))
                    item[mk] = manifestItem[mk];
        for (var sk in source)
            if (Object.prototype.hasOwnProperty.call(source, sk)) item[sk] = source[sk];
        item.stackRefs = extractStackRefs(item.stack);
        item.relatedChunks = [];
        var directAsset = findAssetByReference(item.url || item.objectUrl, assets);
        if (directAsset) item.relatedChunks.push(directAsset.id);
        for (var r = 0; r < item.stackRefs.length; r++) {
            var stackAsset = findAssetByReference(item.stackRefs[r], assets);
            if (stackAsset) item.relatedChunks.push(stackAsset.id);
        }
        item.relatedChunks = uniqueStrings(item.relatedChunks);
        item.originType = determineRuntimeOriginType(item);
        item.score = scoreRuntimeEntry(item);
        runtimeOrigins.push(item);
    }
    return runtimeOrigins;
}

function getBareFileName(value) {
    value = stripUrlVariant(String(value || '')).replace(/\\/g, '/');
    var slash = value.lastIndexOf('/');
    return slash >= 0 ? value.substring(slash + 1) : value;
}

function cleanStackReference(value) {
    value = String(value || '')
        .trim()
        .replace(/[),]+$/, '');
    return value.replace(/:\d+:\d+$/, '').replace(/:\d+$/, '');
}

function extractStackRefs(stack) {
    var refs = [];
    var match;
    var pattern = /(https?:\/\/[^\s)]+|blob:[^\s)]+)/g;
    while ((match = pattern.exec(String(stack || ''))) && refs.length < 12)
        refs.push(cleanStackReference(match[1]));
    return uniqueStrings(refs);
}

function findAssetByReference(reference, assets) {
    var cleaned = cleanStackReference(reference);
    if (!cleaned) return null;
    var full = normalizeUrlKey(cleaned);
    var bare = stripUrlVariant(cleaned);
    var file = getBareFileName(cleaned);
    for (var i = 0; i < assets.length; i++) {
        if (
            assets[i].url === cleaned ||
            normalizeUrlKey(assets[i].url) === full ||
            stripUrlVariant(assets[i].url) === bare ||
            getBareFileName(assets[i].url) === file
        )
            return assets[i];
    }
    return null;
}

function determineRuntimeOriginType(entry) {
    if (entry.blobId) return 'blob-derived';
    if (entry.kind === 'script-injection') return 'inline-script';
    if (
        entry.kind === 'worker' ||
        entry.kind === 'shared-worker' ||
        entry.kind === 'service-worker'
    )
        return 'worker-bootstrap';
    if (entry.kind === 'wasm') return 'wasm-module';
    if (entry.relatedChunks && entry.relatedChunks.length) return 'bundle-linked';
    if (entry.url && /^blob:/i.test(entry.url)) return 'object-url';
    if (entry.url && /^data:/i.test(entry.url)) return 'data-url';
    return 'runtime-generated';
}

function scoreRuntimeEntry(entry) {
    var score =
        entry.kind === 'eval' || entry.kind === 'function'
            ? 46
            : entry.kind === 'wasm'
              ? 42
              : entry.kind === 'script-injection'
                ? 38
                : 28;
    if (entry.relatedChunks && entry.relatedChunks.length) score += entry.relatedChunks.length * 8;
    if (entry.blobId) score += 10;
    if (typeof entry.text === 'string') score += 6;
    if (entry.timestamp) score += 4;
    return score;
}

function stripRuntimeEntry(entry) {
    return {
        id: entry.id,
        kind: entry.kind,
        file: entry.file || '',
        source: entry.source || '',
        url: entry.url || '',
        objectUrl: entry.objectUrl || '',
        blobId: entry.blobId || null,
        originType: entry.originType,
        relatedChunks: entry.relatedChunks || [],
        stackRefs: entry.stackRefs || [],
        timestamp: entry.timestamp || 0,
        mimeType: entry.mimeType || '',
        size: entry.size || 0,
        truncated: !!entry.truncated,
        note: entry.note || '',
        score: entry.score || 0,
    };
}

function buildRuntimeSummary(runtimeOrigins) {
    return {
        totalRuntimeEntries: runtimeOrigins.length,
        kinds: countPropertyValues(runtimeOrigins, 'kind'),
        originTypes: countPropertyValues(runtimeOrigins, 'originType'),
        boundaryLabels: countBoundaryLabels(runtimeOrigins),
        linkedToChunks: runtimeOrigins.filter(function (item) {
            return item.relatedChunks && item.relatedChunks.length;
        }).length,
        labeledEntries: countTaggedEntries(runtimeOrigins),
    };
}

function buildModuleGraph(reconData, assets, runtimeOrigins) {
    var nodes = [];
    var edges = [];
    var nodeMap = {};
    var edgeMap = {};
    function addNode(id, type, label, meta) {
        if (nodeMap[id]) return;
        var node = { id: id, type: type, label: label };
        if (meta) node.meta = meta;
        nodeMap[id] = node;
        nodes.push(node);
    }
    function addEdge(from, to, reason, meta) {
        var key = from + '->' + to + ':' + reason;
        if (edgeMap[key]) return;
        var edge = { from: from, to: to, reason: reason };
        if (meta) edge.meta = meta;
        edgeMap[key] = edge;
        edges.push(edge);
    }
    addNode(
        'page',
        'page',
        reconData && reconData.page && reconData.page.url ? reconData.page.url : 'page',
    );
    for (var i = 0; i < assets.length; i++) {
        addNode(assets[i].id, 'chunk', getBareFileName(assets[i].url), {
            classification: assets[i].classification,
            bundler: assets[i].bundler,
            primaryBoundary: assets[i].primaryBoundary || '',
        });
        addEdge('page', assets[i].id, 'resource', { startTime: assets[i].startTime });
        for (var j = 0; j < assets[i].imports.length; j++) {
            var specifier = assets[i].imports[j];
            var targetAsset = findAssetByReference(specifier, assets);
            if (targetAsset && targetAsset.id !== assets[i].id)
                addEdge(assets[i].id, targetAsset.id, 'imports', { specifier: specifier });
            else {
                var depId =
                    (specifier.indexOf('.') === 0 || specifier.indexOf('/') >= 0
                        ? 'ref:'
                        : 'pkg:') + specifier;
                addNode(depId, depId.indexOf('pkg:') === 0 ? 'package' : 'reference', specifier);
                addEdge(assets[i].id, depId, 'imports', { specifier: specifier });
            }
        }
    }
    for (var r = 0; r < runtimeOrigins.length; r++) {
        var runtimeId = 'runtime:' + runtimeOrigins[r].id;
        addNode(runtimeId, 'runtime', runtimeOrigins[r].kind, {
            originType: runtimeOrigins[r].originType,
            file: runtimeOrigins[r].file || '',
            primaryBoundary: runtimeOrigins[r].primaryBoundary || '',
        });
        if (runtimeOrigins[r].relatedChunks && runtimeOrigins[r].relatedChunks.length) {
            for (var c = 0; c < runtimeOrigins[r].relatedChunks.length; c++)
                addEdge(
                    runtimeOrigins[r].relatedChunks[c],
                    runtimeId,
                    runtimeOrigins[r].originType,
                );
        } else if (runtimeOrigins[r].blobId)
            addEdge('runtime:' + runtimeOrigins[r].blobId, runtimeId, 'spawns');
        else addEdge('page', runtimeId, runtimeOrigins[r].originType);
    }
    var graphqlOps = reconData && reconData.recon ? collectGraphQLOperations(reconData.recon) : [];
    var endpoints = uniqueStrings(
        graphqlOps.map(function (item) {
            return item.url;
        }),
    ).slice(0, 12);
    for (var e = 0; e < endpoints.length; e++) {
        addNode('endpoint:' + endpoints[e], 'endpoint', endpoints[e]);
        addEdge('page', 'endpoint:' + endpoints[e], 'graphql');
    }
    return {
        generatedAt: new Date().toISOString(),
        summary: {
            nodes: nodes.length,
            edges: edges.length,
            runtimeNodes: runtimeOrigins.length,
            chunkNodes: assets.length,
        },
        nodes: nodes,
        edges: edges,
    };
}

function collectNetworkOperations(recon) {
    var operations = [];
    var groups = [
        { type: 'xhr', items: recon && recon.xhr ? recon.xhr : [] },
        { type: 'fetch', items: recon && recon.fetch ? recon.fetch : [] },
    ];
    for (var i = 0; i < groups.length; i++) {
        for (var j = 0; j < groups[i].items.length; j++) {
            var item = groups[i].items[j] || {};
            operations.push({
                type: groups[i].type,
                url: item.url || '',
                method: item.method || 'GET',
                status: item.status || 0,
                timestamp: item.timestamp || 0,
                requestBody: item.requestBody || '',
                requestHeaders: item.requestHeaders || {},
                responseHeaders: item.responseHeaders || '',
                responsePreview:
                    item.responseText || item.responseBodyExcerpt || item.responsePreview || '',
            });
        }
    }
    operations.sort(function (a, b) {
        return (a.timestamp || 0) - (b.timestamp || 0);
    });
    return operations;
}

function buildStartupChain(reconData, assets, runtimeOrigins) {
    var networkOps = collectNetworkOperations(
        reconData && reconData.recon ? reconData.recon : null,
    );
    var graphqlOps = reconData && reconData.recon ? collectGraphQLOperations(reconData.recon) : [];
    var scripts = assets
        .slice()
        .sort(function (a, b) {
            return (a.startTime || 0) - (b.startTime || 0);
        })
        .slice(0, 40)
        .map(function (item) {
            return {
                id: item.id,
                url: item.url,
                classification: item.classification,
                primaryBoundary: item.primaryBoundary || '',
                startTime: item.startTime,
                duration: item.duration,
                startupSignals: item.startupSignals,
            };
        });
    var runtime = runtimeOrigins
        .slice()
        .sort(function (a, b) {
            return (a.timestamp || 0) - (b.timestamp || 0);
        })
        .slice(0, 40)
        .map(function (item) {
            return {
                id: item.id,
                kind: item.kind,
                originType: item.originType,
                primaryBoundary: item.primaryBoundary || '',
                timestamp: item.timestamp || 0,
                relatedChunks: item.relatedChunks || [],
                file: item.file || '',
            };
        });
    return {
        generatedAt: new Date().toISOString(),
        profile:
            reconData && reconData.captureStatus && reconData.captureStatus.profile
                ? reconData.captureStatus.profile
                : reconData && reconData.stackProfile && reconData.stackProfile.strategy
                  ? reconData.stackProfile.strategy.profile
                  : 'generic-app',
        scripts: scripts,
        runtime: runtime,
        data: networkOps.slice(0, 40),
        graphql: graphqlOps.slice(0, 20),
        summary: {
            scripts: assets.length,
            runtime: runtimeOrigins.length,
            dataRequests: networkOps.length,
            graphqlOperations: graphqlOps.length,
        },
    };
}

function buildFrameworkRuntimeSummary(
    reconData,
    assets,
    runtimeOrigins,
    interestingEntrypoints,
    boundaryLabels,
    crossBoundaryFlows,
) {
    var stackProfile = reconData && reconData.stackProfile ? reconData.stackProfile : {};
    var captureStatus = reconData && reconData.captureStatus ? reconData.captureStatus : {};
    var graphqlOps = reconData && reconData.recon ? collectGraphQLOperations(reconData.recon) : [];
    var frameworkState = buildFrameworkStateSummary(
        reconData && reconData.frameworkState ? reconData.frameworkState : null,
    );
    return {
        generatedAt: new Date().toISOString(),
        page: reconData && reconData.page ? reconData.page : {},
        profile:
            captureStatus.profile ||
            (stackProfile.strategy && stackProfile.strategy.profile) ||
            'generic-app',
        confidence: stackProfile.confidence || captureStatus.confidence || 0,
        technologies: stackProfile.technologies || [],
        traits: stackProfile.traits || [],
        strategy: stackProfile.strategy || null,
        captureReason: captureStatus.reasonText || '',
        assetClasses: countPropertyValues(assets, 'classification'),
        bundlersObserved: uniqueStrings(
            assets.map(function (item) {
                return item.bundler;
            }),
        ).filter(function (item) {
            return item && item !== 'unknown';
        }),
        boundaries: boundaryLabels ? boundaryLabels.summary : null,
        runtimeKinds: countPropertyValues(runtimeOrigins, 'kind'),
        graphQLEndpoints: uniqueStrings(
            graphqlOps.map(function (item) {
                return item.url;
            }),
        ).slice(0, 20),
        topBoundaryFlows: crossBoundaryFlows ? crossBoundaryFlows.topTransitions.slice(0, 8) : [],
        likelyEntrypoints: interestingEntrypoints.slice(0, 6),
        frameworkState: frameworkState,
        signals: captureStatus.signals || null,
    };
}

function buildFrameworkStateSummary(frameworkState) {
    if (!frameworkState) return null;
    var router = frameworkState.router || {};
    var summary = frameworkState.summary || {};
    var technologies = Array.isArray(frameworkState.technologies)
        ? frameworkState.technologies
        : [];
    return {
        profile: frameworkState.profile || 'generic-app',
        generatedAt: frameworkState.generatedAt || '',
        reason: frameworkState.reason || '',
        rootCount:
            frameworkState.roots && frameworkState.roots.length ? frameworkState.roots.length : 0,
        storeCount:
            frameworkState.stores && frameworkState.stores.length
                ? frameworkState.stores.length
                : 0,
        queryCount:
            frameworkState.queries && frameworkState.queries.length
                ? frameworkState.queries.length
                : 0,
        hydrationCount:
            frameworkState.hydration && frameworkState.hydration.length
                ? frameworkState.hydration.length
                : 0,
        authCount:
            frameworkState.auth && frameworkState.auth.length ? frameworkState.auth.length : 0,
        routerFramework: router.framework || summary.routerFramework || 'generic',
        route: router.route || router.pathname || '',
        routerSource: router.source || '',
        queryKeyCount: router.queryKeys && router.queryKeys.length ? router.queryKeys.length : 0,
        detectedTechnologies: uniqueStrings(
            technologies
                .map(function (item) {
                    return item && item.name ? item.name : '';
                })
                .concat(summary.detectedTechnologies || []),
        ).filter(Boolean),
        roots: frameworkState.roots || [],
        stores: frameworkState.stores || [],
        queries: frameworkState.queries || [],
        hydration: frameworkState.hydration || [],
        auth: frameworkState.auth || [],
        relatedArtifacts: collectFrameworkArtifactPaths(frameworkState),
    };
}

function collectFrameworkArtifactPaths(frameworkState) {
    if (!frameworkState) return [];
    var artifacts = [];
    if (frameworkState.summary && Object.keys(frameworkState.summary).length)
        artifacts.push('_framework/summary.json');
    if (frameworkState.router && Object.keys(frameworkState.router).length)
        artifacts.push('_framework/router-state.json');
    if (frameworkState.roots && frameworkState.roots.length)
        artifacts.push('_framework/framework-roots.json');
    if (frameworkState.stores && frameworkState.stores.length)
        artifacts.push('_framework/store-snapshots.json');
    if (frameworkState.queries && frameworkState.queries.length)
        artifacts.push('_framework/query-caches.json');
    if (frameworkState.hydration && frameworkState.hydration.length)
        artifacts.push('_framework/hydration-payloads.json');
    if (frameworkState.auth && frameworkState.auth.length)
        artifacts.push('_framework/auth-state.json');
    return artifacts;
}

function buildBoundaryLabels(reconData, assets, runtimeOrigins) {
    var assetMap = {};
    for (var i = 0; i < assets.length; i++) assetMap[assets[i].id] = assets[i];
    for (var j = 0; j < assets.length; j++)
        applyBoundaryLabels(assets[j], inferBoundaryLabels(assets[j], false, assetMap));
    for (var r = 0; r < runtimeOrigins.length; r++)
        applyBoundaryLabels(
            runtimeOrigins[r],
            inferBoundaryLabels(runtimeOrigins[r], true, assetMap),
        );
    return {
        generatedAt: new Date().toISOString(),
        categories: [
            'bootstrap',
            'router',
            'state',
            'data',
            'auth',
            'analytics',
            'editor',
            'vendor',
        ],
        summary: {
            chunkLabels: countBoundaryLabels(assets),
            runtimeLabels: countBoundaryLabels(runtimeOrigins),
            taggedChunks: countTaggedEntries(assets),
            taggedRuntime: countTaggedEntries(runtimeOrigins),
        },
        chunks: assets
            .filter(function (item) {
                return item.boundaryLabels && item.boundaryLabels.length;
            })
            .sort(function (a, b) {
                return (b.score || 0) - (a.score || 0);
            })
            .map(function (item) {
                return stripBoundaryEntry(item, 'chunk');
            }),
        runtime: runtimeOrigins
            .filter(function (item) {
                return item.boundaryLabels && item.boundaryLabels.length;
            })
            .sort(function (a, b) {
                return (b.score || 0) - (a.score || 0);
            })
            .map(function (item) {
                return stripBoundaryEntry(item, 'runtime');
            }),
    };
}

function buildCrossBoundaryFlows(reconData, assets, runtimeOrigins) {
    var flowData = collectFlowEvents(reconData, assets, runtimeOrigins);
    var eventMap = flowData.eventMap;
    var flows = [];
    var flowMap = {};

    for (var i = 0; i < assets.length; i++) {
        var fromAsset = assets[i];
        var fromEvent = eventMap['chunk:' + fromAsset.id];
        if (!fromEvent) continue;
        for (var j = 0; j < fromAsset.imports.length; j++) {
            var targetAsset = findAssetByReference(fromAsset.imports[j], assets);
            if (!targetAsset || targetAsset.id === fromAsset.id) continue;
            var toEvent = eventMap['chunk:' + targetAsset.id];
            if (
                !toEvent ||
                !fromEvent.primaryBoundary ||
                !toEvent.primaryBoundary ||
                fromEvent.primaryBoundary === toEvent.primaryBoundary
            )
                continue;
            addBoundaryFlow(
                flows,
                flowMap,
                fromEvent,
                toEvent,
                'imports-boundary',
                46 + countSharedValues(fromEvent.boundaryLabels, toEvent.boundaryLabels) * 3,
                'chunk imports a differently labeled dependency',
                Math.max(0, (toEvent.approxTime || 0) - (fromEvent.approxTime || 0)),
            );
        }
    }

    for (var r = 0; r < runtimeOrigins.length; r++) {
        var runtime = runtimeOrigins[r];
        var runtimeEvent = eventMap['runtime:' + runtime.id];
        if (!runtimeEvent) continue;
        for (var c = 0; c < (runtime.relatedChunks || []).length; c++) {
            var chunkEvent = eventMap['chunk:' + runtime.relatedChunks[c]];
            if (!chunkEvent) continue;
            addBoundaryFlow(
                flows,
                flowMap,
                chunkEvent,
                runtimeEvent,
                'materializes-runtime',
                68 + countSharedValues(chunkEvent.boundaryLabels, runtimeEvent.boundaryLabels) * 2,
                'runtime artifact links back to its originating chunk',
                Math.max(0, (runtimeEvent.approxTime || 0) - (chunkEvent.approxTime || 0)),
            );
        }
        if (runtime.blobId) {
            var parentRuntime = eventMap['runtime:' + runtime.blobId];
            if (parentRuntime)
                addBoundaryFlow(
                    flows,
                    flowMap,
                    parentRuntime,
                    runtimeEvent,
                    'spawns-runtime',
                    64,
                    'blob ancestry connects these runtime artifacts',
                    Math.max(0, (runtimeEvent.approxTime || 0) - (parentRuntime.approxTime || 0)),
                );
        }
    }

    var timedEvents = flowData.events
        .filter(function (item) {
            return item.primaryBoundary;
        })
        .slice()
        .sort(function (a, b) {
            return (a.approxTime || 0) - (b.approxTime || 0);
        });
    for (var a = 0; a < timedEvents.length; a++) {
        for (var b = a + 1; b < timedEvents.length && b < a + 5; b++) {
            var deltaMs = (timedEvents[b].approxTime || 0) - (timedEvents[a].approxTime || 0);
            if (deltaMs <= 0 || deltaMs > 4000) break;
            var score = scoreFlowTransition(timedEvents[a], timedEvents[b], deltaMs);
            if (score < 34) continue;
            addBoundaryFlow(
                flows,
                flowMap,
                timedEvents[a],
                timedEvents[b],
                inferFlowRelation(timedEvents[a], timedEvents[b]),
                score,
                describeFlowTransition(timedEvents[a], timedEvents[b], deltaMs),
                deltaMs,
            );
        }
    }

    var topTransitions = summarizeBoundaryTransitions(flows);
    return {
        generatedAt: new Date().toISOString(),
        summary: {
            totalFlows: flows.length,
            crossBoundaryFlows: flows.filter(function (item) {
                return item.crossBoundary;
            }).length,
            structuralFlows: flows.filter(function (item) {
                return !item.crossBoundary;
            }).length,
            labeledEvents: flowData.events.filter(function (item) {
                return item.primaryBoundary;
            }).length,
            eventKinds: countPropertyValues(flowData.events, 'kind'),
            relations: countPropertyValues(flows, 'relation'),
        },
        topTransitions: topTransitions,
        chains: buildBoundaryChains(flows),
        events: flowData.events
            .filter(function (item) {
                return item.primaryBoundary;
            })
            .slice(0, 120)
            .map(stripFlowEvent),
        transitions: flows.slice(0, 180).map(stripFlowTransition),
    };
}

function collectFlowEvents(reconData, assets, runtimeOrigins) {
    var events = [];
    var eventMap = {};
    var assetHorizon = 0;
    var networkOps = buildNetworkFlowEvents(reconData && reconData.recon ? reconData.recon : null);
    var absoluteTimes = [];
    for (var i = 0; i < runtimeOrigins.length; i++)
        if (runtimeOrigins[i].timestamp > 0) absoluteTimes.push(runtimeOrigins[i].timestamp);
    for (var j = 0; j < networkOps.length; j++)
        if (networkOps[j].timestamp > 0) absoluteTimes.push(networkOps[j].timestamp);
    var absoluteBase = absoluteTimes.length ? Math.min.apply(Math, absoluteTimes) : 0;

    for (var a = 0; a < assets.length; a++) {
        var asset = assets[a];
        var assetTime = typeof asset.startTime === 'number' ? asset.startTime : a * 25;
        var assetEvent = buildFlowEvent('chunk', asset.id, asset, assetTime);
        events.push(assetEvent);
        eventMap[assetEvent.id] = assetEvent;
        assetHorizon = Math.max(assetHorizon, assetTime + (asset.duration || 0));
    }

    var absoluteOffset = assetHorizon + 50;
    for (var r = 0; r < runtimeOrigins.length; r++) {
        var runtime = runtimeOrigins[r];
        var runtimeTime =
            runtime.timestamp > 0 && absoluteBase
                ? absoluteOffset + (runtime.timestamp - absoluteBase)
                : absoluteOffset + r * 25;
        var runtimeEvent = buildFlowEvent('runtime', runtime.id, runtime, runtimeTime);
        events.push(runtimeEvent);
        eventMap[runtimeEvent.id] = runtimeEvent;
    }

    for (var n = 0; n < networkOps.length; n++) {
        var operation = networkOps[n];
        var operationTime =
            operation.timestamp > 0 && absoluteBase
                ? absoluteOffset + (operation.timestamp - absoluteBase)
                : absoluteOffset + (runtimeOrigins.length + n) * 25;
        var networkEvent = buildFlowEvent('network', operation.id, operation, operationTime);
        events.push(networkEvent);
        eventMap[networkEvent.id] = networkEvent;
    }

    events.sort(function (left, right) {
        return (left.approxTime || 0) - (right.approxTime || 0);
    });
    return { events: events, eventMap: eventMap };
}

function buildNetworkFlowEvents(recon) {
    var operations = collectNetworkOperations(recon);
    for (var i = 0; i < operations.length; i++) {
        operations[i].id = operations[i].type + '-' + ('0000' + (i + 1)).slice(-4);
        operations[i].label =
            (operations[i].method || 'GET') +
            ' ' +
            (getBareFileName(operations[i].url) || operations[i].type || operations[i].id);
        applyBoundaryLabels(operations[i], inferNetworkBoundaryLabels(operations[i]));
    }
    return operations;
}

function inferNetworkBoundaryLabels(entry) {
    var sample = buildNetworkBoundarySample(entry);
    var matches = [];
    if (
        /auth0|next-auth|firebase\/auth|supabase\.auth|oauth|bearer|jwt|csrf|signin|signout|login|logout|session|token|refresh|clerk|okta|passport/.test(
            sample,
        )
    )
        pushBoundaryLabel(
            matches,
            'auth',
            28,
            'network activity contains authentication or session signals',
        );
    if (
        /google-analytics|googletagmanager|gtag|segment|mixpanel|amplitude|posthog|hotjar|fullstory|datadog|sentry|analytics|\/collect\b|\/track\b|\/capture\b/.test(
            sample,
        )
    )
        pushBoundaryLabel(
            matches,
            'analytics',
            26,
            'network activity contains analytics or telemetry signals',
        );
    if (
        /graphql|apollo|relay|axios|tanstack|react-query|swr|trpc|\/api\/|jsonrpc|rpc|query=|mutation=|xmlhttprequest|fetch/.test(
            sample,
        ) ||
        looksLikeGraphQLBody(entry.requestBody)
    )
        pushBoundaryLabel(
            matches,
            'data',
            24,
            'network activity contains data-fetching or API signals',
        );
    if (
        /_next\/data\/|prefetch|router|route|navigate|navigation|redirect=|callbackurl=/.test(
            sample,
        )
    )
        pushBoundaryLabel(
            matches,
            'router',
            18,
            'network activity contains routing or navigation signals',
        );
    if (
        /draft|editor|document|content|prosemirror|tiptap|quill|slate|monaco|codemirror/.test(
            sample,
        )
    )
        pushBoundaryLabel(
            matches,
            'editor',
            18,
            'network activity contains editor or content workflow signals',
        );
    if (/persist|rehydrate|redux|zustand|state/.test(sample))
        pushBoundaryLabel(
            matches,
            'state',
            14,
            'network activity contains state synchronization signals',
        );
    return matches;
}

function buildNetworkBoundarySample(entry) {
    return [
        entry.type || '',
        entry.url || '',
        entry.method || '',
        stringifyLooseValue(entry.requestBody),
        stringifyLooseValue(entry.requestHeaders),
        stringifyLooseValue(entry.responseHeaders),
        stringifyLooseValue(entry.responsePreview),
    ]
        .join('\n')
        .toLowerCase();
}

function stringifyLooseValue(value) {
    if (typeof value === 'string') return value;
    if (value == null) return '';
    try {
        return JSON.stringify(value);
    } catch (_) {
        return String(value);
    }
}

function buildFlowEvent(kind, recordId, entry, approxTime) {
    return {
        id: kind + ':' + recordId,
        recordId: recordId,
        kind: kind,
        label:
            entry.label ||
            getBareFileName(
                entry.file || entry.url || entry.objectUrl || entry.id || entry.kind || recordId,
            ) ||
            recordId,
        primaryBoundary: entry.primaryBoundary || '',
        boundaryLabels: entry.boundaryLabels || [],
        approxTime: approxTime || 0,
        timestamp: entry.timestamp || 0,
        url: entry.url || entry.objectUrl || '',
        file: entry.file || '',
        method: entry.method || '',
        status: entry.status || 0,
        classification: entry.classification || '',
        originType: entry.originType || '',
        relatedChunks: entry.relatedChunks || [],
        blobId: entry.blobId || null,
        source: entry.source || entry.type || '',
        boundaryReasons: entry.boundaryReasons || [],
    };
}

function inferFlowRelation(fromEvent, toEvent) {
    if (fromEvent.kind === 'chunk' && toEvent.kind === 'chunk') return 'imports-boundary';
    if (fromEvent.kind === 'chunk' && toEvent.kind === 'runtime') return 'materializes-runtime';
    if (fromEvent.kind === 'runtime' && toEvent.kind === 'runtime') return 'spawns-runtime';
    if (toEvent.kind === 'network') return 'triggers-request';
    if (fromEvent.kind === 'network') return 'follows-response';
    return 'sequence';
}

function addBoundaryFlow(
    flows,
    flowMap,
    fromEvent,
    toEvent,
    relation,
    confidence,
    evidence,
    deltaMs,
) {
    if (!fromEvent || !toEvent || fromEvent.id === toEvent.id) return;
    if (!fromEvent.primaryBoundary || !toEvent.primaryBoundary) return;
    var crossBoundary = fromEvent.primaryBoundary !== toEvent.primaryBoundary;
    if (!crossBoundary && relation !== 'materializes-runtime' && relation !== 'spawns-runtime')
        return;
    var key = [
        fromEvent.id,
        toEvent.id,
        relation,
        fromEvent.primaryBoundary,
        toEvent.primaryBoundary,
    ].join('|');
    if (flowMap[key]) return;
    flowMap[key] = true;
    flows.push({
        id: 'flow-' + ('0000' + (flows.length + 1)).slice(-4),
        relation: relation,
        crossBoundary: crossBoundary,
        fromBoundary: fromEvent.primaryBoundary,
        toBoundary: toEvent.primaryBoundary,
        confidence: confidence || 0,
        deltaMs: typeof deltaMs === 'number' ? Math.round(deltaMs) : null,
        timestamp:
            toEvent.timestamp ||
            toEvent.approxTime ||
            fromEvent.timestamp ||
            fromEvent.approxTime ||
            0,
        evidence: evidence || '',
        from: stripFlowEvent(fromEvent),
        to: stripFlowEvent(toEvent),
    });
}

function scoreFlowTransition(fromEvent, toEvent, deltaMs) {
    if (
        !fromEvent ||
        !toEvent ||
        !fromEvent.primaryBoundary ||
        !toEvent.primaryBoundary ||
        fromEvent.id === toEvent.id
    )
        return 0;
    var crossBoundary = fromEvent.primaryBoundary !== toEvent.primaryBoundary;
    if (
        !crossBoundary &&
        !(fromEvent.kind === 'chunk' && toEvent.kind === 'runtime') &&
        !(fromEvent.kind === 'runtime' && toEvent.kind === 'runtime')
    )
        return 0;
    var score = 0;
    if (fromEvent.kind === 'chunk' && toEvent.kind === 'chunk') score += 12;
    if (fromEvent.kind === 'runtime' && toEvent.kind === 'network') score += 18;
    if (fromEvent.kind === 'network' && toEvent.kind === 'runtime') score += 18;
    if (fromEvent.kind === 'network' && toEvent.kind === 'network') score += 8;
    if (
        fromEvent.primaryBoundary === 'bootstrap' &&
        arrayContainsAny(['router', 'state', 'data', 'auth'], [toEvent.primaryBoundary])
    )
        score += 18;
    if (
        fromEvent.primaryBoundary === 'auth' &&
        arrayContainsAny(['data', 'router', 'analytics'], [toEvent.primaryBoundary])
    )
        score += 22;
    if (
        fromEvent.primaryBoundary === 'data' &&
        arrayContainsAny(['router', 'analytics', 'state', 'editor'], [toEvent.primaryBoundary])
    )
        score += 20;
    if (
        fromEvent.primaryBoundary === 'router' &&
        arrayContainsAny(['data', 'analytics'], [toEvent.primaryBoundary])
    )
        score += 16;
    if (
        fromEvent.primaryBoundary === 'state' &&
        arrayContainsAny(['data', 'router'], [toEvent.primaryBoundary])
    )
        score += 14;
    if (
        fromEvent.primaryBoundary === 'editor' &&
        arrayContainsAny(['data', 'state', 'analytics'], [toEvent.primaryBoundary])
    )
        score += 14;
    if (
        fromEvent.primaryBoundary === 'vendor' &&
        arrayContainsAny(['analytics', 'auth', 'data'], [toEvent.primaryBoundary])
    )
        score += 8;
    score += Math.min(10, countSharedValues(fromEvent.boundaryLabels, toEvent.boundaryLabels) * 3);
    if (typeof deltaMs === 'number' && deltaMs >= 0)
        score += Math.max(0, 12 - Math.floor(deltaMs / 350));
    return score;
}

function describeFlowTransition(fromEvent, toEvent, deltaMs) {
    var lag =
        typeof deltaMs === 'number' && deltaMs >= 0 ? ' ' + Math.round(deltaMs) + 'ms later' : '';
    if (fromEvent.kind === 'runtime' && toEvent.kind === 'network')
        return 'runtime activity was followed by a labeled request' + lag;
    if (fromEvent.kind === 'network' && toEvent.kind === 'runtime')
        return 'network activity was followed by a labeled runtime effect' + lag;
    if (fromEvent.kind === 'network' && toEvent.kind === 'network')
        return 'one labeled request preceded another labeled request' + lag;
    if (fromEvent.kind === 'chunk' && toEvent.kind === 'chunk')
        return 'one labeled chunk imported another labeled chunk' + lag;
    return (
        fromEvent.primaryBoundary +
        ' activity led into ' +
        toEvent.primaryBoundary +
        ' activity' +
        lag
    );
}

function countSharedValues(left, right) {
    var count = 0;
    for (var i = 0; i < left.length; i++) if (right.indexOf(left[i]) >= 0) count++;
    return count;
}

function summarizeBoundaryTransitions(flows) {
    var grouped = {};
    for (var i = 0; i < flows.length; i++) {
        var key = flows[i].fromBoundary + '->' + flows[i].toBoundary;
        if (!grouped[key])
            grouped[key] = {
                fromBoundary: flows[i].fromBoundary,
                toBoundary: flows[i].toBoundary,
                count: 0,
                totalConfidence: 0,
                relations: {},
            };
        grouped[key].count++;
        grouped[key].totalConfidence += flows[i].confidence || 0;
        grouped[key].relations[flows[i].relation] =
            (grouped[key].relations[flows[i].relation] || 0) + 1;
    }
    var summary = [];
    for (var name in grouped) {
        if (!Object.prototype.hasOwnProperty.call(grouped, name)) continue;
        summary.push({
            path: name,
            fromBoundary: grouped[name].fromBoundary,
            toBoundary: grouped[name].toBoundary,
            count: grouped[name].count,
            averageConfidence: grouped[name].count
                ? Math.round(grouped[name].totalConfidence / grouped[name].count)
                : 0,
            relations: Object.keys(grouped[name].relations).sort(function (left, right) {
                return grouped[name].relations[right] - grouped[name].relations[left];
            }),
        });
    }
    summary.sort(function (left, right) {
        return right.count !== left.count
            ? right.count - left.count
            : right.averageConfidence - left.averageConfidence;
    });
    return summary.slice(0, 24);
}

function buildBoundaryChains(flows) {
    var timedFlows = flows
        .filter(function (item) {
            return item.crossBoundary && item.timestamp > 0;
        })
        .slice()
        .sort(function (left, right) {
            return left.timestamp - right.timestamp;
        });
    var chains = {};
    for (var i = 0; i < timedFlows.length; i++) {
        for (var j = i + 1; j < timedFlows.length && j < i + 5; j++) {
            var delta = timedFlows[j].timestamp - timedFlows[i].timestamp;
            if (delta <= 0 || delta > 6000) break;
            if (timedFlows[i].toBoundary !== timedFlows[j].fromBoundary) continue;
            var path = [
                timedFlows[i].fromBoundary,
                timedFlows[i].toBoundary,
                timedFlows[j].toBoundary,
            ];
            if (path[0] === path[2]) continue;
            var key = path.join(' -> ');
            if (!chains[key])
                chains[key] = { path: path, count: 0, totalConfidence: 0, examples: [] };
            chains[key].count++;
            chains[key].totalConfidence +=
                (timedFlows[i].confidence || 0) + (timedFlows[j].confidence || 0);
            if (chains[key].examples.length < 3)
                chains[key].examples.push([timedFlows[i].relation, timedFlows[j].relation]);
        }
    }
    var items = [];
    for (var name in chains) {
        if (!Object.prototype.hasOwnProperty.call(chains, name)) continue;
        items.push({
            path: chains[name].path,
            label: name,
            count: chains[name].count,
            averageConfidence: chains[name].count
                ? Math.round(chains[name].totalConfidence / (chains[name].count * 2))
                : 0,
            examples: chains[name].examples,
        });
    }
    items.sort(function (left, right) {
        return right.count !== left.count
            ? right.count - left.count
            : right.averageConfidence - left.averageConfidence;
    });
    return items.slice(0, 20);
}

function stripFlowTransition(flow) {
    return {
        id: flow.id,
        relation: flow.relation,
        crossBoundary: flow.crossBoundary,
        fromBoundary: flow.fromBoundary,
        toBoundary: flow.toBoundary,
        confidence: flow.confidence,
        deltaMs: flow.deltaMs,
        evidence: flow.evidence,
        from: flow.from,
        to: flow.to,
    };
}

function stripFlowEvent(event) {
    return {
        id: event.id,
        recordId: event.recordId,
        kind: event.kind,
        label: event.label,
        primaryBoundary: event.primaryBoundary,
        boundaryLabels: event.boundaryLabels || [],
        approxTime: Math.round(event.approxTime || 0),
        timestamp: event.timestamp || 0,
        url: event.url || '',
        file: event.file || '',
        method: event.method || '',
        status: event.status || 0,
        classification: event.classification || '',
        originType: event.originType || '',
    };
}

function applyBoundaryLabels(entry, matches) {
    matches.sort(function (a, b) {
        return b.score - a.score;
    });
    entry.boundaryDetails = matches.slice(0, 4);
    entry.boundaryLabels = entry.boundaryDetails.map(function (item) {
        return item.label;
    });
    entry.primaryBoundary = entry.boundaryLabels[0] || '';
    var reasons = [];
    for (var i = 0; i < entry.boundaryDetails.length; i++) {
        for (var j = 0; j < entry.boundaryDetails[i].reasons.length; j++)
            reasons.push(
                entry.boundaryDetails[i].label + ': ' + entry.boundaryDetails[i].reasons[j],
            );
    }
    entry.boundaryReasons = uniqueStrings(reasons).slice(0, 8);
    return entry;
}

function inferBoundaryLabels(entry, isRuntime, assetMap) {
    var sample = buildBoundarySample(entry);
    var matches = [];
    var routeHints = entry.routeHints || [];
    var startupSignals = entry.startupSignals || [];
    if (
        (!isRuntime && entry.classification === 'runtime') ||
        /hydration|hydrateroot|reactdom\.hydrate|bootstrap|domcontentloaded|__webpack_require__|webpackchunk|parcelrequire|__vite__/.test(
            sample,
        ) ||
        arrayContainsAny(startupSignals, [
            'hydration',
            'chunk-loader',
            'service-worker-register',
            'worker-bootstrap',
            'wasm-bootstrap',
        ]) ||
        (isRuntime && /worker|service-worker/.test(String(entry.kind || '')))
    ) {
        pushBoundaryLabel(matches, 'bootstrap', 30, 'bootstraps the page or runtime loader');
    }
    if (
        routeHints.length ||
        /router|routes\b|history\.pushstate|next\/router|vue-router|react-router|createbrowserrouter|browserrouter|remix/.test(
            sample,
        )
    ) {
        pushBoundaryLabel(matches, 'router', 24, 'contains route or navigation signals');
    }
    if (
        /redux|zustand|mobx|recoil|vuex|pinia|createstore|configurestore|createslice|dispatch\(|subscribe\(|setstate\(/.test(
            sample,
        )
    ) {
        pushBoundaryLabel(matches, 'state', 24, 'contains state container signals');
    }
    if (
        /graphql|apollo|relay|axios|tanstack\/query|react-query|swr|trpc|fetch\(|xmlhttprequest|\/api\/|urql/.test(
            sample,
        ) ||
        arrayContainsAny(startupSignals, ['graphql-client'])
    ) {
        pushBoundaryLabel(matches, 'data', 24, 'contains data-fetching or API signals');
    }
    if (
        /auth0|next-auth|firebase\/auth|supabase\.auth|oauth|bearer|jwt|csrf|signin|signout|login|logout|session|tokenrefresh|clerk|okta|passport/.test(
            sample,
        )
    ) {
        pushBoundaryLabel(matches, 'auth', 24, 'contains authentication or session signals');
    }
    if (
        /gtag|google-analytics|googletagmanager|segment|mixpanel|amplitude|posthog|hotjar|fullstory|datadogrum|sentry|analytics\.track|fbq\(/.test(
            sample,
        )
    ) {
        pushBoundaryLabel(matches, 'analytics', 22, 'contains analytics or telemetry signals');
    }
    if (
        /monaco|codemirror|tiptap|prosemirror|quill|slate|draftjs|tinymce|ckeditor|editorjs|ace\.edit/.test(
            sample,
        )
    ) {
        pushBoundaryLabel(matches, 'editor', 24, 'contains editor/runtime authoring signals');
    }
    if (
        (!isRuntime &&
            (entry.classification === 'vendor' || entry.classification === 'framework')) ||
        /node_modules|chunk-vendors|polyfill|core-js|regenerator-runtime|cdn/.test(sample)
    ) {
        pushBoundaryLabel(matches, 'vendor', 20, 'looks like third-party or framework code');
    }
    if (isRuntime && entry.relatedChunks) {
        for (var i = 0; i < entry.relatedChunks.length; i++) {
            var related = assetMap[entry.relatedChunks[i]];
            if (
                related &&
                (related.classification === 'vendor' || related.classification === 'framework')
            ) {
                pushBoundaryLabel(matches, 'vendor', 16, 'spawned from a vendor/framework chunk');
                break;
            }
        }
    }
    return matches;
}

function buildBoundarySample(entry) {
    var parts = [
        entry.url || '',
        entry.file || '',
        entry.kind || '',
        entry.source || '',
        entry.originType || '',
        entry.classification || '',
        (entry.frameworkHints || []).join('\n'),
        (entry.routeHints || []).join('\n'),
        (entry.startupSignals || []).join('\n'),
        (entry.imports || []).join('\n'),
        entry.note || '',
        entry.mimeType || '',
        entry.stack || '',
    ];
    if (typeof entry.content === 'string') parts.push(entry.content.substring(0, 120000));
    if (typeof entry.text === 'string') parts.push(entry.text.substring(0, 120000));
    return parts.join('\n').toLowerCase();
}

function pushBoundaryLabel(matches, label, score, reason) {
    for (var i = 0; i < matches.length; i++) {
        if (matches[i].label === label) {
            matches[i].score += score;
            if (reason && matches[i].reasons.indexOf(reason) < 0) matches[i].reasons.push(reason);
            return;
        }
    }
    matches.push({ label: label, score: score, reasons: reason ? [reason] : [] });
}

function arrayContainsAny(values, candidates) {
    for (var i = 0; i < candidates.length; i++) if (values.indexOf(candidates[i]) >= 0) return true;
    return false;
}

function countBoundaryLabels(items) {
    var counts = {};
    for (var i = 0; i < items.length; i++) {
        var labels = items[i] && items[i].boundaryLabels ? items[i].boundaryLabels : [];
        for (var j = 0; j < labels.length; j++) counts[labels[j]] = (counts[labels[j]] || 0) + 1;
    }
    return counts;
}

function countTaggedEntries(items) {
    var count = 0;
    for (var i = 0; i < items.length; i++)
        if (items[i] && items[i].boundaryLabels && items[i].boundaryLabels.length) count++;
    return count;
}

function stripBoundaryEntry(entry, kind) {
    return {
        kind: kind,
        id: entry.id,
        label: getBareFileName(entry.file || entry.url || entry.id) || entry.id,
        file: entry.file || '',
        url: entry.url || entry.objectUrl || '',
        primaryBoundary: entry.primaryBoundary || '',
        boundaryLabels: entry.boundaryLabels || [],
        boundaryReasons: entry.boundaryReasons || [],
        classification: entry.classification || '',
        originType: entry.originType || '',
        score: entry.score || 0,
    };
}

function countPropertyValues(items, key) {
    var counts = {};
    for (var i = 0; i < items.length; i++) {
        var value = items[i] && items[i][key] ? items[i][key] : 'unknown';
        counts[value] = (counts[value] || 0) + 1;
    }
    return counts;
}

function uniqueStrings(values) {
    var out = [];
    var seen = {};
    for (var i = 0; i < values.length; i++) {
        var value = values[i];
        if (!value || seen[value]) continue;
        seen[value] = true;
        out.push(value);
    }
    return out;
}

function collectInterestingEntrypoints(assets, runtimeOrigins) {
    var items = [];
    for (var i = 0; i < assets.length; i++) {
        items.push({
            kind: 'chunk',
            id: assets[i].id,
            label: getBareFileName(assets[i].url) || assets[i].id,
            file: assets[i].file,
            url: assets[i].url,
            score: assets[i].score,
            classification: assets[i].classification,
            primaryBoundary: assets[i].primaryBoundary || '',
            boundaryLabels: assets[i].boundaryLabels || [],
            why: [
                assets[i].primaryBoundary,
                assets[i].classification,
                assets[i].bundler,
                assets[i].startupSignals.join(', '),
            ]
                .filter(Boolean)
                .join(' | '),
            startupSignals: assets[i].startupSignals,
            routeHints: assets[i].routeHints,
            frameworkHints: assets[i].frameworkHints,
        });
    }
    for (var j = 0; j < runtimeOrigins.length; j++) {
        items.push({
            kind: 'runtime',
            id: runtimeOrigins[j].id,
            label:
                getBareFileName(
                    runtimeOrigins[j].file || runtimeOrigins[j].url || runtimeOrigins[j].kind,
                ) || runtimeOrigins[j].id,
            file: runtimeOrigins[j].file || '',
            url: runtimeOrigins[j].url || runtimeOrigins[j].objectUrl || '',
            score: runtimeOrigins[j].score,
            originType: runtimeOrigins[j].originType,
            timestamp: runtimeOrigins[j].timestamp || 0,
            primaryBoundary: runtimeOrigins[j].primaryBoundary || '',
            boundaryLabels: runtimeOrigins[j].boundaryLabels || [],
            why: [
                runtimeOrigins[j].primaryBoundary,
                runtimeOrigins[j].kind,
                runtimeOrigins[j].originType,
                (runtimeOrigins[j].relatedChunks || []).join(', '),
            ]
                .filter(Boolean)
                .join(' | '),
            relatedChunks: runtimeOrigins[j].relatedChunks || [],
        });
    }
    items.sort(function (a, b) {
        return b.score !== a.score ? b.score - a.score : (a.timestamp || 0) - (b.timestamp || 0);
    });
    return items.slice(0, 14);
}

function buildInvestigationWorkspace(analysis) {
    var categories =
        analysis.boundaryLabels && analysis.boundaryLabels.categories
            ? analysis.boundaryLabels.categories
            : ['bootstrap', 'router', 'state', 'data', 'auth', 'analytics', 'editor', 'vendor'];
    var workspaces = [];
    for (var i = 0; i < categories.length; i++)
        workspaces.push(buildBoundaryWorkspace(categories[i], analysis));
    workspaces.push(buildFrameworkStateWorkspace(analysis, workspaces));
    var journeys = buildJourneyViews(analysis, workspaces);
    return {
        generatedAt: new Date().toISOString(),
        page:
            analysis.frameworkRuntime && analysis.frameworkRuntime.page
                ? analysis.frameworkRuntime.page
                : {},
        profile: {
            name: analysis.frameworkRuntime ? analysis.frameworkRuntime.profile : 'generic-app',
            confidence: analysis.frameworkRuntime ? analysis.frameworkRuntime.confidence : 0,
            technologies:
                analysis.frameworkRuntime && analysis.frameworkRuntime.technologies
                    ? analysis.frameworkRuntime.technologies
                    : [],
            traits:
                analysis.frameworkRuntime && analysis.frameworkRuntime.traits
                    ? analysis.frameworkRuntime.traits
                    : [],
            captureReason: analysis.frameworkRuntime ? analysis.frameworkRuntime.captureReason : '',
        },
        summary: {
            workspaceCount: workspaces.length,
            journeyCount: journeys.length,
            topBoundaryFlows: analysis.crossBoundaryFlows
                ? analysis.crossBoundaryFlows.topTransitions.slice(0, 10)
                : [],
            likelyEntrypoints: analysis.interestingEntrypoints.slice(0, 8),
            boundaryCounts: analysis.boundaryLabels ? analysis.boundaryLabels.summary : null,
        },
        workspaces: workspaces,
        journeys: journeys,
    };
}

function buildBoundaryWorkspace(boundary, analysis) {
    var chunks = analysis.chunkMap.items
        .filter(function (item) {
            return matchesBoundaryEntry(item, boundary);
        })
        .slice(0, 18);
    var runtime = analysis.runtimeOrigins.items
        .filter(function (item) {
            return matchesBoundaryEntry(item, boundary);
        })
        .slice(0, 18);
    var entrypoints = analysis.interestingEntrypoints
        .filter(function (item) {
            return matchesBoundaryEntry(item, boundary);
        })
        .slice(0, 10);
    var events = analysis.crossBoundaryFlows.events
        .filter(function (item) {
            return matchesBoundaryEntry(item, boundary);
        })
        .slice(0, 24);
    var transitions = analysis.crossBoundaryFlows.transitions
        .filter(function (item) {
            return flowTouchesBoundary(item, boundary);
        })
        .slice(0, 24);
    var topTransitions = analysis.crossBoundaryFlows.topTransitions
        .filter(function (item) {
            return item.fromBoundary === boundary || item.toBoundary === boundary;
        })
        .slice(0, 10);
    var chains = analysis.crossBoundaryFlows.chains
        .filter(function (item) {
            return chainTouchesBoundary(item, boundary);
        })
        .slice(0, 10);
    return {
        id: boundary,
        title: getBoundaryTitle(boundary),
        description: getBoundaryDescription(boundary),
        questions: getBoundaryQuestions(boundary),
        summary: {
            chunkCount: chunks.length,
            runtimeCount: runtime.length,
            entrypointCount: entrypoints.length,
            eventCount: events.length,
            transitionCount: transitions.length,
            chainCount: chains.length,
            totalItems: chunks.length + runtime.length + entrypoints.length,
        },
        entrypoints: entrypoints,
        chunks: chunks,
        runtime: runtime,
        events: events,
        transitions: transitions,
        topTransitions: topTransitions,
        chains: chains,
        relatedArtifacts: [
            '_analysis/boundary-labels.json',
            '_analysis/cross-boundary-flows.json',
            '_analysis/interesting-entrypoints.json',
        ],
    };
}

function buildFrameworkStateWorkspace(analysis, existingWorkspaces) {
    var frameworkState = analysis.frameworkState || {};
    var boundaries = ['bootstrap', 'router', 'state', 'data', 'auth'];
    var chunks = analysis.chunkMap.items
        .filter(function (item) {
            return matchesAnyBoundary(item, boundaries);
        })
        .slice(0, 18);
    var runtime = analysis.runtimeOrigins.items
        .filter(function (item) {
            return matchesAnyBoundary(item, boundaries);
        })
        .slice(0, 18);
    var entrypoints = analysis.interestingEntrypoints
        .filter(function (item) {
            return matchesAnyBoundary(item, boundaries);
        })
        .slice(0, 12);
    var transitions = analysis.crossBoundaryFlows.transitions
        .filter(function (item) {
            return flowTouchesAnyBoundary(item, boundaries);
        })
        .slice(0, 24);
    var chains = analysis.crossBoundaryFlows.chains
        .filter(function (item) {
            return chainTouchesAnyBoundary(item, boundaries);
        })
        .slice(0, 10);
    var events = buildFrameworkStateEvents(frameworkState);
    var supportingWorkspaces = [];
    for (var i = 0; i < existingWorkspaces.length; i++) {
        if (
            arrayContainsAny(
                ['bootstrap', 'router', 'state', 'data', 'auth'],
                [existingWorkspaces[i].id],
            )
        )
            supportingWorkspaces.push(existingWorkspaces[i]);
    }
    return {
        id: 'framework-state',
        title: 'Framework State workspace',
        description:
            'Summarize the inspected framework state across router, stores, query caches, hydration payloads, auth state, and detected framework roots.',
        focusBoundaries: boundaries,
        questions: [
            'Which router state is active and where did it come from?',
            'Which stores, caches, and hydration payloads are present?',
            'What auth/session state is exposed?',
            'Which supporting workspaces explain the observed framework state?',
        ],
        summary: {
            chunkCount: chunks.length,
            runtimeCount: runtime.length,
            entrypointCount: entrypoints.length,
            eventCount: events.length,
            transitionCount: transitions.length,
            chainCount: chains.length,
            totalItems: chunks.length + runtime.length + entrypoints.length,
            rootCount: frameworkState.rootCount || 0,
            storeCount: frameworkState.storeCount || 0,
            queryCount: frameworkState.queryCount || 0,
            hydrationCount: frameworkState.hydrationCount || 0,
            authCount: frameworkState.authCount || 0,
            routerFramework: frameworkState.routerFramework || 'generic',
            route: frameworkState.route || '',
        },
        entrypoints: entrypoints,
        chunks: chunks,
        runtime: runtime,
        events: events,
        transitions: transitions,
        topTransitions: analysis.crossBoundaryFlows.topTransitions
            .filter(function (item) {
                return arrayContainsAny([item.fromBoundary, item.toBoundary], boundaries);
            })
            .slice(0, 10),
        chains: chains,
        supportingWorkspaces: supportingWorkspaces,
        relatedArtifacts: frameworkState.relatedArtifacts || [],
    };
}

function buildFrameworkStateEvents(frameworkState) {
    if (!frameworkState) return [];
    var events = [];
    if (frameworkState.route || frameworkState.routerFramework) {
        events.push({
            id: 'framework-router',
            kind: 'router-state',
            boundary: 'router',
            label: (frameworkState.routerFramework || 'generic') + ' router',
            detail: frameworkState.route || '',
            score: frameworkState.queryKeyCount || 0,
        });
    }
    pushFrameworkCollectionEvents(
        events,
        frameworkState.roots,
        'framework-root',
        'bootstrap',
        'root',
    );
    pushFrameworkCollectionEvents(
        events,
        frameworkState.stores,
        'store-snapshot',
        'state',
        'store',
    );
    pushFrameworkCollectionEvents(events, frameworkState.queries, 'query-cache', 'data', 'query');
    pushFrameworkCollectionEvents(
        events,
        frameworkState.hydration,
        'hydration-payload',
        'bootstrap',
        'hydration',
    );
    pushFrameworkCollectionEvents(events, frameworkState.auth, 'auth-state', 'auth', 'auth');
    return events.slice(0, 24);
}

function pushFrameworkCollectionEvents(target, items, kind, boundary, fallbackLabel) {
    items = items || [];
    for (var i = 0; i < items.length && target.length < 24; i++) {
        var item = items[i] || {};
        target.push({
            id: kind + '-' + (i + 1),
            kind: kind,
            boundary: boundary,
            label: item.id || item.kind || item.tag || fallbackLabel,
            detail: item.source || item.route || item.status || '',
            score: item.keyCount || item.queryCount || item.childCount || 0,
        });
    }
}

function matchesBoundaryEntry(entry, boundary) {
    if (!entry) return false;
    if (entry.primaryBoundary === boundary) return true;
    var labels = entry.boundaryLabels || [];
    return labels.indexOf(boundary) >= 0;
}

function flowTouchesBoundary(flow, boundary) {
    return (
        !!flow &&
        (flow.fromBoundary === boundary ||
            flow.toBoundary === boundary ||
            matchesBoundaryEntry(flow.from, boundary) ||
            matchesBoundaryEntry(flow.to, boundary))
    );
}

function chainTouchesBoundary(chain, boundary) {
    return !!chain && chain.path && chain.path.indexOf(boundary) >= 0;
}

function flowTouchesAnyBoundary(flow, boundaries) {
    if (!flow) return false;
    for (var i = 0; i < boundaries.length; i++)
        if (flowTouchesBoundary(flow, boundaries[i])) return true;
    return false;
}

function chainTouchesAnyBoundary(chain, boundaries) {
    if (!chain) return false;
    for (var i = 0; i < boundaries.length; i++)
        if (chainTouchesBoundary(chain, boundaries[i])) return true;
    return false;
}

function getBoundaryTitle(boundary) {
    var titles = {
        bootstrap: 'Bootstrap workspace',
        router: 'Router workspace',
        state: 'State workspace',
        data: 'Data workspace',
        auth: 'Auth workspace',
        analytics: 'Analytics workspace',
        editor: 'Editor workspace',
        vendor: 'Vendor workspace',
    };
    return titles[boundary] || boundary + ' workspace';
}

function getBoundaryDescription(boundary) {
    var descriptions = {
        bootstrap:
            'Focus on initial loaders, hydration code, runtime bootstraps, and early execution pivots.',
        router: 'Focus on navigation, route loaders, route-linked chunks, and follow-on route activity.',
        state: 'Focus on stores, persistence, rehydration, and state-driven transitions into other subsystems.',
        data: 'Focus on API clients, GraphQL, fetch/XHR activity, and data-triggered runtime behavior.',
        auth: 'Focus on session setup, token handling, login/logout paths, and downstream auth-driven requests.',
        analytics:
            'Focus on telemetry, tracking beacons, pageview/reporting paths, and analytics fan-out.',
        editor: 'Focus on rich-text/editor runtimes, content workflows, and document mutation paths.',
        vendor: 'Focus on third-party/framework code that spawns runtime artifacts or crosses into business logic.',
    };
    return descriptions[boundary] || 'Focus on artifacts labeled for this subsystem.';
}

function getBoundaryQuestions(boundary) {
    var questions = {
        bootstrap: [
            'What actually starts the application?',
            'Which chunks materialize runtime artifacts first?',
            'Where does bootstrap hand off to router, state, or data code?',
        ],
        router: [
            'Which chunks own navigation?',
            'What route-linked requests or runtime artifacts follow router activity?',
            'Which entrypoints look route-specific?',
        ],
        state: [
            'Which stores or persistence seams are present?',
            'Does state drive data fetches or router changes?',
            'Which runtime artifacts look state-derived?',
        ],
        data: [
            'Which requests look like the primary API layer?',
            'Which chunks and runtimes trigger requests?',
            'Are GraphQL or other data clients obvious?',
        ],
        auth: [
            'Where is session or token handling initialized?',
            'Which requests belong to login/session refresh?',
            'What does auth trigger next: data, router, or analytics?',
        ],
        analytics: [
            'Which beacons or SDK seams are present?',
            'What subsystem activity feeds analytics?',
            'Which chunks likely own telemetry wiring?',
        ],
        editor: [
            'Which assets or runtimes look content- or editor-related?',
            'What runtime materialization follows editor activity?',
            'Does editor activity lead into state or data flows?',
        ],
        vendor: [
            'Which third-party bundles are most influential?',
            'Which runtime artifacts come from vendor/framework code?',
            'Where does vendor code cross into app subsystems?',
        ],
    };
    return (
        questions[boundary] || [
            'Which artifacts belong here?',
            'Which flows enter or leave this boundary?',
        ]
    );
}

function buildJourneyViews(analysis, workspaces) {
    var workspaceMap = {};
    for (var i = 0; i < workspaces.length; i++) workspaceMap[workspaces[i].id] = workspaces[i];
    return [
        buildJourneyView(
            'initial-load',
            'Initial load',
            'Trace how bootstrap code, runtime materialization, routing, and data startup fit together during first load.',
            analysis,
            workspaceMap,
            ['bootstrap', 'router', 'data', 'state'],
            function (flow) {
                return (
                    flow.fromBoundary === 'bootstrap' ||
                    flow.toBoundary === 'bootstrap' ||
                    flow.relation === 'imports-boundary' ||
                    flow.relation === 'materializes-runtime'
                );
            },
        ),
        buildJourneyView(
            'auth-handshake',
            'Auth handshake',
            'Slice the session/auth path and its downstream transitions into data, router, and analytics.',
            analysis,
            workspaceMap,
            ['auth', 'data', 'router', 'analytics'],
            function (flow) {
                return flowTouchesBoundary(flow, 'auth');
            },
        ),
        buildJourneyView(
            'route-change',
            'Route change',
            'Slice the navigation path through router, data, state, and analytics activity.',
            analysis,
            workspaceMap,
            ['router', 'data', 'state', 'analytics'],
            function (flow) {
                return flowTouchesBoundary(flow, 'router');
            },
        ),
        buildJourneyView(
            'runtime-materialization',
            'Runtime materialization',
            'Show which chunks create runtime artifacts and how those artifacts lead into requests or more runtime generation.',
            analysis,
            workspaceMap,
            ['bootstrap', 'vendor', 'data'],
            function (flow) {
                return (
                    flow.relation === 'materializes-runtime' ||
                    flow.relation === 'spawns-runtime' ||
                    flow.from.kind === 'runtime' ||
                    flow.to.kind === 'runtime'
                );
            },
        ),
    ];
}

function buildJourneyView(
    id,
    title,
    description,
    analysis,
    workspaceMap,
    focusBoundaries,
    transitionFilter,
) {
    var transitions = analysis.crossBoundaryFlows.transitions
        .filter(function (flow) {
            return (
                transitionFilter(flow) ||
                arrayTouchesAny(
                    flow.fromBoundary ? [flow.fromBoundary, flow.toBoundary] : [],
                    focusBoundaries,
                )
            );
        })
        .slice(0, 26);
    var events = analysis.crossBoundaryFlows.events
        .filter(function (event) {
            return matchesAnyBoundary(event, focusBoundaries);
        })
        .slice(0, 28);
    var entrypoints = analysis.interestingEntrypoints
        .filter(function (entry) {
            return matchesAnyBoundary(entry, focusBoundaries);
        })
        .slice(0, 10);
    var chains = analysis.crossBoundaryFlows.chains
        .filter(function (chain) {
            return chainPathTouchesAny(chain, focusBoundaries);
        })
        .slice(0, 10);
    var supportingWorkspaces = [];
    for (var i = 0; i < focusBoundaries.length; i++) {
        var workspace = workspaceMap[focusBoundaries[i]];
        if (!workspace) continue;
        supportingWorkspaces.push({
            id: workspace.id,
            title: workspace.title,
            summary: workspace.summary,
            entrypoints: workspace.entrypoints.slice(0, 3),
        });
    }
    return {
        id: id,
        title: title,
        description: description,
        focusBoundaries: focusBoundaries,
        summary: {
            eventCount: events.length,
            transitionCount: transitions.length,
            chainCount: chains.length,
            entrypointCount: entrypoints.length,
        },
        questions: getJourneyQuestions(id),
        entrypoints: entrypoints,
        events: events,
        transitions: transitions,
        chains: chains,
        supportingWorkspaces: supportingWorkspaces,
        relatedArtifacts: [
            '_analysis/cross-boundary-flows.json',
            '_analysis/startup-chain.json',
            '_analysis/runtime-origins.json',
        ],
    };
}

function matchesAnyBoundary(entry, boundaries) {
    for (var i = 0; i < boundaries.length; i++)
        if (matchesBoundaryEntry(entry, boundaries[i])) return true;
    return false;
}

function arrayTouchesAny(values, candidates) {
    for (var i = 0; i < values.length; i++) {
        if (!values[i]) continue;
        for (var j = 0; j < candidates.length; j++) if (values[i] === candidates[j]) return true;
    }
    return false;
}

function chainPathTouchesAny(chain, boundaries) {
    if (!chain || !chain.path) return false;
    return arrayTouchesAny(chain.path, boundaries);
}

function getJourneyQuestions(id) {
    var questions = {
        'initial-load': [
            'Which chunk booted first?',
            'What runtime artifacts were materialized during startup?',
            'Which early transitions led into data or router activity?',
        ],
        'auth-handshake': [
            'Which assets and requests carry auth signals?',
            'Does auth lead into data, router, or analytics behavior?',
            'Which runtime artifacts appear around session setup?',
        ],
        'route-change': [
            'Which chunks and requests cluster around navigation?',
            'Does route activity trigger data fetches or analytics?',
            'Which runtime artifacts appear after router activity?',
        ],
        'runtime-materialization': [
            'Which chunks created runtime artifacts?',
            'Which runtime artifacts spawn other runtimes?',
            'What requests or boundary transitions follow runtime generation?',
        ],
    };
    return (
        questions[id] || [
            'What does this slice show first?',
            'Which transitions deserve inspection?',
        ]
    );
}

/*
function generateInvestigationIndexHTML(investigation) {
    var page = investigation && investigation.page ? investigation.page : {};
    var title = page.title || page.url || 'Investigation Console';
    var data = serializeInlineJson(investigation || {});
    return '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width, initial-scale=1.0">\n<title>Investigation Console</title>\n<style>\n' +
        '*{box-sizing:border-box}body{margin:0;font-family:Inter,Segoe UI,Arial,sans-serif;background:#0b1020;color:#e6ebff}a{color:#8ec5ff}button{font:inherit}code{font-family:Consolas,monospace}.shell{display:grid;grid-template-columns:280px 1fr;min-height:100vh}.sidebar{padding:20px;border-right:1px solid rgba(255,255,255,.08);background:#111833}.main{padding:24px}.title{font-size:20px;font-weight:700;margin:0 0 6px}.sub{color:#95a3d7;font-size:12px;line-height:1.5;margin-bottom:18px}.section-title{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#7f8cc9;margin:18px 0 10px}.nav{display:flex;flex-wrap:wrap;gap:8px}.nav button{width:100%;text-align:left;padding:10px 12px;border-radius:10px;border:1px solid rgba(255,255,255,.08);background:#18224a;color:#dfe7ff;cursor:pointer}.nav button.active{background:#24408a;border-color:#6ea8ff}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin:18px 0}.card{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:12px}.card .label{font-size:11px;color:#91a0d4;text-transform:uppercase;letter-spacing:.08em}.card .value{font-size:22px;font-weight:700;margin-top:4px}.panel{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:16px;margin-top:16px}.panel h2{margin:0 0 6px;font-size:18px}.panel p{margin:0 0 12px;color:#b7c2ea;line-height:1.5}.list{display:grid;gap:10px}.item{padding:12px;border-radius:10px;background:#0f1530;border:1px solid rgba(255,255,255,.06)}.item h3{margin:0 0 4px;font-size:14px}.item .meta{font-size:12px;color:#90a0d6;line-height:1.5}.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}.chip{padding:3px 8px;border-radius:999px;background:#243462;color:#dbe6ff;font-size:11px}.empty{color:#7f8cc9;font-size:13px;padding:14px;border:1px dashed rgba(255,255,255,.14);border-radius:10px}.kvs{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}.kv{background:#0f1530;border-radius:10px;padding:10px}.kv .k{font-size:11px;color:#8ea0d8;text-transform:uppercase}.kv .v{font-size:16px;font-weight:700;margin-top:4px}.links{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}.links a{font-size:12px;padding:6px 10px;border-radius:999px;background:#22315e;text-decoration:none}.questions{margin:0;padding-left:18px;color:#c8d2f7}.questions li{margin:6px 0}.mono{font-family:Consolas,monospace;word-break:break-word}@media (max-width:900px){.shell{grid-template-columns:1fr}.sidebar{border-right:none;border-bottom:1px solid rgba(255,255,255,.08)}}\n' +
        '</style>\n</head>\n<body>\n<div class="shell">\n<aside class="sidebar">\n<h1 class="title">Investigation Console</h1>\n<div class="sub">' + escapeXml(title) + '<br>' + escapeXml(page.url || '') + '</div>\n<div class="section-title">Workspaces</div><div id="workspaceNav" class="nav"></div>\n<div class="section-title">Journeys</div><div id="journeyNav" class="nav"></div>\n</aside>\n<main class="main">\n<div id="summaryCards" class="cards"></div>\n<div id="view"></div>\n</main>\n</div>\n<script id="investigation-data" type="application/json">' + data + '</script>\n<script>\n(function(){\nvar data=JSON.parse(document.getElementById("investigation-data").textContent||"{}");\nvar workspaceNav=document.getElementById("workspaceNav");\nvar journeyNav=document.getElementById("journeyNav");\nvar view=document.getElementById("view");\nvar summaryCards=document.getElementById("summaryCards");\nvar state={type:"workspace",id:data.workspaces&&data.workspaces.length?data.workspaces[0].id:(data.journeys&&data.journeys.length?data.journeys[0].id:"")};\nfunction esc(v){return String(v==null?"":v).replace(/[&<>\"']/g,function(ch){return({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"})[ch]})}\nfunction pathHref(path){if(!path)return"";if(path.indexOf("_analysis/")===0)return path.replace(/^_analysis\//,"");return"../"+path.replace(/^\/+/,"")}\nfunction renderNav(){workspaceNav.innerHTML=(data.workspaces||[]).map(function(item){return '<button data-type="workspace" data-id="'+esc(item.id)+'" class="'+(state.type==="workspace"&&state.id===item.id?"active":"")+'">'+esc(item.title)+'</button>'}).join("");journeyNav.innerHTML=(data.journeys||[]).map(function(item){return '<button data-type="journey" data-id="'+esc(item.id)+'" class="'+(state.type==="journey"&&state.id===item.id?"active":"")+'">'+esc(item.title)+'</button>'}).join("");Array.prototype.forEach.call(document.querySelectorAll(".nav button"),function(btn){btn.onclick=function(){state.type=btn.getAttribute("data-type");state.id=btn.getAttribute("data-id");render();};});}\nfunction renderCards(){var summary=data.summary||{};var cards=[{label:"Workspaces",value:summary.workspaceCount||0},{label:"Journeys",value:summary.journeyCount||0},{label:"Top flows",value:(summary.topBoundaryFlows||[]).length},{label:"Entrypoints",value:(summary.likelyEntrypoints||[]).length}];summaryCards.innerHTML=cards.map(function(card){return '<div class="card"><div class="label">'+esc(card.label)+'</div><div class="value">'+esc(card.value)+'</div></div>';}).join("");}\nfunction renderList(items, kind){if(!items||!items.length)return '<div class="empty">No '+kind+' in this slice.</div>';return '<div class="list">'+items.map(function(item){var chips=(item.boundaryLabels||item.focusBoundaries||[]).map(function(v){return '<span class="chip">'+esc(v)+'</span>';}).join("");var meta=[];if(item.label)meta.push(item.label);if(item.file)meta.push(item.file);if(item.url)meta.push(item.url);if(item.relation)meta.push(item.relation);if(item.evidence)meta.push(item.evidence);if(item.why)meta.push(item.why);return '<div class="item"><h3>'+esc(item.title||item.id||item.label||kind)+'</h3><div class="meta mono">'+meta.map(esc).join('<br>')+'</div>'+(chips?'<div class="chips">'+chips+'</div>':'')+'</div>';}).join("")+'</div>'; }\nfunction renderQuestions(items){if(!items||!items.length)return '<div class="empty">No guide questions for this slice.</div>';return '<ul class="questions">'+items.map(function(q){return '<li>'+esc(q)+'</li>';}).join("")+'</ul>'; }\nfunction renderLinks(paths){if(!paths||!paths.length)return '';return '<div class="links">'+paths.map(function(path){return '<a href="'+esc(pathHref(path))+'" target="_blank" rel="noopener">'+esc(path)+'</a>';}).join("")+'</div>'; }\nfunction renderSummary(summary){if(!summary)return '';var keys=Object.keys(summary);if(!keys.length)return '';return '<div class="kvs">'+keys.map(function(key){return '<div class="kv"><div class="k">'+esc(key)+'</div><div class="v">'+esc(summary[key])+'</div></div>';}).join('')+'</div>'; }\nfunction getCurrent(){var items=state.type==="journey"?(data.journeys||[]):(data.workspaces||[]);for(var i=0;i<items.length;i++)if(items[i].id===state.id)return items[i];return items[0]||null;}\nfunction render(){renderNav();renderCards();var current=getCurrent();if(!current){view.innerHTML='<div class="panel"><div class="empty">No investigation slices available.</div></div>';return;}view.innerHTML='<section class="panel"><h2>'+esc(current.title)+'</h2><p>'+esc(current.description||'')+'</p>'+renderSummary(current.summary)+renderLinks(current.relatedArtifacts)+'</section><section class="panel"><h2>Questions</h2>'+renderQuestions(current.questions)+'</section><section class="panel"><h2>Entrypoints</h2>'+renderList(current.entrypoints,"entrypoints")+'</section><section class="panel"><h2>Transitions</h2>'+renderList(current.transitions||current.topTransitions,"transitions")+'</section><section class="panel"><h2>Runtime and chunks</h2>'+renderList((current.runtime||[]).concat(current.chunks||[]),"artifacts")+'</section><section class="panel"><h2>Events and chains</h2>'+renderList((current.events||[]).concat(current.chains||[]),"events")+'</section><section class="panel"><h2>Supporting workspaces</h2>'+renderList(current.supportingWorkspaces,"supporting workspaces")+'</section>'; }\nrender();\n})();\n</script>\n</body>\n</html>';
}
*/
function generateInvestigationIndexHTML(investigation) {
    var page = investigation && investigation.page ? investigation.page : {};
    var title = page.title || page.url || 'Investigation Console';
    var data = serializeInlineJson(investigation || {});
    var styles = [
        '*{box-sizing:border-box}',
        'body{margin:0;font-family:Inter,Segoe UI,Arial,sans-serif;background:#0b1020;color:#e6ebff}',
        'a{color:#8ec5ff}',
        'button{font:inherit}',
        'code{font-family:Consolas,monospace}',
        '.shell{display:grid;grid-template-columns:280px 1fr;min-height:100vh}',
        '.sidebar{padding:20px;border-right:1px solid rgba(255,255,255,.08);background:#111833}',
        '.main{padding:24px}',
        '.title{font-size:20px;font-weight:700;margin:0 0 6px}',
        '.sub{color:#95a3d7;font-size:12px;line-height:1.5;margin-bottom:18px}',
        '.section-title{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#7f8cc9;margin:18px 0 10px}',
        '.nav{display:flex;flex-wrap:wrap;gap:8px}',
        '.nav button{width:100%;text-align:left;padding:10px 12px;border-radius:10px;border:1px solid rgba(255,255,255,.08);background:#18224a;color:#dfe7ff;cursor:pointer}',
        '.nav button.active{background:#24408a;border-color:#6ea8ff}',
        '.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin:18px 0}',
        '.card{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:12px}',
        '.card .label{font-size:11px;color:#91a0d4;text-transform:uppercase;letter-spacing:.08em}',
        '.card .value{font-size:22px;font-weight:700;margin-top:4px}',
        '.panel{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:16px;margin-top:16px}',
        '.panel h2{margin:0 0 6px;font-size:18px}',
        '.panel p{margin:0 0 12px;color:#b7c2ea;line-height:1.5}',
        '.list{display:grid;gap:10px}',
        '.item{padding:12px;border-radius:10px;background:#0f1530;border:1px solid rgba(255,255,255,.06)}',
        '.item h3{margin:0 0 4px;font-size:14px}',
        '.item .meta{font-size:12px;color:#90a0d6;line-height:1.5}',
        '.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}',
        '.chip{padding:3px 8px;border-radius:999px;background:#243462;color:#dbe6ff;font-size:11px}',
        '.empty{color:#7f8cc9;font-size:13px;padding:14px;border:1px dashed rgba(255,255,255,.14);border-radius:10px}',
        '.kvs{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}',
        '.kv{background:#0f1530;border:1px solid rgba(255,255,255,.06);border-radius:10px;padding:10px}',
        '.kv .k{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:#7f8cc9}',
        '.kv .v{margin-top:4px;font-size:14px;font-weight:600}',
        '.path{font-size:12px;color:#9fb0e9}',
        '.split{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;align-items:start}',
        '.mono{font-family:Consolas,monospace}',
        '.muted{color:#8e9cd2}',
        '.links{display:flex;flex-wrap:wrap;gap:8px}',
        '.links a{display:inline-flex;padding:8px 10px;border-radius:10px;background:#18224a;text-decoration:none}',
        '.hero{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;flex-wrap:wrap}',
        '.hero .meta{max-width:820px}',
        '.hero .badge{display:inline-flex;padding:6px 10px;border-radius:999px;background:#203a77;font-size:12px;color:#e6ebff;margin-bottom:10px}',
        '@media (max-width:900px){.shell{grid-template-columns:1fr}.sidebar{border-right:0;border-bottom:1px solid rgba(255,255,255,.08)}}',
    ].join('');
    var script = [
        '(function(){',
        'var data=JSON.parse(document.getElementById("investigation-data").textContent||"{}");',
        'var workspaceNav=document.getElementById("workspaceNav");',
        'var journeyNav=document.getElementById("journeyNav");',
        'var view=document.getElementById("view");',
        'var summaryCards=document.getElementById("summaryCards");',
        'var workspaces=data.workspaces||[];',
        'var journeys=data.journeys||[];',
        'var state={type:"workspace",id:workspaces.length?workspaces[0].id:(journeys.length?journeys[0].id:"")};',
        'function esc(value){return String(value==null?"":value).replace(/[&<>"\']/g,function(ch){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","\'":"&#39;"}[ch]})}',
        'function pathHref(path){if(!path)return"";if(path.indexOf("_analysis/")===0)return path.replace(/^_analysis\//,"");return"../"+path.replace(/^\/+/,"")}',
        'function toTitle(key){return String(key||"").replace(/([A-Z])/g," $1").replace(/^./,function(ch){return ch.toUpperCase()})}',
        'function card(label,value){return "<div class=\"card\"><div class=\"label\">"+esc(label)+"</div><div class=\"value\">"+esc(value)+"</div></div>"}',
        'function panel(title,body,description){return "<section class=\"panel\"><h2>"+esc(title)+"</h2>"+(description?"<p>"+esc(description)+"</p>":"")+body+"</section>"}',
        'function list(items,renderItem,emptyText){if(!items||!items.length)return "<div class=\"empty\">"+esc(emptyText)+"</div>";return "<div class=\"list\">"+items.map(renderItem).join("")+"</div>"}',
        'function chips(items){if(!items||!items.length)return"";return "<div class=\"chips\">"+items.map(function(item){return "<span class=\"chip\">"+esc(item)+"</span>"}).join("")+"</div>"}',
        'function kvs(summary){var rows=[];for(var key in summary){if(Object.prototype.hasOwnProperty.call(summary,key))rows.push("<div class=\"kv\"><div class=\"k\">"+esc(toTitle(key))+"</div><div class=\"v\">"+esc(summary[key])+"</div></div>")}return rows.length?"<div class=\"kvs\">"+rows.join("")+"</div>":"<div class=\"empty\">No summary metrics available.</div>"}',
        'function entryMeta(item){var parts=[];if(item.kind)parts.push(item.kind);if(item.classification)parts.push(item.classification);if(item.originType)parts.push(item.originType);if(item.primaryBoundary)parts.push(item.primaryBoundary);if(item.score!=null)parts.push("score "+item.score);return parts.join(" | ")}',
        'function renderEntrypoint(item){return "<div class=\"item\"><h3>"+esc(item.label||item.id||"Entrypoint")+"</h3><div class=\"meta\">"+esc(entryMeta(item))+"</div><div class=\"path mono\">"+esc(item.url||item.file||"")+"</div>"+chips(item.boundaryLabels||[])+"</div>"}',
        'function renderChunk(item){var meta=[item.classification||"",item.bundler||"",item.transferSize?item.transferSize+" bytes":""].filter(Boolean).join(" | ");return "<div class=\"item\"><h3>"+esc(item.id||item.file||"Chunk")+"</h3><div class=\"meta\">"+esc(meta)+"</div><div class=\"path mono\">"+esc(item.url||item.file||"")+"</div>"+chips((item.frameworkHints||[]).concat(item.boundaryLabels||[]).slice(0,8))+"</div>"}',
        'function renderRuntime(item){var meta=[item.kind||"",item.originType||"",item.size?item.size+" bytes":""].filter(Boolean).join(" | ");return "<div class=\"item\"><h3>"+esc(item.id||item.file||"Runtime artifact")+"</h3><div class=\"meta\">"+esc(meta)+"</div><div class=\"path mono\">"+esc(item.file||item.url||item.objectUrl||"")+"</div>"+chips((item.relatedChunks||[]).slice(0,6))+"</div>"}',
        'function renderTransition(item){var from=(item.from&&item.from.label)||(item.from&&item.from.id)||item.fromBoundary||"Unknown";var to=(item.to&&item.to.label)||(item.to&&item.to.id)||item.toBoundary||"Unknown";var meta=[item.relation||"",item.fromBoundary||"",item.toBoundary||""].filter(Boolean).join(" | ");return "<div class=\"item\"><h3>"+esc(from)+" -> "+esc(to)+"</h3><div class=\"meta\">"+esc(meta)+"</div></div>"}',
        'function renderEvent(item){var meta=[item.kind||item.type||"",item.boundary||item.primaryBoundary||"",item.score!=null?"score "+item.score:""] .filter(Boolean).join(" | ");return "<div class=\"item\"><h3>"+esc(item.label||item.id||item.type||"Event")+"</h3><div class=\"meta\">"+esc(meta)+"</div><div class=\"path mono\">"+esc(item.url||item.file||item.detail||"")+"</div></div>"}',
        'function renderChain(item){return "<div class=\"item\"><h3>"+esc(item.label||item.id||"Chain")+"</h3><div class=\"meta\">"+esc(item.description||"")+"</div>"+chips(item.path||[])+"</div>"}',
        'function renderQuestion(item){return "<div class=\"item\"><h3>"+esc(item)+"</h3></div>"}',
        'function renderArtifact(item){var href=pathHref(item);return "<a href=\""+esc(href)+"\" target=\"_blank\" rel=\"noopener noreferrer\">"+esc(item)+"</a>"}',
        'function renderSupportingWorkspace(item){var body=kvs(item.summary||{});body+=panel("Sample entrypoints",list(item.entrypoints||[],renderEntrypoint,"No supporting entrypoints."),"");return "<div class=\"item\"><h3>"+esc(item.title||item.id||"Workspace")+"</h3>"+body+"</div>"}',
        'function renderSummary(current){var summary=current.summary||{};return [card(state.type==="workspace"?"Workspace items":"Journey entrypoints",summary.totalItems||summary.entrypointCount||0),card("Transitions",summary.transitionCount||0),card("Events",summary.eventCount||0),card("Runtime",summary.runtimeCount||0),card("Chunks",summary.chunkCount||0),card("Chains",summary.chainCount||0)].join("")}',
        'function findCurrent(){if(state.type==="journey"){for(var i=0;i<journeys.length;i++)if(journeys[i].id===state.id)return journeys[i];return journeys[0]||null}for(var j=0;j<workspaces.length;j++)if(workspaces[j].id===state.id)return workspaces[j];return workspaces[0]||journeys[0]||null}',
        'function renderNav(){workspaceNav.innerHTML=workspaces.map(function(item){return "<button data-type=\"workspace\" data-id=\""+esc(item.id)+"\" class=\""+(state.type==="workspace"&&state.id===item.id?"active":"")+"\">"+esc(item.title)+"</button>"}).join("");journeyNav.innerHTML=journeys.map(function(item){return "<button data-type=\"journey\" data-id=\""+esc(item.id)+"\" class=\""+(state.type==="journey"&&state.id===item.id?"active":"")+"\">"+esc(item.title)+"</button>"}).join("");Array.prototype.forEach.call(document.querySelectorAll(".nav button"),function(btn){btn.onclick=function(){state.type=btn.getAttribute("data-type");state.id=btn.getAttribute("data-id");render()}})}',
        'function renderCurrent(current){var relatedArtifacts=current.relatedArtifacts||[];var supportingWorkspaces=current.supportingWorkspaces||[];var html="";html+=panel(current.title||current.id||"Investigation slice","<div class=\"hero\"><div class=\"meta\"><div class=\"badge\">"+esc(state.type)+"</div><p>"+esc(current.description||"No description available.")+"</p>"+chips(current.focusBoundaries||[])+"</div><div class=\"meta\"><div class=\"muted\">Generated</div><div class=\"mono\">"+esc(data.generatedAt||"")+"</div></div></div>","");html+=panel("Summary",kvs(current.summary||{}),"");html+=panel("Questions",list(current.questions||[],renderQuestion,"No questions recorded."),"");html+="<div class=\"split\">"+panel("Entrypoints",list(current.entrypoints||[],renderEntrypoint,"No entrypoints recorded."),"")+panel("Transitions",list(current.transitions||[],renderTransition,"No transitions recorded."),"")+"</div>";html+="<div class=\"split\">"+panel("Chunks",list(current.chunks||[],renderChunk,"No chunks recorded."),"")+panel("Runtime artifacts",list(current.runtime||[],renderRuntime,"No runtime artifacts recorded."),"")+"</div>";html+="<div class=\"split\">"+panel("Events",list(current.events||[],renderEvent,"No events recorded."),"")+panel("Chains",list(current.chains||[],renderChain,"No chains recorded."),"")+"</div>";if(supportingWorkspaces.length)html+=panel("Supporting workspaces",list(supportingWorkspaces,renderSupportingWorkspace,"No supporting workspaces recorded."),"");if(relatedArtifacts.length)html+=panel("Related artifacts","<div class=\"links\">"+relatedArtifacts.map(renderArtifact).join("")+"</div>","");return html}',
        'function render(){var current=findCurrent();renderNav();if(!current){summaryCards.innerHTML="";view.innerHTML="<section class=\"panel\"><div class=\"empty\">No investigation slice available.</div></section>";return}summaryCards.innerHTML=renderSummary(current);view.innerHTML=renderCurrent(current)}',
        'render();',
        '})();',
    ].join('\n');
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Investigation Console</title>
<style>${styles}</style>
</head>
<body>
<div class="shell">
<aside class="sidebar">
<h1 class="title">Investigation Console</h1>
<div class="sub">${escapeXml(title)}<br>${escapeXml(page.url || '')}</div>
<div class="section-title">Workspaces</div><div id="workspaceNav" class="nav"></div>
<div class="section-title">Journeys</div><div id="journeyNav" class="nav"></div>
</aside>
<main class="main">
<div id="summaryCards" class="cards"></div>
<div id="view"></div>
</main>
</div>
<script id="investigation-data" type="application/json">${data}</script>
<script>${script}</script>
</body>
</html>`;
}

function serializeInlineJson(value) {
    return JSON.stringify(value || {})
        .replace(/</g, '\\u003c')
        .replace(/>/g, '\\u003e')
        .replace(/&/g, '\\u0026');
}

function exportReadableArtifacts(zip, analysis) {
    var assetMap = {};
    var runtimeMap = {};
    for (var i = 0; i < analysis.assets.length; i++)
        assetMap[analysis.assets[i].id] = analysis.assets[i];
    for (var j = 0; j < analysis.runtimeRecords.length; j++)
        runtimeMap[analysis.runtimeRecords[j].id] = analysis.runtimeRecords[j];
    var written = 0;
    for (var k = 0; k < analysis.interestingEntrypoints.length && written < 10; k++) {
        var entry = analysis.interestingEntrypoints[k];
        var record = entry.kind === 'chunk' ? assetMap[entry.id] : runtimeMap[entry.id];
        if (!record) continue;
        if (entry.kind === 'chunk' && !record.content) continue;
        if (entry.kind === 'runtime' && typeof record.text !== 'string') continue;
        written++;
        var label = sanitizePathPart(entry.label || entry.id, entry.kind);
        entry.readableFile =
            '_analysis/readable/' + ('0000' + written).slice(-4) + '-' + label + '.js';
        zip.file(entry.readableFile, buildReadableArtifact(entry, record));
    }
}

function buildReadableArtifact(entry, record) {
    var body = (entry.kind === 'chunk' ? record.content : record.text) || '';
    var readable = looksMinified(body) ? beautifyJs(body) : body;
    var facts = [
        'Kind: ' + entry.kind,
        'Label: ' + (entry.label || entry.id),
        'URL: ' + (entry.url || ''),
        'File: ' + (entry.file || ''),
        'Boundaries: ' + ((entry.boundaryLabels || []).join(', ') || 'none'),
        'Why: ' + (entry.why || ''),
        'Score: ' + (entry.score || 0),
        'Beautified: ' + (readable === body ? 'no' : 'yes'),
    ];
    var header = ['/*', ' * Semantic reconstruction']
        .concat(
            facts.map(function (line) {
                return ' * ' + line;
            }),
        )
        .concat([' */', ''])
        .join('\n');
    return header + readable;
}

function collectGraphQLOperations(recon) {
    var operations = [];
    var sources = [recon && recon.xhr ? recon.xhr : [], recon && recon.fetch ? recon.fetch : []];
    for (var i = 0; i < sources.length; i++) {
        for (var j = 0; j < sources[i].length; j++) {
            var parsed = parseGraphQLOperation(sources[i][j]);
            if (parsed) operations.push(parsed);
        }
    }
    return operations;
}

function parseGraphQLOperation(entry) {
    if (!entry) return null;
    var url = String(entry.url || '');
    var body = entry.requestBody;
    if (url.toLowerCase().indexOf('graphql') < 0 && !looksLikeGraphQLBody(body)) return null;
    var payload = normalizeGraphQLPayload(body);
    return {
        url: url,
        method: entry.method || 'POST',
        operationName: payload.operationName || '',
        operationType: payload.operationType || '',
        queryPreview: payload.queryPreview || '',
        timestamp: entry.timestamp || 0,
        status: entry.status || 0,
    };
}

function looksLikeGraphQLBody(body) {
    if (!body) return false;
    if (typeof body === 'string')
        return (
            /(?:^|\b)(query|mutation|subscription)\b/.test(body) ||
            body.indexOf('operationName') >= 0
        );
    return typeof body === 'object' && (body.query || body.operationName || body.extensions);
}

function normalizeGraphQLPayload(body) {
    var payload = body;
    if (typeof payload === 'string') {
        try {
            payload = JSON.parse(payload);
        } catch (_) {
            payload = { query: payload };
        }
    }
    payload = payload && typeof payload === 'object' ? payload : {};
    var query = String(payload.query || payload.body || '');
    var match = query.match(/\b(query|mutation|subscription)\s+([A-Za-z0-9_]+)/);
    return {
        operationName: payload.operationName || (match ? match[2] : ''),
        operationType: match ? match[1] : '',
        queryPreview: query.substring(0, 240),
    };
}

// External source maps are fetched as text for the unpack stage. The panel
// origin cannot read every page asset, so the page context is the fallback and
// both paths fail soft: a missing map is never an export error.
function fetchSourceMapText(url) {
    return fetch(url, { credentials: 'omit' })
        .then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res.text();
        })
        .catch(function () {
            return fetchSourceMapTextInPage(url);
        })
        .catch(function () {
            return null;
        });
}

function fetchSourceMapTextInPage(url) {
    return new Promise(function (resolve) {
        var expression =
            '(function(){return fetch(' +
            JSON.stringify(url) +
            ',{credentials:"include"})' +
            '.then(function(r){return r.ok?r.text():""})' +
            '.catch(function(){return ""})})()';
        chrome.devtools.inspectedWindow.eval(
            expression,
            { awaitPromise: true },
            function (result, error) {
                resolve(!error && typeof result === 'string' && result.length ? result : null);
            },
        );
    });
}

function generateWaterfallHTML(timings) {
    if (!timings || !timings.length) return '<html><body>No timing data available.</body></html>';
    var sorted = timings.slice().sort(function (a, b) {
        return a.startTime - b.startTime;
    });
    var maxEnd = 0;
    for (var i = 0; i < sorted.length; i++) {
        var end = sorted[i].responseEnd || sorted[i].startTime + sorted[i].duration;
        if (end > maxEnd) maxEnd = end;
    }
    var totalTime = maxEnd;
    var ROW_H = 22;
    var LABEL_W = 360;
    var BAR_START = LABEL_W + 8;
    var TOTAL_W = 1200;
    var BAR_W = TOTAL_W - BAR_START - 10;
    var chartHeight = sorted.length * ROW_H + 60;
    var svgHeight = chartHeight + 120;
    var COLORS = {
        dns: 'rgba(3,169,244,0.6)',
        tcp: 'rgba(255,152,0,0.6)',
        ssl: 'rgba(156,39,176,0.6)',
        ttfb: 'rgba(76,175,80,0.6)',
        download: 'rgba(3,169,244,0.9)',
        text: '#ccc',
        bg: '#242424',
        stripe: '#2a2a2a',
    };
    var rows = '';
    for (var r = 0; r < sorted.length; r++) {
        var e = sorted[r];
        var y = 40 + r * ROW_H;
        if (r % 2 === 0)
            rows +=
                '<rect x="' +
                BAR_START +
                '" y="' +
                y +
                '" width="' +
                BAR_W +
                '" height="' +
                ROW_H +
                '" fill="' +
                COLORS.stripe +
                '" opacity="0.3"/>';
        var label = e.name.replace(/^https?:\/\/[^\/]+\//, '').substring(0, 55);
        rows +=
            '<text x="' +
            (BAR_START - 6) +
            '" y="' +
            (y + 14) +
            '" fill="' +
            COLORS.text +
            '" font-size="11" font-family="monospace" text-anchor="end">' +
            escapeXml(label) +
            '</text>';
        var toX = function (t) {
            return BAR_START + (t / totalTime) * BAR_W;
        };
        if (e.domainLookupStart > 0 && e.domainLookupEnd > e.domainLookupStart)
            rows +=
                '<rect x="' +
                toX(e.domainLookupStart) +
                '" y="' +
                (y + 4) +
                '" width="' +
                Math.max(1, toX(e.domainLookupEnd) - toX(e.domainLookupStart)) +
                '" height="' +
                (ROW_H - 8) +
                '" fill="' +
                COLORS.dns +
                '"><title>DNS: ' +
                formatMs(e.domainLookupEnd - e.domainLookupStart) +
                '</title></rect>';
        if (e.connectStart > 0 && e.connectEnd > 0) {
            var tcpWidth = Math.max(1, toX(e.connectEnd) - toX(e.connectStart));
            if (e.secureConnectionStart > 0 && e.secureConnectionStart > e.connectStart)
                tcpWidth = Math.max(1, toX(e.secureConnectionStart) - toX(e.connectStart));
            if (tcpWidth > 0)
                rows +=
                    '<rect x="' +
                    toX(e.connectStart) +
                    '" y="' +
                    (y + 4) +
                    '" width="' +
                    tcpWidth +
                    '" height="' +
                    (ROW_H - 8) +
                    '" fill="' +
                    COLORS.tcp +
                    '"><title>TCP: ' +
                    formatMs(e.connectEnd - e.connectStart) +
                    '</title></rect>';
        }
        if (e.secureConnectionStart > 0 && e.connectEnd > e.secureConnectionStart)
            rows +=
                '<rect x="' +
                toX(e.secureConnectionStart) +
                '" y="' +
                (y + 4) +
                '" width="' +
                Math.max(1, toX(e.connectEnd) - toX(e.secureConnectionStart)) +
                '" height="' +
                (ROW_H - 8) +
                '" fill="' +
                COLORS.ssl +
                '"><title>SSL: ' +
                formatMs(e.connectEnd - e.secureConnectionStart) +
                '</title></rect>';
        if (e.requestStart > 0 && e.responseStart > e.requestStart)
            rows +=
                '<rect x="' +
                toX(e.requestStart) +
                '" y="' +
                (y + 4) +
                '" width="' +
                Math.max(1, toX(e.responseStart) - toX(e.requestStart)) +
                '" height="' +
                (ROW_H - 8) +
                '" fill="' +
                COLORS.ttfb +
                '"><title>TTFB: ' +
                formatMs(e.responseStart - e.requestStart) +
                '</title></rect>';
        if (e.responseStart > 0 && e.responseEnd > e.responseStart)
            rows +=
                '<rect x="' +
                toX(e.responseStart) +
                '" y="' +
                (y + 4) +
                '" width="' +
                Math.max(1, toX(e.responseEnd) - toX(e.responseStart)) +
                '" height="' +
                (ROW_H - 8) +
                '" fill="' +
                COLORS.download +
                '"><title>Download: ' +
                formatMs(e.responseEnd - e.responseStart) +
                '</title></rect>';
        var dur = e.responseEnd - e.startTime || e.duration;
        rows +=
            '<text x="' +
            (toX(e.responseEnd || e.startTime + dur) + 6) +
            '" y="' +
            (y + 14) +
            '" fill="#888" font-size="10" font-family="monospace">' +
            formatMs(dur) +
            '</text>';
    }
    var gridLines = '';
    var numTicks = Math.min(10, Math.ceil(totalTime / 100));
    for (var t = 0; t <= numTicks; t++) {
        var tx = BAR_START + (t / numTicks) * BAR_W;
        gridLines +=
            '<line x1="' +
            tx +
            '" y1="40" x2="' +
            tx +
            '" y2="' +
            (chartHeight - 10) +
            '" stroke="#333" stroke-width="0.5"/>';
        gridLines +=
            '<text x="' +
            tx +
            '" y="30" fill="#777" font-size="10" font-family="monospace" text-anchor="middle">' +
            formatMs((t / numTicks) * totalTime) +
            '</text>';
    }
    return (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width, initial-scale=1.0">\n<title>Waterfall Report</title>\n<style>*{margin:0;padding:0;box-sizing:border-box}body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding:20px}h1{font-size:20px;margin-bottom:6px;color:#03a9f4}.sub{color:#888;font-size:12px;margin-bottom:16px}.summary{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}.stat{background:#16213e;border-radius:6px;padding:8px 14px;border:1px solid #2a2a4a}.stat .val{font-size:18px;font-weight:600;color:#03a9f4}.stat .lbl{font-size:10px;color:#888;text-transform:uppercase;letter-spacing:.5px}.chart{background:#1e1e36;border-radius:8px;padding:16px;overflow-x:auto;border:1px solid #2a2a4a}.legend{display:flex;gap:16px;margin-bottom:10px;flex-wrap:wrap}.legend span{display:flex;align-items:center;gap:4px;font-size:11px}.legend .sw{width:12px;height:12px;border-radius:2px}.controls{display:flex;gap:8px;margin-bottom:12px}.controls button{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 12px;border-radius:4px;cursor:pointer;font-size:11px}.controls button:hover{background:#1e1e46;border-color:#03a9f4}.controls input{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 10px;border-radius:4px;font-size:11px;width:240px}.controls input:focus{outline:none;border-color:#03a9f4}.controls select{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px;border-radius:4px;font-size:11px}.dark{background:#f5f5f5;color:#333}.dark h1{color:#0288d1}.dark .stat{background:#fff;border:1px solid #ddd}.dark .stat .val{color:#0288d1}.dark .chart{background:#fff;border:1px solid #ddd}.dark .controls button{background:#eee;color:#333;border:1px solid #ccc}.dark .controls input{background:#fff;color:#333;border:1px solid #ccc}.dark .controls select{background:#fff;color:#333;border:1px solid #ccc}table{width:100%;border-collapse:collapse;margin-top:10px;font-size:11px}th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #2a2a4a}th{color:#888;font-weight:500;position:sticky;top:0;background:#1e1e36}tr:hover{background:rgba(3,169,244,.1)}.dark th{background:#fff;color:#666}.dark td{border-color:#eee}</style>\n</head>\n<body><h1>Network Waterfall</h1><div class="sub">Generated ' +
        new Date().toISOString() +
        ' | ' +
        sorted.length +
        ' requests | Total: ' +
        formatMs(totalTime) +
        '</div><div class="summary">' +
        computeReconStats(timings) +
        '</div><div class="controls"><button onclick="toggleTheme()">Toggle Dark/Light</button><input id="search" placeholder="Filter by URL..." oninput="filterTable()"><select id="typeFilter" onchange="filterTable()"><option value="">All types</option></select></div><div class="chart"><div class="legend"><span><span class="sw" style="background:' +
        COLORS.dns +
        '"></span> DNS</span><span><span class="sw" style="background:' +
        COLORS.tcp +
        '"></span> TCP</span><span><span class="sw" style="background:' +
        COLORS.ssl +
        '"></span> SSL</span><span><span class="sw" style="background:' +
        COLORS.ttfb +
        '"></span> TTFB</span><span><span class="sw" style="background:' +
        COLORS.download +
        '"></span> Download</span></div><svg viewBox="0 0 ' +
        TOTAL_W +
        ' ' +
        svgHeight +
        '" style="width:100%;height:auto;min-width:' +
        TOTAL_W +
        'px"><rect width="' +
        TOTAL_W +
        '" height="' +
        svgHeight +
        '" fill="' +
        COLORS.bg +
        '" rx="6"/>' +
        gridLines +
        rows +
        '</svg></div>' +
        generateTable(sorted) +
        '<script>var timings=' +
        JSON.stringify(sorted) +
        ';function toggleTheme(){document.body.classList.toggle("dark")}var types=[...new Set(timings.map(function(t){return t.initiatorType||"other"}))];var sel=document.getElementById("typeFilter");for(var i=0;i<types.length;i++){var o=document.createElement("option");o.value=types[i];o.textContent=types[i];sel.appendChild(o)}function filterTable(){var q=(document.getElementById("search").value||"").toLowerCase();var tp=sel.value;var rows=document.querySelectorAll("#resTable tbody tr");for(var i=0;i<rows.length;i++){var r=rows[i];var url=(r.cells[0].textContent||"").toLowerCase();var type=r.cells[1].textContent||"";var show=!q||url.indexOf(q)>-1;if(tp&&type!==tp)show=false;r.style.display=show?"":"none"}}</script></body></html>'
    );
}

function generateTable(timings) {
    var html =
        '<table id="resTable"><thead><tr><th>URL</th><th>Type</th><th>Status</th><th>Size</th><th>Time</th><th>DNS</th><th>TCP</th><th>SSL</th><th>TTFB</th><th>Download</th></tr></thead><tbody>';
    for (var i = 0; i < timings.length; i++) {
        var e = timings[i];
        var dns = e.domainLookupEnd - e.domainLookupStart || 0;
        var tcp = e.connectEnd - e.connectStart || 0;
        var ssl =
            e.secureConnectionStart > 0 && e.connectEnd > 0
                ? e.connectEnd - e.secureConnectionStart
                : 0;
        var ttfb = e.responseStart - e.requestStart || 0;
        var download = e.responseEnd - e.responseStart || 0;
        var status = e.transferSize > 0 || e.encodedBodySize > 0 ? 'OK' : 'from cache';
        var size = formatSize(e.transferSize || e.encodedBodySize || e.decodedBodySize || 0);
        html +=
            '<tr><td style="max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' +
            escapeAttr(e.name) +
            '">' +
            escapeXml(e.name) +
            '</td><td>' +
            escapeXml(e.initiatorType || 'other') +
            '</td><td>' +
            status +
            '</td><td>' +
            size +
            '</td><td>' +
            formatMs(e.duration || 0) +
            '</td><td>' +
            (dns > 0 ? formatMs(dns) : '-') +
            '</td><td>' +
            (tcp > 0 ? formatMs(tcp) : '-') +
            '</td><td>' +
            (ssl > 0 ? formatMs(ssl) : '-') +
            '</td><td>' +
            (ttfb > 0 ? formatMs(ttfb) : '-') +
            '</td><td>' +
            (download > 0 ? formatMs(download) : '-') +
            '</td></tr>';
    }
    return html + '</tbody></table>';
}

function computeReconStats(timings) {
    var totalBytes = 0;
    var slowest = 0;
    var domains = {};
    var types = {};
    for (var i = 0; i < timings.length; i++) {
        var t = timings[i];
        totalBytes += t.transferSize || t.encodedBodySize || 0;
        var dur = t.responseEnd - t.startTime || t.duration || 0;
        if (dur > slowest) slowest = dur;
        var m = t.name.match(/^https?:\/\/([^\/]+)/);
        if (m) domains[m[1]] = true;
        var tp = t.initiatorType || 'other';
        types[tp] = (types[tp] || 0) + 1;
    }
    var typeStr = '';
    for (var k in types)
        if (Object.prototype.hasOwnProperty.call(types, k))
            typeStr +=
                '<div class="stat"><div class="val">' +
                types[k] +
                '</div><div class="lbl">' +
                escapeXml(k) +
                '</div></div>';
    return (
        '<div class="stat"><div class="val">' +
        timings.length +
        '</div><div class="lbl">Requests</div></div><div class="stat"><div class="val">' +
        formatSize(totalBytes) +
        '</div><div class="lbl">Total Size</div></div><div class="stat"><div class="val">' +
        Object.keys(domains).length +
        '</div><div class="lbl">Domains</div></div><div class="stat"><div class="val">' +
        formatMs(slowest) +
        '</div><div class="lbl">Slowest</div></div>' +
        typeStr
    );
}

function generateDOMSnapshotHTML(domHtml, pageMeta) {
    var title = pageMeta && pageMeta.title ? pageMeta.title : 'DOM Snapshot';
    var url = pageMeta && pageMeta.url ? pageMeta.url : '';
    return (
        '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="UTF-8">\n<title>DOM Snapshot</title>\n<style>body{font-family:system-ui,sans-serif;padding:20px;background:#fff;color:#222}h1{margin:0 0 8px}p{margin:0 0 16px;color:#555}pre{white-space:pre-wrap;word-break:break-word;font-family:Consolas,monospace;font-size:12px;line-height:1.5;background:#f7f7f7;border:1px solid #ddd;border-radius:6px;padding:16px}</style>\n</head>\n<body><h1>' +
        escapeXml(title) +
        '</h1><p>' +
        escapeXml(url) +
        '</p><pre>' +
        escapeXml(domHtml || '') +
        '</pre></body>\n</html>'
    );
}

function escapeXml(s) {
    return s
        ? String(s)
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;')
              .replace(/'/g, '&#39;')
        : '';
}

function escapeAttr(s) {
    return s
        ? String(s)
              .replace(/&/g, '&amp;')
              .replace(/"/g, '&quot;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
        : '';
}
