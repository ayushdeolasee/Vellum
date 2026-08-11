// Keep this literal in sync with CaptureDOMPolicy.maximumByteCount. Safari's
// property-list XPC hop has no documented limit, so v1 deliberately sends at
// most 1 MiB of UTF-8 DOM and records the measured size for URL-only fallback.
var VellumMaximumDOMBytes = 1048576;

var VellumCapturePreprocessor = function() {};
VellumCapturePreprocessor.prototype = {
    run: function(arguments) {
        var html = document.documentElement ? document.documentElement.outerHTML : null;
        var htmlByteCount = html ? new TextEncoder().encode(html).byteLength : 0;
        var result = {
            url: document.baseURI || document.URL,
            title: document.title || "",
            htmlByteCount: htmlByteCount
        };
        if (html && htmlByteCount <= VellumMaximumDOMBytes) {
            result.outerHTML = html;
        }
        arguments.completionFunction(result);
    }
};

var ExtensionPreprocessingJS = new VellumCapturePreprocessor();
