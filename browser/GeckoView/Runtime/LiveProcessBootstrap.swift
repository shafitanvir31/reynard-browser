//
//  LiveProcessBootstrap.swift
//  Reynard
//

import Foundation
import UIKit

// Child process entry point used when Reynard runs inside LiveContainer.
// Reynard's own helper extension isn't registered with iOS there, so the
// parent launches LiveContainer's LiveProcess extension instead. LiveProcess
// dlopens this framework and calls ReynardLiveProcessMain, which does the same
// work as the helper's ProcessBootstrap.
// https://github.com/LiveContainer/LiveContainer/blob/main/LiveProcess/main.m

@objc private protocol LiveProcessBootstrapPing {
    func ping()
}

private final class LiveProcessExtension: NSObject, GeckoProcessExtension {
    func lockdownSandbox(_ revision: String) {}
}

@_cdecl("ReynardLiveProcessMain")
public func ReynardLiveProcessMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ apple: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    // LiveProcess stores the extension request's userInfo here.
    let appInfoSelector = NSSelectorFromString("retrievedAppInfo")
    guard
        let handlerClass = NSClassFromString("LiveProcessHandler") as? NSObject.Type,
        handlerClass.responds(to: appInfoSelector),
        let appInfo = handlerClass.perform(appInfoSelector)?.takeUnretainedValue() as? [String: Any],
        let endpoint = appInfo["ReynardXPCListenerEndpoint"] as? NSXPCListenerEndpoint
    else {
        NSLog("[Reynard] LiveProcess payload: missing NSXPC listener endpoint")
        return 1
    }

    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: LiveProcessBootstrapPing.self)
    connection.resume()

    guard let xpcConnection = XPCConnectionFromNSXPC(connection) else {
        NSLog("[Reynard] LiveProcess payload: failed to bridge NSXPCConnection to libxpc")
        connection.invalidate()
        return 1
    }

    GeckoRuntime.childMain(xpcConnection: xpcConnection, process: LiveProcessExtension())
    (connection.remoteObjectProxyWithErrorHandler({ _ in }) as? LiveProcessBootstrapPing)?.ping()

    // LiveProcess skipped the real UIApplicationMain to hand control to us.
    // Run it now so the process stays alive and has the same UIKit state as
    // the helper extension. It never returns.
    return withExtendedLifetime(connection) {
        UIApplicationMain(argc, argv, nil, nil)
    }
}
