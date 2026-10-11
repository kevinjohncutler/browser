import Foundation
import JavaScriptCore
@testable import Ora
import Testing

struct FingerprintingCompatibilityTests {
    @Test(arguments: [
        "https://accounts.google.com",
        "http://accounts.google.com",
        "https://accounts.google.com:8443",
        "https://accounts.google.com.example.test",
        "https://other.accounts.google.com",
        "https://www.youtube.com",
        "https://example.test",
        "null"
    ])
    func authenticGoogleOriginKeepsNativeSurfaces(origin: String) throws {
        let context = try #require(JSContext())
        let originJSON = try String(
            decoding: JSONSerialization.data(withJSONObject: origin, options: .fragmentsAllowed),
            as: UTF8.self
        )
        // Execute the shipped script against native-like surfaces, including observable methods.
        context.evaluateScript("""
        var window = this;
        var location = {origin: \(originJSON)};
        function Navigator() {}
        Navigator.prototype.hardwareConcurrency = 24;
        var navigator = new Navigator();
        function Screen() {}
        Screen.prototype.width = 1800;
        function HTMLCanvasElement() {}
        HTMLCanvasElement.prototype.toDataURL = function () {return 'native'};
        var originalCanvas = HTMLCanvasElement.prototype.toDataURL;
        function CanvasRenderingContext2D() {}
        """)
        #expect(context.exception == nil)
        context.evaluateScript(BrowserPrivacyService.fingerprintingProtectionScriptSource())
        #expect(context.exception == nil)
        let exempt = origin == "https://accounts.google.com"
        #expect(context.evaluateScript("navigator.hardwareConcurrency")?.toInt32() == (exempt ? 24 : 8))
        #expect(context.evaluateScript("Screen.prototype.width")?.toInt32() == (exempt ? 1800 : 1440))
        #expect(context.evaluateScript("HTMLCanvasElement.prototype.toDataURL === originalCanvas")?.toBool() == exempt)
        #expect(context.evaluateScript("window.__oraFingerprintingProtectionInstalled === true")?.toBool() == !exempt)
    }
}
