(function (global) {
    'use strict';

    var VERSION = '1.0.0';

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    function lower(value) {
        return String(value || '').toLowerCase();
    }

    function normalizeList(list) {
        return Array.isArray(list) ? list.filter(Boolean).map(String) : [];
    }

    function addUnique(list, value) {
        value = String(value || '').trim();
        if (value && list.indexOf(value) < 0) list.push(value);
    }

    function anyRegex(list, pattern) {
        for (var i = 0; i < list.length; i++) {
            if (pattern.test(String(list[i] || ''))) return true;
        }
        return false;
    }

    function hasUrl(urls, needle) {
        needle = lower(needle);
        for (var i = 0; i < urls.length; i++) {
            if (lower(urls[i]).indexOf(needle) >= 0) return true;
        }
        return false;
    }

    function createDefaultStrategy() {
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
            reasons: ['Generic adaptive profile']
        };
    }

    function buildStrategy(profile) {
        var strategy = createDefaultStrategy();
        var technologies = profile.technologies || [];
        var traits = profile.traits || [];
        var techNames = {};
        var reasons = [];

        for (var i = 0; i < technologies.length; i++) techNames[technologies[i].name] = true;

        function hasTrait(name) {
            return traits.indexOf(name) >= 0;
        }

        function note(reason) {
            addUnique(reasons, reason);
        }

        if (techNames['Next.js'] || techNames['Nuxt'] || techNames['Remix'] || techNames['Astro'] || techNames['SvelteKit']) {
            strategy.profile = 'spa-hydration';
            strategy.bootDelayMs = 1600;
            strategy.networkQuietMs = 1500;
            strategy.mutationQuietMs = 1800;
            strategy.runtimeQuietMs = 1400;
            strategy.preferHydratedDom = true;
            strategy.captureFrameworkState = true;
            strategy.prioritizeSourceMaps = true;
            note('Hydration-oriented framework markers detected');
        }

        if (hasTrait('graphql-heavy') || techNames['Apollo'] || techNames['Relay'] || techNames['GraphQL']) {
            if (strategy.profile === 'generic-app') strategy.profile = 'graphql-app';
            strategy.captureGraphQLOps = true;
            strategy.networkQuietMs = Math.max(strategy.networkQuietMs, 1600);
            note('GraphQL traffic detected');
        }

        if (hasTrait('socket-heavy')) {
            strategy.profile = 'socket-streaming';
            strategy.socketQuietMs = 3600;
            strategy.maxCaptureMs = Math.max(strategy.maxCaptureMs, 22000);
            note('Socket or SSE activity detected');
        }

        if (hasTrait('worker-heavy') || hasTrait('wasm-heavy')) {
            strategy.profile = 'worker-runtime-heavy';
            strategy.workerGraceMs = 2200;
            strategy.runtimeQuietMs = 1800;
            strategy.maxCaptureMs = Math.max(strategy.maxCaptureMs, 24000);
            note('Worker or WebAssembly activity detected');
        }

        if (techNames['WordPress'] || techNames['Shopify']) {
            if (strategy.profile === 'generic-app') strategy.profile = 'static-site';
            strategy.networkQuietMs = Math.min(strategy.networkQuietMs, 1100);
            strategy.mutationQuietMs = Math.min(strategy.mutationQuietMs, 1000);
            note('CMS or commerce platform markers detected');
        }

        if (techNames['Webpack'] || techNames['Vite'] || techNames['Parcel']) {
            strategy.prioritizeSourceMaps = true;
            note('Bundler markers detected');
        }

        strategy.reasons = reasons.length ? reasons : strategy.reasons;
        return strategy;
    }

    function analyze(snapshot) {
        snapshot = snapshot || {};
        var urls = normalizeList(snapshot.resourceUrls).concat(normalizeList(snapshot.scriptUrls));
        var globals = snapshot.globals || {};
        var dom = snapshot.dom || {};
        var network = snapshot.network || {};
        var runtime = snapshot.runtime || {};
        var techMap = {};
        var traitMap = {};

        function tech(name, category, confidence, signal) {
            var item = techMap[name];
            if (!item) {
                item = { name: name, category: category, confidence: confidence || 0.5, evidence: [] };
                techMap[name] = item;
            }
            item.confidence = Math.max(item.confidence, confidence || 0.5);
            if (signal) addUnique(item.evidence, signal);
        }

        function trait(name, signal) {
            if (!traitMap[name]) traitMap[name] = [];
            if (signal) addUnique(traitMap[name], signal);
        }

        if (globals.nextData || dom.hasNextRoot || hasUrl(urls, '/_next/')) tech('Next.js', 'framework', 0.97, globals.nextData ? 'window.__NEXT_DATA__' : '/_next/ assets');
        if (globals.reactDevtoolsHook || hasUrl(urls, 'react-dom') || anyRegex(urls, /\/react(?:-dom)?(?:@|\.|\/)/i)) tech('React', 'library', 0.86, globals.reactDevtoolsHook ? '__REACT_DEVTOOLS_GLOBAL_HOOK__' : 'React bundle markers');
        if (globals.nuxt || dom.hasNuxtRoot || hasUrl(urls, '/_nuxt/')) tech('Nuxt', 'framework', 0.95, dom.hasNuxtRoot ? '#__nuxt' : '/_nuxt/ assets');
        else if (globals.vue || globals.vueDevtoolsHook || dom.hasVueApp) tech('Vue', 'framework', 0.84, globals.vueDevtoolsHook ? '__VUE_DEVTOOLS_GLOBAL_HOOK__' : 'Vue mount markers');
        if (globals.angular || dom.hasNgVersion) tech('Angular', 'framework', 0.85, dom.hasNgVersion ? '[ng-version]' : 'Angular global markers');
        if (globals.svelteKit || dom.hasSvelteData || hasUrl(urls, '/_app/immutable/')) tech('SvelteKit', 'framework', 0.9, globals.svelteKit ? '__SVELTEKIT_APP_VERSION__' : 'SvelteKit asset markers');
        if (dom.hasAstroIsland || hasUrl(urls, '/_astro/')) tech('Astro', 'framework', 0.9, dom.hasAstroIsland ? '<astro-island>' : '/_astro/ assets');
        if (globals.remix || dom.hasRemixData) tech('Remix', 'framework', 0.88, globals.remix ? '__remixContext' : 'Remix DOM markers');

        if (globals.webpackChunk || globals.webpackJsonp || anyRegex(urls, /\.chunk\.[^/?#]+$/i) || anyRegex(urls, /webpack(?:-|\.|\/)/i)) tech('Webpack', 'bundler', 0.88, globals.webpackChunk ? 'webpackChunk* global' : 'Chunk naming');
        if (globals.vitePreamble || hasUrl(urls, '/@vite/client')) tech('Vite', 'bundler', 0.95, globals.vitePreamble ? '__vite_plugin_react_preamble_installed__' : '/@vite/client');
        else if (anyRegex(urls, /\/assets\/.+\.[a-f0-9]{6,}\.(?:js|css)/i)) tech('Vite', 'bundler', 0.72, 'Hashed /assets/ bundles');
        if (anyRegex(urls, /parcel/i)) tech('Parcel', 'bundler', 0.67, 'Parcel URL marker');

        if ((dom.metaGenerator && dom.metaGenerator.indexOf('wordpress') >= 0) || hasUrl(urls, '/wp-content/') || hasUrl(urls, '/wp-includes/')) tech('WordPress', 'platform', 0.94, dom.metaGenerator && dom.metaGenerator.indexOf('wordpress') >= 0 ? 'generator meta tag' : 'wp-content assets');
        if (globals.shopify || dom.hasShopify || hasUrl(urls, 'cdn.shopify.com') || hasUrl(urls, '/shopifycloud/')) tech('Shopify', 'platform', 0.95, globals.shopify ? 'window.Shopify' : 'Shopify asset markers');

        if (network.graphqlCount > 0) tech('GraphQL', 'protocol', 0.9, 'GraphQL requests observed');
        if (globals.apolloClient || globals.apolloState || anyRegex(normalizeList(network.graphqlEndpoints), /apollo/i)) tech('Apollo', 'data', 0.82, globals.apolloClient ? '__APOLLO_CLIENT__' : 'Apollo/GraphQL markers');
        if (globals.relay || anyRegex(normalizeList(network.graphqlEndpoints), /relay/i)) tech('Relay', 'data', 0.76, globals.relay ? '__RELAY_DEVTOOLS_HOOK__' : 'Relay markers');

        if ((runtime.wasmCount || 0) > 0) tech('WebAssembly', 'runtime', 0.88, 'WASM bytes captured');
        if (globals.serviceWorkerController || (runtime.serviceWorkerCount || 0) > 0) tech('Service Worker', 'runtime', 0.8, 'serviceWorker activity');

        if (globals.nextData || dom.hasNuxtRoot || dom.hasVueApp || dom.hasSvelteData || dom.hasRemixData || dom.hasAstroIsland) trait('spa-hydration', 'Framework hydration markers');
        if ((dom.mutationCount || 0) > 20) trait('dynamic-dom', 'Sustained DOM mutation activity');
        if (network.graphqlCount > 0) trait('graphql-heavy', 'GraphQL endpoints observed');
        if ((network.websocketCount || 0) > 0 || (network.sseCount || 0) > 0 || (snapshot.activity && snapshot.activity.openSockets > 0)) trait('socket-heavy', 'WebSocket or SSE activity');
        if ((runtime.workerCount || 0) > 0) trait('worker-heavy', 'Worker runtime observed');
        if ((runtime.wasmCount || 0) > 0) trait('wasm-heavy', 'WebAssembly runtime observed');
        if ((network.fetchCount || 0) + (network.xhrCount || 0) > 10) trait('api-heavy', 'High XHR/fetch volume');
        if ((runtime.runtimeCount || 0) > 6) trait('runtime-generated-code', 'In-memory code generation observed');
        if ((dom.scriptCount || 0) <= 6 && (network.fetchCount || 0) <= 2 && (network.xhrCount || 0) <= 1) trait('static-ish', 'Low script and API activity');

        if (!Object.keys(techMap).length) tech('Generic Web App', 'profile', 0.45, 'Fallback profile');

        var technologies = Object.keys(techMap).map(function (name) { return techMap[name]; }).sort(function (left, right) {
            if (right.confidence !== left.confidence) return right.confidence - left.confidence;
            return left.name.localeCompare(right.name);
        });
        var traits = Object.keys(traitMap).sort();
        var evidence = { technologies: {}, traits: traitMap, globals: snapshot.globalsDetected || [], endpoints: normalizeList(network.graphqlEndpoints).slice(0, 20) };
        for (var i = 0; i < technologies.length; i++) evidence.technologies[technologies[i].name] = technologies[i].evidence.slice();

        var confidenceBase = technologies[0] ? technologies[0].confidence * 100 : 45;
        var confidence = Math.round(clamp(confidenceBase + Math.min(technologies.length, 4) * 4 + Math.min(traits.length, 5) * 3, 35, 99));
        var profile = {
            version: VERSION,
            generatedAt: Date.now(),
            technologies: technologies,
            traits: traits,
            confidence: confidence,
            evidence: evidence
        };
        profile.strategy = buildStrategy(profile);
        profile.summary = profile.strategy.profile + ' | ' + technologies.slice(0, 3).map(function (item) { return item.name; }).join(', ');
        return profile;
    }

    global.__STACK_PROFILER__ = {
        version: VERSION,
        defaultStrategy: createDefaultStrategy,
        buildStrategy: buildStrategy,
        analyze: analyze
    };
})(window);
