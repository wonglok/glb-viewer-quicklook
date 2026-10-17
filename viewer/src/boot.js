/**
 * Loaded before the bundle, deliberately as a separate classic script.
 *
 * If the bundle throws while it is being evaluated — a bad import, an
 * unsupported API — nothing inside it ever runs, so its own error handling
 * cannot report anything. Installing the handlers first means those failures
 * still reach the native log, which is the only output a Quick Look extension
 * has (it is out of process and has no visible console).
 */
(function () {
  function send(type, message) {
    try {
      window.webkit.messageHandlers.viewer.postMessage({ type: type, message: String(message) });
    } catch (_) {
      /* no native host: browser dev mode */
    }
  }

  window.__glbReport = send;

  window.addEventListener("error", function (event) {
    var where = event.filename ? " @ " + event.filename + ":" + event.lineno : "";
    send("error", "Uncaught: " + (event.message || event.error) + where);
  });

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    send("error", "Unhandled rejection: " + ((reason && reason.message) || reason));
  });

  // DRACOLoader and KTX2Loader swallow worker failures: a decoder that dies
  // inside its worker leaves the load promise pending forever, with no error
  // anywhere. Reporting it here turns a silently blank preview into a log line.
  var Worker = window.Worker;
  window.Worker = function (url, options) {
    var worker = new Worker(url, options);
    worker.addEventListener("error", function (event) {
      send("error", "Web Worker failed: " + (event.message || "unknown error"));
    });
    return worker;
  };
  window.Worker.prototype = Worker.prototype;
})();
