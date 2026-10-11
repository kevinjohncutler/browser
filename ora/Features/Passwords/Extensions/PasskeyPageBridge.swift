import Foundation
import WebKit

@MainActor
final class PasskeyPageBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let connection: PasskeyConnection
    private var requestID: String?
    private var generation = 0

    init(connection: PasskeyConnection) {
        self.connection = connection
    }

    func cancel() {
        generation += 1
        requestID = nil
        connection.cancel()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let security = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, security.protocol == "https",
              security.port == 0 || security.port == 443,
              let pageURL = message.webView?.url, pageURL.scheme == "https",
              pageURL.host == security.host,
              let body = message.body as? [String: Any], let operation = body["operation"] as? String,
              let identifier = body["identifier"] as? String, UUID(uuidString: identifier) != nil
        else {
            replyHandler(["error": "SecurityError"], nil)
            return
        }
        if operation == "cancel" {
            if requestID == identifier {
                cancel()
            }
            replyHandler([:], nil)
            return
        }
        guard operation == "available" || operation == "get", requestID == nil else {
            replyHandler(["error": "NotAllowedError"], nil)
            return
        }
        // No background tab or untrusted embedded frame can initiate a system authentication prompt.
        if operation == "get", ProcessInfo.processInfo.environment["ORA_HEADLESS_TESTING"] != "1",
           message.webView?.window?.isKeyWindow != true
        {
            replyHandler(["error": "NotAllowedError"], nil)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 131_072 else {
            replyHandler(["error": "DataError"], nil)
            return
        }
        requestID = identifier
        let current = generation
        let origin = "https://" + security.host
        Task { [weak self] in
            guard let self else { replyHandler(["error": "AbortError"], nil)
                return
            }
            defer {
                if current == generation {
                    requestID = nil
                }
            }
            do {
                let reply = try await connection.perform(data, origin: origin)
                guard current == generation else { replyHandler(["error": "AbortError"], nil)
                    return
                }
                try replyHandler(JSONSerialization.jsonObject(with: reply), nil)
            } catch {
                let allowed = [
                    "AbortError",
                    "SecurityError",
                    "NotAllowedError",
                    "NotSupportedError",
                    "DataError",
                    "InvalidStateError",
                    "TypeError"
                ]
                let name = allowed.contains(error.localizedDescription) ? error.localizedDescription : "NotAllowedError"
                replyHandler(["error": name], nil)
            }
        }
    }

    static let script = #"""
    (() => {
      if (!isSecureContext || window !== window.top || !window.PublicKeyCredential ||
          !window.webkit?.messageHandlers?.oraPasskey) return;
      const handler = window.webkit.messageHandlers.oraPasskey;
      const nativeGet = navigator.credentials.get.bind(navigator.credentials);
      let availability;
      const encode = value => {
        const bytes = ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : new Uint8Array(value);
        if (bytes.length > 65536) throw new DOMException('Passkey request is too large', 'DataError');
        return btoa(String.fromCharCode(...bytes));
      };
      const decode = value => value == null ? null : Uint8Array.from(atob(value), c => c.charCodeAt(0)).buffer;
      const url64 = value => value?.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      const send = async body => {
        const result = await handler.postMessage(body);
        if (result.error) throw new DOMException('Apple passkey request did not complete', result.error);
        return result;
      };
      PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => {
        availability ??= send({operation:'available', identifier:crypto.randomUUID()})
          .then(result => result.available === true).catch(() => false);
        return availability;
      };
      // Conditional autofill needs a visible credential picker, which this broker does not provide.
      PublicKeyCredential.isConditionalMediationAvailable = async () => false;
      if (PublicKeyCredential.getClientCapabilities) {
        const nativeCapabilities = PublicKeyCredential.getClientCapabilities.bind(PublicKeyCredential);
        PublicKeyCredential.getClientCapabilities = async () => {
          const capabilities = await nativeCapabilities();
          const available = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
          return {...capabilities, conditionalGet:false,
            userVerifyingPlatformAuthenticator:available,
            passkeyPlatformAuthenticator:available || capabilities.passkeyPlatformAuthenticator};
        };
      }
      navigator.credentials.get = async options => {
        if (!options?.publicKey) return nativeGet(options);
        if (options.mediation === 'silent') return null;
        if (options.mediation === 'conditional') throw new DOMException('Conditional passkey selection is unavailable', 'NotSupportedError');
        if (options.publicKey.extensions?.prf || options.publicKey.extensions?.largeBlob)
          throw new DOMException('Binary passkey extensions are unavailable', 'NotSupportedError');
        if (options.signal?.aborted) throw new DOMException('Request canceled', 'AbortError');
        if (availability) await availability;
        const identifier = crypto.randomUUID();
        const cancel = () => handler.postMessage({operation:'cancel', identifier}).catch(() => {});
        options.signal?.addEventListener('abort', cancel, {once:true});
        try {
          const key = {...options.publicKey, challenge:encode(options.publicKey.challenge)};
          if (key.allowCredentials) key.allowCredentials = key.allowCredentials.map(c => ({...c, id:encode(c.id)}));
          const result = await send({operation:'get', identifier, publicKey:key});
          if (options.signal?.aborted) throw new DOMException('Request canceled', 'AbortError');
          const response = Object.create(AuthenticatorAssertionResponse.prototype);
          for (const [name, value] of Object.entries(result.response))
            Object.defineProperty(response, name, {value:decode(value), enumerable:true});
          const credential = Object.create(PublicKeyCredential.prototype);
          for (const [name, value] of Object.entries({id:result.id, type:result.type,
              rawId:decode(result.rawId), authenticatorAttachment:result.authenticatorAttachment, response}))
            Object.defineProperty(credential, name, {value, enumerable:true});
          Object.defineProperty(credential, 'getClientExtensionResults', {value:() => result.extensions});
          Object.defineProperty(credential, 'toJSON', {value:() => ({id:result.id, type:result.type,
            rawId:url64(result.rawId), authenticatorAttachment:result.authenticatorAttachment,
            response:Object.fromEntries(Object.entries(result.response).map(([k,v]) => [k,url64(v)])),
            clientExtensionResults:result.extensions})});
          return credential;
        } finally { options.signal?.removeEventListener('abort', cancel); }
      };
    })();
    """#
}
