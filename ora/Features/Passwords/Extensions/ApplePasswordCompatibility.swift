import Foundation

/// Supplies the navigation events missing from WebKit's Chromium compatibility surface.
/// The vendor's credential selection, encryption, and filling code remains unchanged.
enum ApplePasswordCompatibility {
    static let background = """
    (() => {
      function event() {
        const listeners = new Set();
        return {addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn),
                hasListener: fn => listeners.has(fn), dispatch: data => { for (const fn of listeners) fn(data); }};
      }
      // Ora disables its own password overlay/save prompts for the Apple provider.
      // Address and credit-card filling are not implemented in Ora, so all three values are false.
      if (!chrome.privacy) {
        function disabledSetting() {
          return {
            onChange: event(),
            get: (details, callback) => {
              const result = {value:false, levelOfControl:'controllable_by_this_extension'};
              callback?.(result); return Promise.resolve(result);
            },
            set: (details, callback) => {
              if (details.value !== false) return Promise.reject(new Error('Ora does not provide this autofill service'));
              callback?.(); return Promise.resolve();
            },
            clear: (details, callback) => { callback?.(); return Promise.resolve(); }
          };
        }
        chrome.privacy = {services:{passwordSavingEnabled:disabledSetting(),
          autofillAddressEnabled:disabledSetting(), autofillCreditCardEnabled:disabledSetting()}};
      }
      if (!chrome.webNavigation.onHistoryStateUpdated) {
        const changes = event();
        chrome.webNavigation.onHistoryStateUpdated = changes;
        chrome.runtime.onMessage.addListener((message, sender) => {
          if (message?.oraHistoryChanged && sender.tab) changes.dispatch({tabId:sender.tab.id,
              frameId:sender.frameId ?? 0, url:sender.url, timeStamp:Date.now()});
          return false;
        });
      }
      // Ora represents replacement as tab close/open, so Chromium's tab replacement event does not occur.
      if (!chrome.webNavigation.onTabReplaced) chrome.webNavigation.onTabReplaced = event();
    })();
    """

    static let content = """
    (() => {
      let previous = location.href;
      setInterval(() => {
        if (previous === location.href) return;
        previous = location.href;
        chrome.runtime.sendMessage({oraHistoryChanged:true}).catch(() => {});
      }, 300);
    })();
    """

    static func prepare(directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        guard var backgroundConfig = manifest["background"] as? [String: Any],
              let worker = backgroundConfig["service_worker"] as? String,
              !worker.hasPrefix("/"), !worker.split(separator: "/").contains("..")
        else { throw CocoaError(.fileReadCorruptFile) }
        let script = try String(contentsOf: directory.appendingPathComponent(worker), encoding: .utf8)
        try (background + "\n" + script).write(
            to: directory.appendingPathComponent("ora_background.js"),
            atomically: true,
            encoding: .utf8
        )
        backgroundConfig["service_worker"] = "ora_background.js"
        manifest["background"] = backgroundConfig
        try content.write(to: directory.appendingPathComponent("ora_navigation.js"), atomically: true, encoding: .utf8)
        if var contentScripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in contentScripts.indices {
                contentScripts[index]["js"] = ["ora_navigation.js"] + (contentScripts[index]["js"] as? [String] ?? [])
            }
            manifest["content_scripts"] = contentScripts
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
            to: manifestURL,
            options: .atomic
        )
    }
}
