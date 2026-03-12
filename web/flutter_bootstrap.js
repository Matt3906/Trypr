{{flutter_js}}
{{flutter_build_config}}

const isLocalhost = ["localhost", "127.0.0.1", "::1"].includes(
  window.location.hostname,
);

_flutter.loader.load({
  serviceWorkerSettings: isLocalhost
      ? null
      : {
          serviceWorkerVersion: {{flutter_service_worker_version}},
          // Avoid a 4s startup stall when SW activation/update is slow.
          timeoutMillis: 500,
        },
});
