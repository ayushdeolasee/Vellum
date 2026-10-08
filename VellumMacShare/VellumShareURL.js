// URL intake only. The containing app owns page fetching and offline snapshots.
var VellumShareURLPreprocessor = function() {};
VellumShareURLPreprocessor.prototype = {
    run: function(arguments) {
        arguments.completionFunction({url: document.URL});
    }
};
var ExtensionPreprocessingJS = new VellumShareURLPreprocessor();
