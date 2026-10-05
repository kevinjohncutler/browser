import Foundation

/// Supplies the navigation events missing from WebKit's Chromium compatibility surface.
/// The vendor's credential selection, encryption, and filling code remains unchanged.
enum ApplePasswordCompatibility {
    /// Apple's localizer passes null optional arguments. WebKit rejects these before falling back.
    static let localization = """
    function oraLocalizedMessage(name, substitutions, options) {
      if (options != null) return chrome.i18n.getMessage(name, substitutions ?? [], options);
      if (substitutions != null) return chrome.i18n.getMessage(name, substitutions);
      return chrome.i18n.getMessage(name);
    }
    """

    private static func localizedScript(_ script: String) -> String {
        localization + "\n" + script.replacingOccurrences(of: "chrome.i18n.getMessage(", with: "oraLocalizedMessage(")
    }

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
      // WebKit forbids action API calls from a web-accessible extension iframe.
      // Only the extension's own completion list can request its popup through this privileged worker.
      chrome.runtime.onMessage.addListener((message, sender, reply) => {
        if (!message?.oraOpenPasswordPopup) return false;
        const expected = chrome.runtime.getURL('completion_list.html');
        if (sender.id !== chrome.runtime.id || sender.url?.split('?')[0] !== expected) {
          reply({error:'Invalid password popup source'}); return false;
        }
        const options = sender.tab ? {windowId:sender.tab.windowId} : {};
        chrome.action.openPopup(options).then(() => reply({ok:true}), error => reply({error:String(error)}));
        return true;
      });
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
        let versionFile = directory.appendingPathComponent("ora_compatibility_version")
        if (try? String(contentsOf: versionFile, encoding: .utf8)) == "2" {
            return
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        guard var backgroundConfig = manifest["background"] as? [String: Any],
              let worker = backgroundConfig["service_worker"] as? String,
              !worker.hasPrefix("/"), !worker.split(separator: "/").contains("..")
        else { throw CocoaError(.fileReadCorruptFile) }
        // Earlier installations retain the untouched original background beside the generated worker.
        let originalWorker = worker == "ora_background.js" ? "background.js" : worker
        let script = try String(contentsOf: directory.appendingPathComponent(originalWorker), encoding: .utf8)
        try (background + "\n" + localizedScript(script)).write(
            to: directory.appendingPathComponent("ora_background.js"),
            atomically: true,
            encoding: .utf8
        )
        backgroundConfig["service_worker"] = "ora_background.js"
        manifest["background"] = backgroundConfig
        let completionURL = directory.appendingPathComponent("completion_list.js")
        if FileManager.default.fileExists(atPath: completionURL.path) {
            let original = try String(contentsOf: completionURL, encoding: .utf8)
            let call = "chrome.action.openPopup()"
            guard original.components(separatedBy: call).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
            let relay = """
            async function oraOpenPasswordPopup() {
              const result = await chrome.runtime.sendMessage({oraOpenPasswordPopup:true});
              if (!result?.ok) throw new Error(result?.error || 'Password popup unavailable');
            }
            """
            try (relay + "\n" + localizedScript(original.replacingOccurrences(
                of: call,
                with: "oraOpenPasswordPopup()"
            )))
            .write(to: completionURL, atomically: true, encoding: .utf8)
        }
        for name in ["page_popup.js", "content_script.js", "settings.js"] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try localizedScript(String(contentsOf: file, encoding: .utf8))
                .write(to: file, atomically: true, encoding: .utf8)
        }
        try content.write(to: directory.appendingPathComponent("ora_navigation.js"), atomically: true, encoding: .utf8)
        if var contentScripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in contentScripts.indices {
                let scripts = (contentScripts[index]["js"] as? [String] ?? []).filter { $0 != "ora_navigation.js" }
                contentScripts[index]["js"] = ["ora_navigation.js"] + scripts
            }
            manifest["content_scripts"] = contentScripts
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
            to: manifestURL,
            options: .atomic
        )
        try "2".write(to: versionFile, atomically: true, encoding: .utf8)
    }
}
