import Foundation
import PDFKit
import UIKit
import WebKit

@MainActor
final class DOCXPreviewPDFSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private weak var hostWindow: UIWindow?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?
    private static let messageHandlerName = "notyDocxRendered"

    func render(
        docxData: Data,
        docxScript: String,
        jszipScript: String,
        workingDirectoryURL: URL
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            let contentController = WKUserContentController()
            contentController.add(self, name: Self.messageHandlerName)
            contentController.addUserScript(WKUserScript(
                source: jszipScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            contentController.addUserScript(WKUserScript(
                source: docxScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            contentController.addUserScript(WKUserScript(
                source: Self.driverScript(for: docxData),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
            configuration.userContentController = contentController

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 1_200), configuration: configuration)
            webView.navigationDelegate = self
            webView.isOpaque = false
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
            self.webView = webView
            do {
                try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
                let htmlURL = workingDirectoryURL.appendingPathComponent("Noty-DOCX-Render.html")
                try Self.html.write(to: htmlURL, atomically: true, encoding: .utf8)
                if let window = Self.activeWindow() {
                    hostWindow = window
                    webView.frame = window.bounds
                    webView.alpha = 1
                    webView.isUserInteractionEnabled = false
                    webView.accessibilityElementsHidden = true
                    window.insertSubview(webView, at: 0)
                    webView.setNeedsLayout()
                    webView.layoutIfNeeded()
                }
                webView.loadFileURL(htmlURL, allowingReadAccessTo: workingDirectoryURL)
                NSLog("Noty DOCX renderer: started local WebKit load")
            } catch {
                finish(.failure(error))
                return
            }

            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                } catch {
                    return
                }
                self?.finish(.failure(NotyStoreError.invalidOfficeDocument(
                    "The offline Word renderer took too long. Noty will try a text conversion fallback. The original Word file has been kept."
                )))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Noty DOCX renderer navigation failed: %@", error.localizedDescription)
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Noty DOCX renderer provisional navigation failed: %@", error.localizedDescription)
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("Noty DOCX renderer: local page finished loading")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Noty DOCX renderer: WebKit content process terminated")
        finish(.failure(NotyStoreError.invalidOfficeDocument(
            "The offline Word renderer stopped while opening this file. Noty will try its text conversion fallback."
        )))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let result = message.body as? [String: Any] else {
            finish(.failure(NotyStoreError.invalidOfficeDocument("The offline Word renderer returned an unreadable result.")))
            return
        }
        if let progress = result["progress"] as? String {
            NSLog("Noty DOCX renderer: %@", progress)
            return
        }
        guard result["ok"] as? Bool == true else {
            let detail = result["error"] as? String ?? "Unknown rendering error"
            finish(.failure(NotyStoreError.invalidOfficeDocument(
                "The full-layout Word renderer could not open this document (\(detail)). Noty will try its text conversion fallback."
            )))
            return
        }

        Task { @MainActor in
            do {
                guard let webView else {
                    throw NotyStoreError.invalidOfficeDocument("The Word preview closed before PDF creation finished.")
                }
                let data = try await Self.createPaginatedPDF(from: webView)
                finish(.success(data))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.removeFromSuperview()
        webView = nil
        hostWindow = nil
        continuation.resume(with: result)
    }

    private static func createPaginatedPDF(from webView: WKWebView) async throws -> Data {
        let pages = try await pageSlices(in: webView)
        guard !pages.isEmpty else {
            throw NotyStoreError.invalidOfficeDocument("The Word document has no printable pages.")
        }

        let pdf = PDFDocument()
        for (pageIndex, page) in pages.enumerated() {
            let scale = page.cssToViewScale
            guard scale.isFinite, scale > 0 else {
                throw NotyStoreError.invalidOfficeDocument("The Word page layout could not be measured.")
            }

            let desiredOffset = CGPoint(x: page.x * scale, y: page.y * scale)
            let maxOffset = CGPoint(
                x: max(0, webView.scrollView.contentSize.width - webView.bounds.width),
                y: max(0, webView.scrollView.contentSize.height - webView.bounds.height)
            )
            webView.scrollView.setContentOffset(
                CGPoint(x: min(desiredOffset.x, maxOffset.x), y: min(desiredOffset.y, maxOffset.y)),
                animated: false
            )
            webView.layoutIfNeeded()
            await Task.yield()

            guard let visiblePage = try await pageSlices(in: webView).first(where: { $0.index == page.index }) else {
                throw NotyStoreError.invalidOfficeDocument("A Word page could not be positioned for PDF export.")
            }
            let crop = CGRect(
                x: visiblePage.visibleX * scale,
                y: visiblePage.visibleY * scale,
                width: visiblePage.width * scale,
                height: visiblePage.height * scale
            )
            let captureRect = crop.integral.intersection(webView.bounds)
            let visibleAreaRatio = crop.width > 0 && crop.height > 0
                ? (captureRect.width * captureRect.height) / (crop.width * crop.height)
                : 0
            guard !captureRect.isNull, captureRect.width > 0, captureRect.height > 0,
                  visibleAreaRatio >= 0.98 else {
                throw NotyStoreError.invalidOfficeDocument(
                    "A Word page extends beyond the renderer viewport " +
                    "(crop: \(crop), bounds: \(webView.bounds), visible page: " +
                    "\(visiblePage.visibleX),\(visiblePage.visibleY),\(visiblePage.width),\(visiblePage.height), " +
                    "offset: \(webView.scrollView.contentOffset), content: \(webView.scrollView.contentSize), " +
                    "visible area: \(visibleAreaRatio))."
                )
            }

            let configuration = WKPDFConfiguration()
            configuration.rect = captureRect
            let pageData = try await webView.pdf(configuration: configuration)
            guard let pagePDF = PDFDocument(data: pageData), pagePDF.pageCount == 1,
                  let renderedPage = pagePDF.page(at: 0) else {
                throw NotyStoreError.invalidOfficeDocument("A Word page could not be exported as PDF.")
            }
            pdf.insert(renderedPage, at: pageIndex)
        }

        guard pdf.pageCount == pages.count, let data = pdf.dataRepresentation() else {
            throw NotyStoreError.invalidOfficeDocument("The Word pages could not be combined into a PDF.")
        }
        return data
    }

    private struct PageSlice {
        var index: Int
        var x: CGFloat
        var y: CGFloat
        var visibleX: CGFloat
        var visibleY: CGFloat
        var width: CGFloat
        var height: CGFloat
        var cssToViewScale: CGFloat
    }

    private static func pageSlices(in webView: WKWebView) async throws -> [PageSlice] {
        let script = """
        (() => {
          const nodes = Array.from(document.querySelectorAll('#docx-output section.docx'));
          return JSON.stringify({
            devicePixelRatio: window.devicePixelRatio,
            pages: nodes.map((node, index) => {
              const rect = node.getBoundingClientRect();
              return {
                index,
                x: rect.left + window.scrollX,
                y: rect.top + window.scrollY,
                visibleX: rect.left,
                visibleY: rect.top,
                width: rect.width,
                height: rect.height
              };
            })
          });
        })()
        """
        guard let json = try await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageValues = root["pages"] as? [[String: Any]] else {
            throw NotyStoreError.invalidOfficeDocument("The Word page layout could not be read.")
        }
        let devicePixelRatio = (root["devicePixelRatio"] as? NSNumber)?.doubleValue ?? 0
        let screenScale = Double(webView.window?.screen.scale ?? webView.traitCollection.displayScale)
        let cssToViewScale = devicePixelRatio / max(screenScale, 1)
        guard cssToViewScale.isFinite, cssToViewScale > 0 else {
            throw NotyStoreError.invalidOfficeDocument("The Word page viewport scale is unavailable.")
        }
        let slices = try pageValues.map { value -> PageSlice in
            guard let index = (value["index"] as? NSNumber)?.intValue,
                  let x = (value["x"] as? NSNumber)?.doubleValue,
                  let y = (value["y"] as? NSNumber)?.doubleValue,
                  let visibleX = (value["visibleX"] as? NSNumber)?.doubleValue,
                  let visibleY = (value["visibleY"] as? NSNumber)?.doubleValue,
                  let width = (value["width"] as? NSNumber)?.doubleValue,
                  let height = (value["height"] as? NSNumber)?.doubleValue,
                  [x, y, visibleX, visibleY, width, height].allSatisfy(\.isFinite),
                  width > 0, height > 0 else {
                throw NotyStoreError.invalidOfficeDocument("A Word page has incomplete layout information.")
            }
            return PageSlice(
                index: index,
                x: x,
                y: y,
                visibleX: visibleX,
                visibleY: visibleY,
                width: width,
                height: height,
                cssToViewScale: cssToViewScale
            )
        }
        guard slices.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
            throw NotyStoreError.invalidOfficeDocument("The Word renderer returned pages in an unsupported order.")
        }
        return slices
    }

    private static var html: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#fff}body{-webkit-print-color-adjust:exact;print-color-adjust:exact}</style>
        </head><body><div id="docx-output"></div></body></html>
        """
    }

    private static func driverScript(for data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        (async function () {
          const send = value => window.webkit.messageHandlers.\(messageHandlerName).postMessage(value);
          try {
            send({ progress: "renderer script started" });
            if (!window.JSZip || !window.docx || !window.docx.renderAsync) {
              throw new Error("Offline Word rendering resources did not load");
            }
            const encoded = "\(base64)";
            const binary = atob(encoded);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            send({ progress: "renderAsync started" });
            const output = document.getElementById("docx-output");
            await window.docx.renderAsync(bytes, output, output, {
              inWrapper: true,
              ignoreWidth: false,
              ignoreHeight: false,
              ignoreFonts: false,
              breakPages: true,
              renderHeaders: true,
              renderFooters: true,
              renderFootnotes: true,
              renderEndnotes: true,
              useBase64URL: true
            });
            send({ progress: "renderAsync completed" });
            await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 1200))]);
            await Promise.race([Promise.all(Array.from(document.images, image => image.complete
              ? Promise.resolve()
              : new Promise(resolve => { image.onload = resolve; image.onerror = resolve; }))),
              new Promise(resolve => setTimeout(resolve, 1800))]);
            send({ progress: "images and fonts settled" });
            send({ ok: true });
          } catch (error) {
            send({
              ok: false,
              error: String(error && error.message ? error.message : error)
            });
          }
        })();
        """
    }

    private static func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

}
