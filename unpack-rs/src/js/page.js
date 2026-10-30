import {
    looksBinaryScript,
    decodeBase64ToBytes,
    sanitizeFilename,
    sanitizePageTitle,
    panelTrackerView,
    panelDescribeCaptureReason,
    panelFinalizeZipWithRecon,
    panelStackProfileAnalyze,
    panelCapturePolicy,
    buildZip,
} from './unpack-bridge.js';

// The archive is assembled in the engine: everything here collects
// [{path, content}] / [{path, base64}] and one call turns it into bytes. The
// engine's own file lists use that same shape, so they append straight in.
function collectFiles(target, files) {
    target.push.apply(target, files);
}

// Saving is the one part that cannot leave the DOM.
function saveBytes(name, bytes) {
    var url = URL.createObjectURL(new Blob([bytes], { type: 'application/zip' }));
    var anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = name;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
    // revoking in the same tick can cancel the download in some builds
    setTimeout(function () {
        URL.revokeObjectURL(url);
    }, 0);
}

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
var latestStackSnapshotJson = null;

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
    return panelDescribeCaptureReason(status, profile);
}

// The page-profile analysis lives in the engine: the page world collects the
// snapshot (only it can read the page's globals and DOM), the panel runs it
// here, and the profile is pushed back into the page so its own readers - the
// capture strategy, the framework introspector, the export - see the same
// object they used to compute locally. Re-analysis is skipped while the
// snapshot is unchanged, which is most polls.
function publishStackProfile(snapshot) {
    var json = JSON.stringify(snapshot);
    if (json !== latestStackSnapshotJson) {
        latestStackSnapshotJson = json;
        latestStackProfile = panelStackProfileAnalyze(snapshot);
        chrome.devtools.inspectedWindow.eval(
            'window.__STACK_PROFILE__ = ' + JSON.stringify(latestStackProfile) + '; true',
            function (result, error) {
                // A navigation mid-write leaves the page without the profile;
                // dropping the cache makes the next poll publish it again.
                if (error) latestStackSnapshotJson = null;
            },
        );
    }
    return latestStackProfile;
}

function resetTrackerView() {
    latestTracker = null;
    latestStackProfile = null;
    latestCaptureStatus = null;
    latestStackSnapshotJson = null;
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
        fetchTextAsset(
            chrome.runtime.getURL('js/framework-introspect.js'),
            'framework-introspect.js',
        ),
        fetchTextAsset(chrome.runtime.getURL('js/injected.js'), 'injected.js'),
    ])
        .then(function (scripts) {
            // The capture policy is engine-owned (panel::policy): it crosses
            // once, here, so the page world reads it from its first line.
            var policy =
                'window.__CAPTURE_POLICY__ = ' +
                JSON.stringify(panelCapturePolicy()) +
                ';\n';
            var code = policy + scripts.join('\n;\n');
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
            'JSON.stringify({ ready: window.__RESOURCE_TRACKER_READY__, data: window.__RESOURCE_TRACKER__, site: { title: document.title || "", url: location.href || "", origin: location.origin || "" }, stackProfile: window.__STACK_PROFILE__ || null, stackSnapshot: window.__STACK_SNAPSHOT__ || null, captureStatus: window.__CAPTURE_STATUS__ || null })',
            function (result, error) {
                if (error) {
                    if (attempts >= maxAttempts) stopPolling();
                    return;
                }
                try {
                    var payload = JSON.parse(result);
                    if (payload.site) renderPageOrigin(payload.site);
                    var profile = payload.stackSnapshot
                        ? publishStackProfile(payload.stackSnapshot)
                        : payload.stackProfile;
                    if (profile || payload.captureStatus)
                        renderStackProfile(profile, payload.captureStatus);
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
        var files = [];
        var pending = resources.length + 1;
        var jsAssets = [];
        var pageSnapshot = { html: '', title: 'page' };
        var done = false;

        function checkDone() {
            if (done || pending !== 0) return;
            done = true;
            collectReconAndFinalize(files, jsAssets, pageSnapshot);
        }

        for (var i = 0; i < resources.length; i++) {
            (function (resource) {
                resource.getContent(function (content, encoding) {
                    files.push(
                        encoding === 'base64'
                            ? { path: sanitizeFilename(resource.url), base64: content }
                            : { path: sanitizeFilename(resource.url), content: content },
                    );
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
                            // The engine reads `content`: a string is a text
                            // asset, an array of byte values a binary one.
                            jsAssets.push({
                                url: resource.url,
                                zipPath: sanitizeFilename(resource.url),
                                content: routedBytes,
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
                            files.push({
                                path: sanitizePageTitle(pageSnapshot.title) + '.html',
                                content: pageSnapshot.html,
                            });
                        }
                    } catch (_) {}
                }
                pending--;
                checkDone();
            },
        );
    });
}

function collectReconAndFinalize(files, jsAssets, pageSnapshot) {
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
        if (error) return finalizeZipWithRecon(files, jsAssets, null, pageSnapshot);
        try {
            finalizeZipWithRecon(files, jsAssets, JSON.parse(result), pageSnapshot);
        } catch (_) {
            finalizeZipWithRecon(files, jsAssets, null, pageSnapshot);
        }
    });
}

function finalizeZipWithRecon(files, jsAssets, reconData, pageSnapshot) {
    downloadBtn.textContent = 'Building zip...';
    setActivity('info', 'Building a site-aware export package...');
    var runtimeEntries =
        reconData && reconData.recon && reconData.recon.runtime ? reconData.recon.runtime : [];

    collectRuntimePayloads(runtimeEntries, function (runtimePayloads) {
        var result;
        try {
            result = panelFinalizeZipWithRecon(jsAssets, reconData, pageSnapshot, runtimePayloads, {
                pathPrefix: '_unpack',
            });
            collectFiles(files, result.files);
        } catch (err) {
            downloadBtn.disabled = false;
            downloadBtn.textContent = 'Download All';
            setActivity(
                'danger',
                'Unpacking failed: ' + (err && err.message ? err.message : String(err)),
            );
            return;
        }
        try {
            saveBytes('sources.zip', buildZip(files));
        } catch (err) {
            downloadBtn.disabled = false;
            downloadBtn.textContent = 'Download All';
            setActivity(
                'danger',
                'Archive failed: ' + (err && err.message ? err.message : String(err)),
            );
            return;
        }
        downloadBtn.disabled = false;
        downloadBtn.textContent = 'Download All';
        setActivity('success', result.summary);
    });
}

// Runtime payloads (eval, Function, injected scripts, JS workers) are exactly where
// obfuscation hides, so they take the same peel/beautify/module pass as page scripts.

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
