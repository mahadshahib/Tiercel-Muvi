//
//  DownloadTask.swift
//  Tiercel
//
//  Created by Daniels on 2018/3/16.
//  Copyright © 2018 Daniels. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import UIKit

public class DownloadTask: Task<DownloadTask> {
    
    private enum CodingKeys: CodingKey {
        case resumeData
    }

    fileprivate var acceptableStatusCodes: Range<Int> { return 200..<300 }
    
    internal var sessionTask: URLSessionDownloadTask? {
        willSet {
            sessionTask?.removeObserver(self, forKeyPath: "currentRequest")
        }
        didSet {
            sessionTask?.addObserver(self, forKeyPath: "currentRequest", options: [.new], context: nil)
        }
    }
    
    public var originalRequest: URLRequest? {
        sessionTask?.originalRequest
    }

    public var currentRequest: URLRequest? {
        sessionTask?.currentRequest
    }

    public var response: URLResponse? {
        sessionTask?.response
    }
    
    public var statusCode: Int? {
        (sessionTask?.response as? HTTPURLResponse)?.statusCode
    }

    public var filePath: String {
        return cache.filePath(fileName: fileName)!
    }

    public var pathExtension: String? {
        let pathExtension = (filePath as NSString).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension
    }

    internal var tmpFileURL: URL?


    private let protectedDownloadState: Protector<DownloadState> = Protector(DownloadState())
    
    internal var tmpFileName: String? {
        protectedDownloadState.directValue.tmpFileName
    }

    private struct DownloadState {

        internal var resumeData: Data? {
            didSet {
                guard let resumeData = resumeData else { return  }
                tmpFileName = ResumeDataHelper.getTmpFileName(resumeData)
            }
        }

        internal var tmpFileName: String?

        internal var shouldValidateFile: Bool = false
    }



    internal init(_ url: URL,
                  headers: [String: String]? = nil,
                  fileName: String? = nil,
                  cache: Cache,
                  operationQueue: DispatchQueue) {
        super.init(url,
                   headers: headers,
                   cache: cache,
                   operationQueue: operationQueue)
        if let fileName = fileName,
            !fileName.isEmpty {
            protectedState.write { $0.fileName = fileName }
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fixDelegateMethodError),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }
    
    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let superEncoder = container.superEncoder()
        try super.encode(to: superEncoder)
        try container.encodeIfPresent(protectedDownloadState.directValue.resumeData, forKey: .resumeData)
    }
    
    internal required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let superDecoder = try container.superDecoder()
        try super.init(from: superDecoder)
        guard let resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData) else { return }
        protectedDownloadState.write {
            $0.resumeData = resumeData
        }
    }
    
    
    deinit {
        sessionTask?.removeObserver(self, forKeyPath: "currentRequest")
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func fixDelegateMethodError() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.sessionTask?.suspend()
            self.sessionTask?.resume()
        }
    }


    internal override func execute(_ executer: Executer<DownloadTask>?) {
        executer?.execute(self)
    }
    

}


// MARK: - control
extension DownloadTask {

    internal func prepare() {
        cache.createDirectory()

        if cache.fileExists(fileName: fileName) {
            TiercelLog("[downloadTask] file already exists", identifier: manager?.identifier ?? "", url: url)
            if let fileInfo = try? FileManager().attributesOfItem(atPath: cache.filePath(fileName: fileName)!), let length = fileInfo[.size] as? Int64 {
                progress.totalUnitCount = length
            }
            succeeded()
            manager?.determineStatus()
            return
        }
        download()
    }

    private func download() {
        guard let manager = manager else { return }
        switch status {
        case .waiting, .suspended, .failed:
            if manager.shouldRun {
                start()
            } else {
                protectedState.write { $0.status = .waiting }
                TiercelLog("[downloadTask] waiting", identifier: manager.identifier, url: url)
            }
        case .succeeded:
            succeeded()
            manager.determineStatus()
        case .running:
            TiercelLog("[downloadTask] running", identifier: manager.identifier, url: url)
        default: break
        }
    }


    private func start() {
        if let resumeData = protectedDownloadState.directValue.resumeData {
            cache.retrieveTmpFile(self)
            if #available(iOS 10.2, *) {
                sessionTask = session?.downloadTask(withResumeData: resumeData)
            } else if #available(iOS 10.0, *) {
                sessionTask = session?.correctedDownloadTask(withResumeData: resumeData)
            } else {
                sessionTask = session?.downloadTask(withResumeData: resumeData)
            }
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0)
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            sessionTask = session?.downloadTask(with: request)
        }
        protectedState.write { $0.speed = 0 }
        progress.setUserInfoObject(progress.completedUnitCount, forKey: .fileCompletedCountKey)

        sessionTask?.resume()

        if startDate == 0 {
            protectedState.write { $0.startDate = Date().timeIntervalSince1970 }
        }
        protectedState.write { $0.status = .running }
        TiercelLog("[downloadTask] running", identifier: manager?.identifier ?? "", url: url)
        progressExecuter?.execute(self)
        manager?.didStart()
    }


    internal func suspend(onMainQueue: Bool = true, _ handler: Handler<DownloadTask>? = nil) {
        guard status == .running || status == .waiting else { return }
        controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)

        if status == .running {
            protectedState.write { $0.status = .willSuspend }
            sessionTask?.cancel(byProducingResumeData: { _ in })
        }

        if status == .waiting {
            protectedState.write { $0.status = .suspended }
            TiercelLog("[downloadTask] did suspend", identifier: manager?.identifier ?? "", url: url)
            progressExecuter?.execute(self)
            controlExecuter?.execute(self)
            failureExecuter?.execute(self)

            manager?.determineStatus()
        }
    }

    internal func cancel(onMainQueue: Bool = true, _ handler: Handler<DownloadTask>? = nil) {
        guard status != .succeeded else { return }
        controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        if status == .running {
            protectedState.write { $0.status = .willCancel }
            sessionTask?.cancel()
        } else {
            protectedState.write { $0.status = .willCancel }
            didCancelOrRemove()
            TiercelLog("[downloadTask] did cancel", identifier: manager?.identifier ?? "", url: url)
            controlExecuter?.execute(self)
            failureExecuter?.execute(self)
            manager?.determineStatus()
        }
    }


    internal func remove(completely: Bool = false, onMainQueue: Bool = true, _ handler: Handler<DownloadTask>? = nil) {
        protectedState.write { $0.isRemoveCompletely = completely }
        controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        if status == .running {
            protectedState.write { $0.status = .willRemove }
            sessionTask?.cancel()
        } else {
            protectedState.write { $0.status = .willRemove }
            didCancelOrRemove()
            TiercelLog("[downloadTask] did remove", identifier: manager?.identifier ?? "", url: url)
            controlExecuter?.execute(self)
            failureExecuter?.execute(self)
            manager?.determineStatus()
        }
    }


    internal func updateFileName(_ newFileName: String) {
        guard !fileName.isEmpty else { return }
        cache.updateFileName(self, newFileName)
        protectedState.write { $0.fileName = newFileName }
    }

    fileprivate func validateFile() {
        guard let validateHandler = self.validateExecuter else { return }

        if !protectedDownloadState.directValue.shouldValidateFile {
            validateHandler.execute(self)
            return
        }

        guard let verificationCode = verificationCode else { return }
        FileChecksumHelper.validateFile(filePath, code: verificationCode, type: verificationType) { [weak self] (isCorrect) in
            guard let self = self else { return }
            self.protectedDownloadState.write { $0.shouldValidateFile = false }
            self.protectedState.write { $0.validation = isCorrect ? .correct : .incorrect }
            if let manager = self.manager {
                manager.cache.storeTasks(manager.tasks)
            }
            validateHandler.execute(self)
        }
    }

}



// MARK: - status handle
extension DownloadTask {

    
    private func didCancelOrRemove() {
        
        // 把预操作的状态改成完成操作的状态
        if status == .willCancel {
            protectedState.write { $0.status = .canceled }
        }
        
        if status == .willRemove {
            protectedState.write { $0.status = .removed }
        }
        cache.remove(self, completely: protectedState.directValue.isRemoveCompletely)
        
        manager?.didCancelOrRemove(url.absoluteString)
    }


    internal func succeeded() {
        guard status != .succeeded else { return }
        protectedState.write { $0.status = .succeeded }
        protectedState.write { $0.endDate = Date().timeIntervalSince1970 }

        progress.completedUnitCount = progress.totalUnitCount
        timeRemaining = 0
        TiercelLog("[downloadTask] completed", identifier: manager?.identifier ?? "", url: url)
        progressExecuter?.execute(self)
        successExecuter?.execute(self)
        validateFile()
    }

    private func determineStatus(error: Error?, isAcceptable: Bool) {
        if !isAcceptable {
            protectedState.write { $0.status = .failed }
        }

        if let error = error {
            self.error = error

            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                protectedDownloadState.write { $0.resumeData = ResumeDataHelper.handleResumeData(resumeData)}
                cache.storeTmpFile(self)
            }
            if let _ = (error as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int {
                protectedState.write { $0.status = .suspended }
            }
            if let urlError = error as? URLError, urlError.code != URLError.cancelled {
                protectedState.write { $0.status = .failed }
            }
        }

        switch status {
        case .suspended:
            protectedState.write { $0.status = .suspended }
            TiercelLog("[downloadTask] did suspend", identifier: manager?.identifier ?? "", url: url)

        case .willSuspend:
            protectedState.write { $0.status = .suspended }
            TiercelLog("[downloadTask] did suspend", identifier: manager?.identifier ?? "", url: url)
            progressExecuter?.execute(self)
            controlExecuter?.execute(self)
            failureExecuter?.execute(self)
        case .willCancel, .willRemove:
            didCancelOrRemove()
            if status == .canceled {
                TiercelLog("[downloadTask] did cancel", identifier: manager?.identifier ?? "", url: url)
            }
            if status == .removed {
                TiercelLog("[downloadTask] did remove", identifier: manager?.identifier ?? "", url: url)
            }
            controlExecuter?.execute(self)
            failureExecuter?.execute(self)
        default:
            protectedState.write { $0.status = .failed }
            TiercelLog("[downloadTask] failed", identifier: manager?.identifier ?? "", url: url)
            progressExecuter?.execute(self)
            failureExecuter?.execute(self)
        }
    }
}

// MARK: - closure
extension DownloadTask {
    @discardableResult
    public func validateFile(code: String,
                             type: FileVerificationType,
                             onMainQueue: Bool = true,
                             _ handler: @escaping Handler<DownloadTask>) -> Self {
        return operationQueue.sync {
            if verificationCode == code &&
                verificationType == type &&
                validation != .unkown {
                protectedDownloadState.write { $0.shouldValidateFile = false}
            } else {
                protectedDownloadState.write { $0.shouldValidateFile = true }
                verificationCode = code
                verificationType = type
            }
            self.validateExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
            if let manager = manager {
                manager.cache.storeTasks(manager.tasks)
            }
            if status == .succeeded {
                validateFile()
            }
            return self
        }

    }
}



// MARK: - KVO
extension DownloadTask {
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if let change = change, let newRequest = change[NSKeyValueChangeKey.newKey] as? URLRequest, let url = newRequest.url {
            protectedState.write { $0.currentURL = url }
        }
    }
}

// MARK: - info
extension DownloadTask {

    internal func updateSpeedAndTimeRemaining(_ interval: TimeInterval) {

        let dataCount = progress.completedUnitCount
        let lastData: Int64 = progress.userInfo[.fileCompletedCountKey] as? Int64 ?? 0

        if dataCount > lastData {
            protectedState.write { $0.speed = Int64(Double(dataCount - lastData) / interval) }
            updateTimeRemaining()
        }
        progress.setUserInfoObject(dataCount, forKey: .fileCompletedCountKey)

    }

    private func updateTimeRemaining() {
        if speed == 0 {
            self.timeRemaining = 0
        } else {
            let timeRemaining = (Double(progress.totalUnitCount) - Double(progress.completedUnitCount)) / Double(speed)
            self.timeRemaining = Int64(timeRemaining)
            if timeRemaining < 1 && timeRemaining > 0.8 {
                self.timeRemaining += 1
            }
        }
    }
}

// MARK: - callback
extension DownloadTask {
    internal func didWriteData(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress.completedUnitCount = totalBytesWritten
        progress.totalUnitCount = totalBytesExpectedToWrite
        if SessionManager.isControlNetworkActivityIndicator {
            DispatchQueue.tr.executeOnMain {
                UIApplication.shared.isNetworkActivityIndicatorVisible = true
            }
        }
        progressExecuter?.execute(self)
        manager?.updateProgress()
    }
    
    
    internal func didFinishDownloading(task: URLSessionDownloadTask, to location: URL) {
        guard let statusCode = (task.response as? HTTPURLResponse)?.statusCode,
            acceptableStatusCodes.contains(statusCode)
            else { return }
        self.tmpFileURL = location
        cache.storeFile(self)
        cache.removeTmpFile(self)
    }
    
    internal func didComplete(task: URLSessionTask, error: Error?) {
        if SessionManager.isControlNetworkActivityIndicator {
            DispatchQueue.tr.executeOnMain {
                UIApplication.shared.isNetworkActivityIndicatorVisible = false
            }
        }

        progress.totalUnitCount = task.countOfBytesExpectedToReceive
        progress.completedUnitCount = task.countOfBytesReceived
        progress.setUserInfoObject(task.countOfBytesReceived, forKey: .fileCompletedCountKey)


        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let isAcceptable = acceptableStatusCodes.contains(statusCode)

        if error == nil && acceptableStatusCodes.contains(statusCode) {
            succeeded()
        } else {
            determineStatus(error: error, isAcceptable: isAcceptable)
        }

        manager?.determineStatus()
    }

}



extension Array where Element == DownloadTask {
    @discardableResult
    public func progress(onMainQueue: Bool = true, _ handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.progress(onMainQueue: onMainQueue, handler) }
        return self
    }

    @discardableResult
    public func success(onMainQueue: Bool = true, _ handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.success(onMainQueue: onMainQueue, handler) }
        return self
    }

    @discardableResult
    public func failure(onMainQueue: Bool = true, _ handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.failure(onMainQueue: onMainQueue, handler) }
        return self
    }

    public func validateFile(codes: [String],
                             type: FileVerificationType,
                             onMainQueue: Bool = true,
                             _ handler: @escaping Handler<DownloadTask>) -> [Element] {
        for (index, task) in self.enumerated() {
            guard let code = codes.safeObject(at: index) else { continue }
            task.validateFile(code: code, type: type, onMainQueue: onMainQueue, handler)
        }
        return self
    }
}
