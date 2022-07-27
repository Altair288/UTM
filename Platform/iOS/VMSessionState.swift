//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// Represents the UI state for a single VM session.
@MainActor class VMSessionState: NSObject, ObservableObject {
    let vm: UTMQemuVirtualMachine
    
    var qemuConfig: UTMQemuConfiguration! {
        vm.config.qemuConfig
    }
    
    @Published var vmState: UTMVMState = .vmStopped
    
    @Published var fatalError: String?
    
    @Published var nonfatalError: String?
    
    @Published var primaryInput: CSInput?
    
    #if !WITH_QEMU_TCI
    private var primaryUsbManager: CSUSBManager?
    
    @Published var mostRecentConnectedDevice: CSUSBDevice?
    
    @Published var allUsbDevices: [CSUSBDevice] = []
    
    @Published var connectedUsbDevices: [CSUSBDevice] = []
    #else
    let mostRecentConnectedDevice: Any? = nil
    
    let allUsbDevices: [Any] = []
    
    let connectedUsbDevices: [Any] = []
    #endif
    
    @Published var isUsbBusy: Bool = false
    
    @Published var primaryDisplay: CSDisplay?
    
    @Published var otherDisplays: [CSDisplay] = []
    
    @Published var primarySerial: CSPort?
    
    @Published var otherSerials: [CSPort] = []
    
    init(for vm: UTMQemuVirtualMachine) {
        self.vm = vm
        super.init()
        vm.delegate = self
        vm.ioDelegate = self
    }
}

extension VMSessionState: UTMVirtualMachineDelegate {
    func virtualMachine(_ vm: UTMVirtualMachine, didTransitionTo state: UTMVMState) {
        Task {
            await MainActor.run {
                vmState = state
                if state == .vmStopped {
                    clearDevices()
                }
            }
        }
    }
    
    func virtualMachine(_ vm: UTMVirtualMachine, didErrorWithMessage message: String) {
        Task {
            await MainActor.run {
                fatalError = message
            }
        }
    }
}

extension VMSessionState: UTMSpiceIODelegate {
    func spiceDidCreateInput(_ input: CSInput) {
        guard primaryInput == nil else {
            return
        }
        Task {
            await MainActor.run {
                primaryInput = input
            }
        }
    }
    
    func spiceDidDestroyInput(_ input: CSInput) {
        guard primaryInput == input else {
            return
        }
        Task {
            await MainActor.run {
                primaryInput = nil
            }
        }
    }
    
    func spiceDidCreateDisplay(_ display: CSDisplay) {
        guard display.isPrimaryDisplay else {
            return
        }
        Task {
            await MainActor.run {
                primaryDisplay = display
            }
        }
    }
    
    func spiceDidDestroyDisplay(_ display: CSDisplay) {
        guard display == primaryDisplay else {
            return
        }
        Task {
            await MainActor.run {
                primaryDisplay = nil
            }
        }
    }
    
    func spiceDidUpdateDisplay(_ display: CSDisplay) {
        // nothing to do
    }
    
    func spiceDidCreateSerial(_ serial: CSPort) {
        guard primarySerial == nil else {
            return
        }
        Task {
            await MainActor.run {
                primarySerial = serial
            }
        }
    }
    
    func spiceDidDestroySerial(_ serial: CSPort) {
        guard primarySerial == serial else {
            return
        }
        Task {
            await MainActor.run {
                primarySerial = nil
            }
        }
    }
    
    #if !WITH_QEMU_TCI
    func spiceDidChangeUsbManager(_ usbManager: CSUSBManager?) {
        Task {
            await MainActor.run {
                primaryUsbManager?.delegate = nil
                primaryUsbManager = usbManager
                usbManager?.delegate = self
            }
        }
    }
    #endif
}

#if !WITH_QEMU_TCI
extension VMSessionState: CSUSBManagerDelegate {
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        Task {
            await MainActor.run {
                nonfatalError = error
            }
        }
    }
    
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        Task {
            await MainActor.run {
                mostRecentConnectedDevice = device
            }
        }
    }
    
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        Task {
            await MainActor.run {
                disconnectDevice(device)
            }
        }
    }
    
    func refreshDevices() {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            let devices = usbManager.usbDevices
            await MainActor.run {
                allUsbDevices = devices
                isUsbBusy = false
            }
        }
    }
    
    func connectDevice(_ usbDevice: CSUSBDevice) {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            let (success, message) = await usbManager.connectUsbDevice(usbDevice)
            await MainActor.run {
                if success {
                    self.connectedUsbDevices.append(usbDevice)
                } else {
                    nonfatalError = message
                }
                isUsbBusy = false
            }
        }
    }
    
    func disconnectDevice(_ usbDevice: CSUSBDevice) {
        guard let usbManager = self.primaryUsbManager else {
            logger.error("no usb manager connected")
            return
        }
        isUsbBusy = true
        Task.detached { [self] in
            await usbManager.disconnectUsbDevice(usbDevice)
            await MainActor.run {
                connectedUsbDevices.removeAll(where: { $0 == usbDevice })
                isUsbBusy = false
            }
        }
    }
    
    private func clearDevices() {
        connectedUsbDevices.removeAll()
        allUsbDevices.removeAll()
    }
}
#endif

extension VMSessionState {
    @objc private func suspend() {
        // dummy function for selector
    }
    
    func terminateApplication() {
        DispatchQueue.main.async { [self] in
            // animate to home screen
            let app = UIApplication.shared
            app.performSelector(onMainThread: #selector(suspend), with: nil, waitUntilDone: true)
            
            // wait 2 seconds while app is going background
            Thread.sleep(forTimeInterval: 2)
            
            // exit app when app is in background
            exit(0);
        }
    }
    
    func powerDown() {
        vm.requestVmDeleteState()
        vm.vmStop { _ in
            self.terminateApplication()
        }
    }
    
    func pauseResume() {
        let shouldSaveState = !vm.isRunningAsSnapshot
        if vm.state == .vmStarted {
            vm.requestVmPause(save: shouldSaveState)
        } else if vm.state == .vmPaused {
            vm.requestVmResume()
        }
    }
    
    func reset() {
        vm.requestVmReset()
    }
}